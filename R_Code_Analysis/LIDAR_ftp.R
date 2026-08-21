library(curl)
library(stringr)
library(sf)
library(dplyr)
library(lidR)
library(terra)
library(future)
library(future.apply)

# Print warnings as they happen. R's default (warn = 0) buffers them and
# collapses the tail into "There were 50 or more warnings", which threw away
# every per-tile download/metric failure reason in past runs.
options(warn = 1)

n_workers <- as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", unset = "1"))

nys_lidar_ftp <- "ftp://ftp.gis.ny.gov/elevation/LIDAR/"

# List FTP directory contents
list_ftp_dir <- function(ftp_url) {
    con <- curl(ftp_url, open = "r")
    on.exit(close(con))
    
    lines <- readLines(con)
    names <- str_extract(lines, "[^\\s]+$")
    is_dir <- str_detect(lines, "^d")
    
    tibble(
        name = names,
        is_directory = is_dir,
        full_path = paste0(ftp_url, names, ifelse(is_dir, "/", ""))
    )
}

# Download file to temp or specified location, with timeouts + retry so a
# stalled FTP transfer aborts instead of hanging the whole job (the NYS FTP
# server occasionally accepts the connection then stops sending data).
#   connecttimeout  : cap the initial connect (s)
#   low_speed_limit : bytes/sec floor ...
#   low_speed_time  : ... that must be sustained this long before curl aborts.
#     This catches true stalls without killing a large-but-progressing LAS
#     download (tiles can be hundreds of MB), which a flat `timeout` would.
#   timeout         : absolute per-tile backstop (s).
# Errors propagate after max_tries; process_tile()'s tryCatch turns that into a
# skipped tile + warning rather than a blocked job.
download_ftp_file <- function(ftp_url, dest_dir = tempdir(), max_tries = 3) {
    filename  <- basename(ftp_url)
    dest_path <- file.path(dest_dir, filename)

    for (attempt in seq_len(max_tries)) {
        h <- new_handle(
            connecttimeout  = 60,
            low_speed_limit = 1024,
            low_speed_time  = 120,
            timeout         = 3600
        )
        ok <- tryCatch({
            curl_download(ftp_url, dest_path, quiet = TRUE, handle = h)
            file.exists(dest_path) && file.size(dest_path) > 0
        }, error = function(e) {
            message("  download attempt ", attempt, "/", max_tries,
                    " failed for ", filename, ": ", conditionMessage(e))
            FALSE
        })
        if (ok) return(dest_path)
        unlink(dest_path)            # drop any partial file before retrying
        Sys.sleep(2 * attempt)       # linear backoff
    }
    stop("download failed after ", max_tries, " attempts: ", filename)
}

### Find tiles overlapping a set of HUC12 boundaries
# index_path: a per-collection index GPKG (from download_lidar_indexes.R) OR
#             the combined all-collections index (from build_lidar_index.R)
# huc12_sf: sf object with one or more HUC12 polygons
get_overlapping_tiles <- function(index_path, huc12_sf) {

    tile_index <- st_read(index_path, quiet = TRUE)

    # The combined index can carry empty geometries from the merge; drop them.
    tile_index <- tile_index[!st_is_empty(tile_index), ]

    # Transform HUC12s to match tile index CRS
    huc12_transformed <- st_transform(huc12_sf, st_crs(tile_index))

    # Find tiles intersecting ANY of the HUC12 polygons
    intersects_mat <- st_intersects(tile_index, huc12_transformed, sparse = FALSE)
    hits <- apply(intersects_mat, 1, any)
    overlapping <- tile_index[hits, ]

    if (nrow(overlapping) == 0) {
        warning("No overlapping tiles found in: ", index_path)
        return(NULL)
    }

    # Tile footprint area, computed from geometry: the per-collection indexes
    # carry a SHAPE.AREA column but the combined index does not, and computing
    # it makes the partial-tile filter work for both.
    overlapping$tile_area <- as.numeric(st_area(overlapping))

    # Build tile_name and ftp_url from DIRECT_DL
    # DIRECT_DL contains full HTTPS path including subdirectories
    # Convert to FTP: https://gisdata.ny.gov/ → ftp://ftp.gis.ny.gov/
    overlapping |>
        mutate(
            tile_name = as.character(FILENAME),
            ftp_url = str_replace(DIRECT_DL,
                                  "https://gisdata.ny.gov/",
                                  "ftp://ftp.gis.ny.gov/")
        )
}

