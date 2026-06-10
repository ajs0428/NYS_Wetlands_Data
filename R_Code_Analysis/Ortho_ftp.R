library(curl)
library(stringr)
library(sf)
library(dplyr)
library(terra)
library(jsonlite)
library(future)
library(future.apply)

n_workers <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", unset = "1"))

# Root of the NYS orthoimagery tile-index MapServer (layers organized by
# year / state-plane zone / resolution / band-type). Layer IDs are NOT stable
# across publishing cycles, so we always resolve them by name at runtime.
ortho_mapserver <- "https://orthos.its.ny.gov/arcgis/rest/services/vector/ortho_indexes/MapServer"

# Normalize a raw FILENAME from the index into a clean tile name.
# FILENAME carries its extension and has inconsistent case across zones
# (e.g. "..._2020.jp2" vs "..._2020.jP2"); lowercase + strip extension so that
# dedup, skip-if-exists, and output naming all agree.
normalize_tile_name <- function(filename) {
    tools::file_path_sans_ext(tolower(as.character(filename)))
}

### Resolve ALL index layers for a band type, with their imagery year.
# Fetches the MapServer root JSON, parses the `layers` array, and filters to
# layers named like ind{YY}{zone}_{res}_{bands}. Returns a tibble of
# layer_id + layer_name + year (one row per matching year/zone/resolution).
# Years are resolved here (not passed in) so the caller can fall back to the
# nearest available year when the preferred one lacks coverage.
get_ortho_layer_index <- function(bands = "4bd") {
    meta <- fromJSON(paste0(ortho_mapserver, "?f=json"))
    layers <- meta$layers  # data.frame with id + name

    # Match "ind{YY}...._4bd" but require the band suffix to be the trailing token
    pat <- paste0("^ind(\\d{2})[a-z]+_.*", bands, "($|_)")
    keep <- str_detect(layers$name, pat)
    yy <- as.integer(str_match(layers$name[keep], "^ind(\\d{2})")[, 2])
    out <- tibble(
        layer_id   = layers$id[keep],
        layer_name = layers$name[keep],
        year       = ifelse(yy > 50, 1900L + yy, 2000L + yy)
    )

    if (nrow(out) == 0) {
        warning("No index layers matched bands '", bands, "'")
    }
    out
}

### Query one index layer for all tiles intersecting a bbox (handles pagination).
# bbox_4326: numeric c(xmin, ymin, xmax, ymax) in EPSG:4326.
# Returns an sf object (EPSG:6347) of matching tile polygons, or NULL if none.
query_ortho_index <- function(layer_id, bbox_4326, bands_outfields =
                              "FILENAME,FTP_PATH,DIRECT_DL,Shape_Area") {
    base_url <- paste0(ortho_mapserver, "/", layer_id, "/query")
    page_size <- 1000
    offset <- 0L
    pages <- list()

    repeat {
        params <- list(
            where             = "1=1",
            geometry          = paste(bbox_4326, collapse = ","),
            geometryType      = "esriGeometryEnvelope",
            inSR              = "4326",
            spatialRel        = "esriSpatialRelIntersects",
            outFields         = bands_outfields,
            returnGeometry    = "true",
            outSR             = "6347",
            f                 = "geojson",
            resultOffset      = offset,
            resultRecordCount = page_size
        )
        # Build a properly URL-encoded query string
        qs <- paste(names(params),
                    vapply(params, function(v) curl_escape(as.character(v)), ""),
                    sep = "=", collapse = "&")
        url <- paste0(base_url, "?", qs)

        # Download to a temp file rather than handing st_read a URL directly
        # (more reliable for long query strings / large GeoJSON payloads).
        tmp <- tempfile(fileext = ".geojson")
        curl_download(url, tmp, quiet = TRUE)

        page <- tryCatch(st_read(tmp, quiet = TRUE),
                         error = function(e) NULL)
        unlink(tmp)

        n <- if (is.null(page)) 0L else nrow(page)
        if (n > 0) pages[[length(pages) + 1L]] <- page

        # geojson output does not reliably echo exceededTransferLimit, so page
        # until a short page is returned.
        if (n < page_size) break
        offset <- offset + page_size
    }

    if (length(pages) == 0) return(NULL)
    do.call(rbind, pages)
}