# Per-pixel vegetation metrics function (top-level for lidR formula scoping)
veg_metrics <- function(z) {
    n <- length(z)
    #p95 <- quantile(z, 0.95)
    list(
        pct_below_1m = sum(z < 1) / n,
        pct_1m_to_5m  = sum(z >= 1 & z < 5) / n,
        pct_above_5m  = sum(z >= 5) / n
    )
}

### Compute lidar vegetation metrics for a single LAS tile
# Returns 4-band raster at 1m resolution in EPSG:6347:
#   Band 1: mean_intensity  — mean return intensity REMOVED
#   Band 2: pct_below_1m  — proportion of returns below 1m
#   Band 3: pct_1m_to_5m   — proportion of returns between 1m and 5m
#   Band 4: pct_above_5m   — proportion of returns between 2m and 95th percentile height
compute_lidar_metrics <- function(las_path, out_dir, res = 1) {

    las <- readLAS(las_path, filter = "-drop_withheld -drop_class 7 18")

    # Height-normalize using ground points (class 2) via TIN interpolation
    las <- normalize_height(las, tin())

    # Drop points with negative normalized heights (below-ground noise)
    las <- filter_poi(las, Z >= 0)

    metrics <- pixel_metrics(las, ~veg_metrics(z = Z), res = res)

    # Reproject to EPSG:6347 snapped to a global integer-meter grid so tiles
    # from different source CRSs land on a shared origin. Without this each
    # project() call anchors to the tile's own origin and mosaic() downstream
    # rejects the mismatched origins.
    target_crs <- "EPSG:6347"
    if (!same.crs(crs(metrics), target_crs)) {
        message("  Reprojecting from ", crs(metrics, describe = TRUE)$code, " to EPSG:6347")
        src_bbox <- as.polygons(ext(metrics), crs = crs(metrics))
        tgt_ext  <- ext(project(src_bbox, target_crs))
        snap_ext <- ext(floor(xmin(tgt_ext)), ceiling(xmax(tgt_ext)),
                        floor(ymin(tgt_ext)), ceiling(ymax(tgt_ext)))
        tmpl <- rast(snap_ext, resolution = res, crs = target_crs)
        metrics <- project(metrics, tmpl, method = "bilinear")
    }

    # Fill interior NA holes with 3x3 mean focal filter (edges unchanged)
    # Create a mask of valid pixels before filling so we don't expand the raster footprint
    valid_mask <- !is.na(metrics[[1]])
    valid_mask <- focal(valid_mask, w = matrix(1, 3, 3), fun = "mean")
    for (i in seq_len(nlyr(metrics))) {
        metrics[[i]] <- focal(metrics[[i]], w = matrix(1, 3, 3),
                              fun = "mean", na.rm = TRUE, na.policy = "only")
    }
    # Mask back to original footprint so edges don't expand
    metrics <- mask(metrics, valid_mask, maskvalues = 0)
    # Min-max normalize intensity to 0-1 (raw values vary across sensors/projects)
    # int_vals <- values(metrics[[1]], na.rm = TRUE)
    # int_min <- min(int_vals)
    # int_max <- max(int_vals)
    # if (int_max > int_min) {
    #     metrics[[1]] <- (metrics[[1]] - int_min) / (int_max - int_min)
    # } else {
    #     metrics[[1]] <- metrics[[1]] * 0  # constant value → set to 0
    # }
    # metrics[[1]] <- ifel(is.na(metrics[[1]]), 0, metrics[[1]]) # makes NA which is usually water 0 intensity
    # metrics[[1]] <- ifel(is.na(metrics[[1]]), 1, metrics[[1]])  # pct_below_1m → 1 for water/NA
    # metrics[[2]] <- ifel(is.na(metrics[[2]]), 0, metrics[[2]])  # pct_1m_to_5m → 0
    # metrics[[3]] <- ifel(is.na(metrics[[3]]), 0, metrics[[3]])  # pct_above_5m → 0
    set.names(metrics, c("pct_below_1m", "pct_1m_to_5m", "pct_above_5m"))
    # Write multi-band GeoTIFF
    tile_name <- tools::file_path_sans_ext(basename(las_path))
    out_path <- file.path(out_dir, paste0(tile_name, "_metrics.tif"))
    writeRaster(metrics, out_path, overwrite = TRUE)

    cat("Wrote:", out_path, "\n")
    out_path
}

### Touch the heartbeat file the shell watchdog in step_lidar_ftp.sh polls.
# Bumped at the start and end of every tile, so a stale mtime means no worker
# has made progress -- the signal the watchdog uses to kill a stalled step.
beat <- function(hb_file) {
    if (!is.null(hb_file) && nzchar(hb_file)) {
        try(file.create(hb_file, showWarnings = FALSE), silent = TRUE)
    }
    invisible(NULL)
}

### Process a single tile: download → compute metrics → clean up
process_tile <- function(tile_name, tile_url, out_dir, hb_file = NULL) {
    beat(hb_file)
    out_path <- file.path(out_dir, paste0(tools::file_path_sans_ext(tile_name), "_metrics.tif"))

    # Skip if already processed
    if (file.exists(out_path)) {
        message("[", Sys.getpid(), "] Skipping (exists): ", tile_name)
        return(out_path)
    }

    # Each worker gets its own download directory
    dl_dir <- file.path(tempdir(), "lidar_dl")
    dir.create(dl_dir, showWarnings = FALSE, recursive = TRUE)

    message("[", Sys.getpid(), "] Downloading: ", tile_name)
    las_path <- tryCatch(
        download_ftp_file(tile_url, dl_dir),
        error = function(e) {
            warning("Failed to download ", tile_name, ": ", e$message)
            return(NULL)
        }
    )
    if (is.null(las_path)) return(NULL)

    message("[", Sys.getpid(), "] Computing metrics: ", tile_name)
    result <- tryCatch(
        compute_lidar_metrics(las_path, out_dir),
        error = function(e) {
            warning("Failed to process ", tile_name, ": ", e$message)
            return(NULL)
        }
    )

    # Clean up raw LAS to save disk space
    unlink(las_path)
    beat(hb_file)
    result
}

###############################################################################
# Command-line execution
# Args: gpkg_path, cluster_number, index_path, output_dir
#
# index_path is normally the COMBINED index (all collections, built by
# build_lidar_index.R) so every tile overlapping the cluster is processed in
# one run; pass a single collection's gpkg from Data/Lidar/Indexes/ instead
# for a targeted re-run.
#
# Example (combined index, used by step_lidar_ftp.sh):
  # Rscript R_Code_Analysis/LIDAR_ftp.R \
  #   "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" \
  #   208 \
  #   "Data/Lidar/NYS_Lidar_All_Indexes.gpkg" \
  #   "Data/Lidar/Metrics"
###############################################################################
args <- c("Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
              82,
              "Data/Lidar/Indexes/FEMA_2019.gpkg",
              "Data/Lidar/Metrics")

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 4) {
    stop("Usage: Rscript Lidar_ftp.R <gpkg_path> <cluster> <index_path> <output_dir> [heartbeat_file]")
}

gpkg_path   <- args[1]
cluster_num <- args[2]
index_path  <- args[3]
out_dir     <- args[4]
# Optional 5th arg: file whose mtime this script bumps on every tile so the
# watchdog in step_lidar_ftp.sh can tell "still working" from "hung".
hb_file     <- if (length(args) >= 5) args[5] else ""

# Per-cluster record of tiles that produced no output, so a re-run can be
# targeted instead of re-walking the whole cluster.
log_dir     <- if (dir.exists("Shell_Scripts/logs")) "Shell_Scripts/logs" else out_dir
failed_file <- file.path(log_dir,
                         paste0("lidar_ftp_", cluster_num, "_failed_tiles.txt"))