### Query all index layers of ONE year for tiles intersecting a bbox.
# Returns an sf object (or NULL). Logs a note when the year's layers span
# multiple native resolutions (harmless: everything is resampled to 1 m).
query_ortho_year <- function(yr_layers, bbox_4326) {
    message("  Matching index layers: ",
            paste(yr_layers$layer_name, collapse = ", "))

    res_tokens <- str_extract(yr_layers$layer_name, "half_ft|one_ft|two_ft|one_m")
    if (length(unique(na.omit(res_tokens))) > 1) {
        message("  NOTE: source tiles span multiple native resolutions (",
                paste(unique(na.omit(res_tokens)), collapse = ", "),
                "); all will be resampled to 1 m.")
    }

    parts <- lapply(yr_layers$layer_id, function(id) {
        res <- tryCatch(query_ortho_index(id, bbox_4326),
                        error = function(e) {
                            warning("Query failed for layer ", id, ": ", e$message)
                            NULL
                        })
        if (!is.null(res)) message("    layer ", id, ": ", nrow(res), " bbox hits")
        res
    })
    parts <- parts[!sapply(parts, is.null)]
    if (length(parts) == 0) return(NULL)
    do.call(rbind, parts)
}

### Find all ortho tiles needed to cover a cluster's HUC12 polygons.
# Mirrors get_overlapping_tiles() in Lidar_ftp.R, but pulls the index from the
# REST service and is YEAR-AWARE: the preferred year's tiles are taken first;
# if they leave more than gap_tol of the cluster uncovered (no coverage at all,
# or a collection boundary crossing the cluster), the nearest other year(s)
# (newer breaks ties) fill only the remaining gap. This guarantees the tiles
# that Ortho_HUC_Processing.R's own preferred-year + nearest-year gap-fill
# needs are actually on disk.
get_overlapping_ortho_tiles <- function(huc12_sf, year, bands = "4bd",
                                        gap_tol = 0.001) {

    # Bounding box of the cluster in EPSG:4326 for the spatial query
    huc_4326 <- st_transform(huc12_sf, 4326)
    bb <- st_bbox(huc_4326)
    bbox_4326 <- c(bb["xmin"], bb["ymin"], bb["xmax"], bb["ymax"])

    layers <- get_ortho_layer_index(bands)
    if (nrow(layers) == 0) return(NULL)
    years_available <- sort(unique(layers$year))
    message("  Index years available for '", bands, "': ",
            paste(years_available, collapse = ", "))

    preferred <- as.integer(year)
    if (!preferred %in% years_available) {
        message("  Preferred year ", preferred,
                " has no index layers; falling back to nearest available year.")
    }
    others <- setdiff(years_available, preferred)
    others <- others[order(abs(others - preferred), -others)]
    year_order <- c(intersect(preferred, years_available), others)

    selected     <- NULL  # accumulated sf of chosen tiles (tile CRS)
    covered      <- NULL  # union of chosen tile footprints
    cluster_geom <- NULL  # cluster outline in the tile CRS (built lazily)
    cluster_area <- NA_real_

    for (yr in year_order) {
        # Remaining uncovered part of the cluster
        if (!is.null(cluster_geom)) {
            gap <- if (is.null(covered)) cluster_geom
                   else st_make_valid(st_difference(cluster_geom, covered))
            gap_area <- if (length(gap) == 0) 0 else sum(as.numeric(st_area(gap)))
            if (gap_area / cluster_area < gap_tol) break  # effectively covered
        }

        message("  Querying year ", yr, " ...")
        tiles_yr <- query_ortho_year(layers[layers$year == yr, ], bbox_4326)
        if (is.null(tiles_yr) || nrow(tiles_yr) == 0) next

        # Cluster geometry in the tile CRS (same for every year: fixed outSR)
        if (is.null(cluster_geom)) {
            cluster_geom <- st_make_valid(
                st_union(st_geometry(st_transform(huc12_sf, st_crs(tiles_yr)))))
            cluster_area <- as.numeric(st_area(cluster_geom))
            gap <- cluster_geom
        }

        # Refine bbox hits to tiles actually touching the remaining gap (for
        # the preferred year the gap IS the cluster, mirroring the old refine).
        tiles_yr <- tiles_yr[lengths(st_intersects(tiles_yr, gap)) > 0, ]
        if (nrow(tiles_yr) == 0) next
        message("  Year ", yr, ": ", nrow(tiles_yr), " tiles selected")

        tiles_yr$tile_year <- yr
        selected <- if (is.null(selected)) tiles_yr else rbind(selected, tiles_yr)
        yr_union <- st_union(st_geometry(tiles_yr))
        covered  <- if (is.null(covered)) yr_union else st_union(covered, yr_union)
    }

    if (is.null(selected) || nrow(selected) == 0) {
        warning("No tiles intersect the cluster HUC12 polygons (any year)")
        return(NULL)
    }
    message("  Years selected: ", paste(unique(selected$tile_year), collapse = ", "))

    selected |>
        mutate(
            tile_name = normalize_tile_name(FILENAME),
            # Prefer the authoritative DIRECT_DL HTTPS url; FTP fallback derived
            # by swapping the host (same convention as Lidar_ftp.R).
            dl_url  = as.character(DIRECT_DL),
            ftp_url = str_replace(as.character(DIRECT_DL),
                                  "https://gisdata.ny.gov/",
                                  "ftp://ftp.gis.ny.gov/")
        )
}