# if (future::availableCores() > 16) {
#     n_workers <- 1
# } else {
#     n_workers <- future::availableCores()
# }

message("=== Lidar Metrics Pipeline ===")
message("  GPKG:        ", gpkg_path)
message("  Cluster:     ", cluster_num)
message("  Tile Index:  ", index_path)
message("  Output:      ", out_dir)
message("  Workers:     ", n_workers)

# Filter to all HUC12s in this cluster
cluster_hucs <- st_read(gpkg_path, quiet = TRUE) |>
    filter(cluster == cluster_num)
message("  HUC12s in cluster: ", nrow(cluster_hucs))

# Find overlapping tiles from local index
message("\nFinding overlapping tiles...")
tile_index_info <- get_overlapping_tiles(index_path, cluster_hucs)

if (is.null(tile_index_info) || nrow(tile_index_info) == 0) {
    stop("No overlapping tiles found for cluster ", cluster_num)
}

# Deduplicate tiles and filter out partial/small tiles. The same FILENAME can
# appear in several collections of the combined index; distinct() keeps one.
min_tile_area <- 500000  # most tiles are 2250000 m^2 but size varies by collection
unique_tiles <- tile_index_info |>
    as.data.frame() |>
    distinct(tile_name, .keep_all = TRUE) |>
    filter(tile_area >= min_tile_area)
message("Unique full-size tiles to process: ", nrow(unique_tiles))

# Create output directory
if(!dir.exists(out_dir)){
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
}


# Set up parallel workers (sequential if workers = 1)
if (n_workers > 1) {
    plan(future.callr::callr)
    message("Using ", n_workers, " parallel workers")
} else {
    plan(sequential)
}

# Process all tiles (ftp_url already built by get_overlapping_tiles).
#
# Chunked on purpose: future_lapply aborts the ENTIRE run if a single parallel
# worker dies (a segfaulting callr subprocess took out all 1085 tiles of
# cluster 1 on 2026-08-18). Wrapping each chunk means one crash costs at most
# `chunk_size` tiles, and the backend is rebuilt before continuing. Tiles
# already on disk are skipped, so nothing is redone on the next pass.
beat(hb_file)
n_tiles    <- nrow(unique_tiles)
chunk_size <- max(4L * n_workers, 16L)
chunks     <- split(seq_len(n_tiles), ceiling(seq_len(n_tiles) / chunk_size))
results    <- vector("list", n_tiles)

for (ci in seq_along(chunks)) {
    ids <- chunks[[ci]]
    out <- tryCatch(
        future_lapply(ids, function(idx) {
            process_tile(unique_tiles$tile_name[idx], unique_tiles$ftp_url[idx],
                         out_dir, hb_file)
        }, future.seed = NULL),
        error = function(e) {
            message("!! chunk ", ci, "/", length(chunks),
                    " (tiles ", min(ids), "-", max(ids), ") failed: ",
                    conditionMessage(e))
            # A dead worker poisons the backend; stand a fresh one up.
            if (n_workers > 1) {
                try(plan(sequential), silent = TRUE)
                try(plan(future.callr::callr), silent = TRUE)
            }
            vector("list", length(ids))
        }
    )
    results[ids] <- out
}

# Reset to sequential
try(plan(sequential), silent = TRUE)

failed <- unique_tiles$tile_name[vapply(results, is.null, logical(1))]
if (length(failed)) {
    writeLines(failed, failed_file)
    message("!! ", length(failed), " tiles produced no output. Names written to: ",
            failed_file)
} else if (file.exists(failed_file)) {
    unlink(failed_file)          # clean slate once a cluster is fully covered
}

n_success <- n_tiles - length(failed)
message("\n=== Done. ", n_success, "/", n_tiles,
        " tiles processed. Metrics written to: ", out_dir, " ===")

# Hard exit. Every raster is already written; R's normal shutdown has been
# observed to hang here waiting on lingering future.callr worker processes,
# which left the srun step (and therefore the whole batch job) alive doing
# nothing. runLast = FALSE skips .Last and finalizers.
flush(stdout()); flush(stderr())
beat(hb_file)
quit(save = "no", status = 0, runLast = FALSE)