### Download a tile zip (HTTPS, FTP fallback), unzip, return path to the .jp2.
download_ortho_tile <- function(dl_url, ftp_url, dest_dir, max_tries = 3) {
    zip_path <- file.path(dest_dir, basename(dl_url))

    fetch <- function(url) {
        for (attempt in seq_len(max_tries)) {
            ok <- tryCatch({
                curl_download(url, zip_path, quiet = TRUE)
                TRUE
            }, error = function(e) FALSE)
            if (ok && file.exists(zip_path) && file.size(zip_path) > 0) return(TRUE)
            Sys.sleep(2 * attempt)  # linear backoff
        }
        FALSE
    }

    if (!fetch(dl_url)) {
        message("    HTTPS failed, trying FTP: ", basename(ftp_url))
        if (!fetch(ftp_url)) stop("download failed (HTTPS and FTP): ", basename(dl_url))
    }

    exdir <- file.path(dest_dir, tools::file_path_sans_ext(basename(zip_path)))
    dir.create(exdir, showWarnings = FALSE, recursive = TRUE)
    unzip(zip_path, exdir = exdir)
    unlink(zip_path)  # zip no longer needed

    jp2 <- list.files(exdir, pattern = "\\.jp2$", ignore.case = TRUE,
                      full.names = TRUE)
    if (length(jp2) == 0) stop("no .jp2 found in zip for ", basename(dl_url))
    jp2[1]
}

# Path to a JPEG2000-capable gdalwarp. terra's bundled GDAL on BioHPC is built
# WITHOUT a JP2 driver, so rast() cannot read .jp2 directly. Point this at a
# GDAL install that reports JP2OpenJPEG (see `gdalwarp --formats | grep -i jp2`)
# via the ORTHO_GDALWARP env var; defaults to whatever is on PATH.
ortho_gdalwarp <- Sys.getenv("ORTHO_GDALWARP", unset = "gdalwarp")

### Reproject + resample a .jp2 to 1 m EPSG:6347, snapped to the integer-meter
# grid so tiles share an origin with the LiDAR metrics (required for mosaic()).
# Uses gdalwarp directly (not terra::rast) so it works even when terra's GDAL
# lacks a JP2 driver. -tap forces the output grid onto integer-meter multiples
# (equivalent to the floor/ceil snap in compute_lidar_metrics()).
reproject_ortho_tile <- function(jp2_path, out_path, res = 1,
                                 target_crs = "EPSG:6347") {
    args <- c("-t_srs", target_crs,
              "-tr", res, res, "-tap",
              "-r", "bilinear",
              "-of", "GTiff", "-overwrite",
              "-co", "COMPRESS=DEFLATE",
              shQuote(jp2_path), shQuote(out_path))

    log <- suppressWarnings(
        system2(ortho_gdalwarp, args, stdout = TRUE, stderr = TRUE))
    status <- attr(log, "status")

    if ((!is.null(status) && status != 0) || !file.exists(out_path)) {
        stop("gdalwarp failed: ", paste(log, collapse = " | "))
    }
    out_path
}

### Process a single tile: skip-if-exists -> download -> reproject -> clean up.
process_ortho_tile <- function(tile_name, dl_url, ftp_url, out_dir) {
    out_path <- file.path(out_dir, paste0(tile_name, ".tif"))

    if (file.exists(out_path)) {
        message("[", Sys.getpid(), "] Skipping (exists): ", tile_name)
        return(out_path)
    }

    dl_dir <- file.path(tempdir(), "ortho_dl")
    dir.create(dl_dir, showWarnings = FALSE, recursive = TRUE)

    message("[", Sys.getpid(), "] Downloading: ", tile_name)
    jp2_path <- tryCatch(
        download_ortho_tile(dl_url, ftp_url, dl_dir),
        error = function(e) {
            warning("Failed to download ", tile_name, ": ", e$message)
            NULL
        }
    )
    if (is.null(jp2_path)) return(NULL)

    message("[", Sys.getpid(), "] Reprojecting: ", tile_name)
    result <- tryCatch(
        reproject_ortho_tile(jp2_path, out_path),
        error = function(e) {
            warning("Failed to process ", tile_name, ": ", e$message)
            NULL
        }
    )

    # Clean up extracted contents to save disk space
    unlink(dirname(jp2_path), recursive = TRUE)
    result
}

###############################################################################
# Command-line execution
# Args: gpkg_path, cluster_number, year, output_dir, [bands]
#
# Example:
  # Rscript R_Code_Analysis/Ortho_ftp.R \
  #   "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
  #   208 \
  #   2020 \
  #   "Data/Ortho/Tiles" \
  #   4bd
###############################################################################
args <- c(
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
    "208",
    "2020",
    "Data/Ortho/Tiles", 
    "4bd"
)

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 4) {
    stop("Usage: Rscript Ortho_ftp.R <gpkg_path> <cluster> <year> <output_dir> [bands]")
}

gpkg_path   <- args[1]
cluster_num <- args[2]
year        <- args[3]
out_dir     <- args[4]
bands       <- if (length(args) >= 5) args[5] else "4bd"

message("=== NYS Orthoimagery Download Pipeline ===")
message("  GPKG:     ", gpkg_path)
message("  Cluster:  ", cluster_num)
message("  Year:     ", year)
message("  Bands:    ", bands)
message("  Output:   ", out_dir)
message("  Workers:  ", n_workers)

# Filter to all HUC12s in this cluster
cluster_hucs <- st_read(gpkg_path, quiet = TRUE) |>
    filter(cluster == cluster_num)
message("  HUC12s in cluster: ", nrow(cluster_hucs))

message("\nQuerying ortho tile indexes...")
tiles <- get_overlapping_ortho_tiles(cluster_hucs, year, bands)

if (is.null(tiles) || nrow(tiles) == 0) {
    stop("No overlapping ortho tiles found for cluster ", cluster_num,
         " (year ", year, ", bands ", bands, ")")
}

# Deduplicate by normalized tile name, drop partial/sliver tiles.
# Full ortho tiles are ~1.0-1.1M m^2; this keeps genuine partials out.
min_tile_area <- 800000
unique_tiles <- tiles |>
    as.data.frame() |>
    distinct(tile_name, .keep_all = TRUE) |>
    filter(Shape_Area >= min_tile_area)
message("Unique full-size tiles to process: ", nrow(unique_tiles))

if (!dir.exists(out_dir)) {
    dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
}

# Set up parallel workers (sequential if workers = 1)
if (n_workers > 1) {
    plan(future.callr::callr)
    message("Using ", n_workers, " parallel workers")
} else {
    plan(sequential)
}

results <- future_lapply(seq_len(nrow(unique_tiles)), function(idx) {
    process_ortho_tile(unique_tiles$tile_name[idx],
                       unique_tiles$dl_url[idx],
                       unique_tiles$ftp_url[idx],
                       out_dir)
}, future.seed = NULL)

plan(sequential)

n_success <- sum(!sapply(results, is.null))
message("\n=== Done. ", n_success, "/", nrow(unique_tiles),
        " tiles processed. Imagery written to: ", out_dir, " ===")

gc()
