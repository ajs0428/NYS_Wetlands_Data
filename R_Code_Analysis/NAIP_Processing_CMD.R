#!/usr/bin/env Rscript

args = c(
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
    22,
    "Data/NAIP/HUC_NAIP_Processed/"
)
args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

clusterPath <- args[1]
clusterSubset <- args[2]
outputPath <- args[3]
# Optional 4th arg: comma-separated huc12 ids to restrict the run to. Lets a
# single bad HUC be re-run on its own budget without re-walking the cluster.
hucSubset <- if (length(args) >= 4 && nzchar(args[4]))
                 trimws(strsplit(args[4], ",")[[1]]) else NULL

message("these are the arguments: \n",
     "- Path to cluster:", clusterPath, "\n",
     "- Cluster:", clusterSubset, "\n",
     "- Path to NAIP Processed:", outputPath, "\n",
     "- HUC subset:", if (is.null(hucSubset)) "(all)" else paste(hucSubset, collapse = ","), "\n"
)

###############################################################################################

library(terra)
library(sf)
suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(tidyterra))
library(future)
library(future.apply)

terraOptions(tempdir = "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp")
print(tempdir())
setGDALconfig("GDAL_PAM_ENABLED", "FALSE") # does not create aux.xml files
###############################################################################################

#Index of all NAIP tiles
naip_index <- st_read("Data/NAIP/noaa_digital_coast_2017/tileindex_NY_NAIP_2017.shp", quiet = TRUE) |> 
    st_transform(st_crs("EPSG:6347"))

#Cluster of HUCs
cluster_target <- sf::st_read(clusterPath, quiet = TRUE) |> 
    dplyr::filter(cluster == clusterSubset) 
cluster_crs <- st_crs(cluster_target)
# unique(): a huc12 can occupy several gpkg rows (split MULTIPOLYGONs) — iterate
# each HUC once (the per-HUC crop/mask still uses all of its rows).
cluster_hucs <- unique(cluster_target[["huc12"]])
if (!is.null(hucSubset)) {
    missing_hucs <- setdiff(hucSubset, cluster_hucs)
    if (length(missing_hucs)) stop("huc(s) not in cluster ", clusterSubset, ": ",
                                   paste(missing_hucs, collapse = ","))
    cluster_hucs <- hucSubset
}

#Filter for NAIP tiles in Cluster
naip_int_cluster <- st_filter(naip_index, cluster_target, .predicate = st_intersects)
# plot(naip_int_cluster)


###############################################################################################

# This should take a list of all the NAIP rasters, merge them together in a HUC,
# crop to HUC boundaris, calculate indices, export and write to file

vi2 <- function(r, g, nir) {
    return(
        c(((nir - r) / (nir + r)), ((g-nir)/(g+nir)))
    )
}

TERRA_TMP <- "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp"

# GDAL creation options for anything that can cross 4 GiB. Same recipe as the
# final product so an intermediate is never the slower/fatter format.
BIG_GDAL <- c("COMPRESS=DEFLATE", "PREDICTOR=2", "TILED=YES",
              "BLOCKXSIZE=512", "BLOCKYSIZE=512", "BIGTIFF=YES", "NUM_THREADS=2")

# terra's own temp rasters are *classic* TIFF written with no creation options,
# so they die at 4 GiB. GDAL reports it as
#   "TIFFAppendToStrip:Maximum TIFF file size exceeded. Use BIGTIFF=YES"
# and terra then either errors ("[mask] cannot read from .../spat_*.tif",
# which killed cluster 119 huc 020302020405 and cluster 163 huc 020200070502
# in job 786402) or spins retrying forever - step 786402.4077 sat on cluster
# 154 huc 041300030203 for four days at 100% CPU, 347 billion read syscalls,
# writes frozen at exactly 4 GiB.
#
# A 4-band FLT4S intermediate crosses 4 GiB at 268M cells, and 60 of the HUCs
# still to process are within 10% of that, so the multi-band intermediates get
# an explicit BIGTIFF file instead of a terra temp. Gate on the estimated
# payload rather than forcing it always: below the threshold terra keeps the
# raster in memory and a forced filename would be a pure round-trip to disk.
#
# 3 GiB, not 4: the ceiling applies to the file, and the estimate ignores
# header/tag overhead and any FLT8S promotion.
BIG_SPILL_BYTES <- 3 * 1024^3

spill_to <- function(scratch, tag, ncells, nlyrs, bytes_per_cell = 4) {
    if (as.numeric(ncells) * nlyrs * bytes_per_cell > BIG_SPILL_BYTES)
        file.path(scratch, paste0(tag, ".tif")) else ""
}

# Cells the mosaic will span: sprc()/mosaic() covers the *union* of the tile
# extents, which snap="out" can push a tile-margin past the DEM, so measure it
# rather than reusing ncell(dem).
union_ncell <- function(tiles) {
    u <- terra::ext(tiles[[1]])
    for (t in tiles[-1]) u <- terra::union(u, terra::ext(t))
    rs <- terra::res(tiles[[1]])
    ceiling((u$xmax - u$xmin) / rs[1]) * ceiling((u$ymax - u$ymin) / rs[2])
}

# "Done" means a file that opens as a raster, not merely a file that exists.
done_already <- function(target_file) {
    if (!file.exists(target_file)) return(FALSE)
    if (isTRUE(file.size(target_file) == 0)) {
        message("removing 0-byte output from an interrupted run: ", target_file)
        unlink(target_file)
        return(FALSE)
    }
    ok <- tryCatch({ terra::rast(target_file); TRUE }, error = function(e) FALSE)
    if (!ok) {
        message("removing unreadable output from an interrupted run: ", target_file)
        unlink(target_file)
    }
    ok
}

# terra cap derived from the SLURM per-task cgroup so it tracks the SBATCH
# directives, not node RAM. step_naip.sh exports the budget as TASK_MEM_MB and
# strips SLURM_MEM_PER_CPU from each srun's env (via `env -u`) so terra sizes to
# the per-task budget, not the node; we split TASK_MEM_MB across the callr
# workers (= SLURM_CPUS_PER_TASK).
#
# The headroom fraction is 0.60, not the 0.85 used before: memmax caps terra
# inside the *callr worker*, but the cgroup also has to hold the parent R
# session (NAIP tile index + cluster sf + exported globals) and GDAL's own
# block cache / DEFLATE buffers, none of which terra counts. At 0.85 that
# overspill killed 31 of 74 clusters in job 786391 with MaxRSS pinned at the
# 64 GiB ceiling. Falls back to 28 GB off-SLURM (local runs).
.task_mem_gb <- as.numeric(Sys.getenv("TASK_MEM_MB", "0")) / 1024
.n_workers   <- max(1L, as.integer(Sys.getenv("SLURM_CPUS_PER_TASK", "1")))
memmax_gb    <- if (.task_mem_gb > 0)
                    max(4L, as.integer(floor(.task_mem_gb * 0.60 / .n_workers))) else 28L

process_huc_one <- function(huc_num) {
    setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
    # Per-worker terra cap from the cgroup (see memmax_gb above).
    terra::terraOptions(
        tempdir = TERRA_TMP,
        memmax = memmax_gb
    )
    target_file <- paste0(outputPath, "cluster_", clusterSubset, "_huc_", huc_num, "_NAIP_metrics.tif")
    dem_filename <- paste0("Data/TerrainProcessed/HUC_DEMs", "/cluster_", clusterSubset, "_huc_", huc_num, ".tif")
    huc <- cluster_target[cluster_target$huc12 == huc_num, ]

    # Scratch for the forced-BIGTIFF intermediates (see spill_to() above). Torn
    # down on every exit path, including the error that process_huc catches.
    scratch <- file.path(TERRA_TMP,
                         paste0("naip_int_", clusterSubset, "_", huc_num, "_", Sys.getpid()))
    on.exit(unlink(scratch, recursive = TRUE, force = TRUE), add = TRUE)

    # A cancelled job (SIGKILL) leaves a 0-byte or header-truncated target
    # behind that the old bare file.exists() then treated as done forever -
    # job 786391 left cluster_78_huc_020501040408 and
    # cluster_249_huc_020501010908 at 0 bytes and 786402 duly logged "NAIP
    # already processed" for them. Only a file that actually opens as a raster
    # counts as done; anything else is removed and rebuilt.
    if (!done_already(target_file)) {
        message("no NAIP processed yet for: ", target_file)
        dir.create(scratch, showWarnings = FALSE, recursive = TRUE)
        if (!file.exists(dem_filename)) {
            warning("no DEM for HUC ", huc_num, " - skipping")
            return(NULL)
        }
        dem_rast <- terra::rast(dem_filename)
        naip_tiles_huc <- st_filter(naip_int_cluster, huc)
        huc_vect <- vect(huc)
        #re-paste the file path to rasters
        naip_int_cluster_rast_locs <- paste0("Data/NAIP/noaa_digital_coast_2017/", naip_tiles_huc$location)

        # NAIP tiles are NAD83 UTM and NY spans zones 17/18/19, so the 29 HUCs on
        # a zone boundary pull tiles in two different CRSs. sprc()/mosaic() does
        # NOT reproject - it unions the raw extents, so zone-17 eastings land
        # ~450 km from zone-18 ones. That yields a ~14-billion-cell phantom
        # mosaic that effectively never finishes, and the imagery that survives
        # the later crop covers as little as 2% of the HUC.
        #
        # So warp every tile onto the DEM grid BEFORE mosaicking: mosaic() then
        # only ever sees one CRS and one alignment. Cropping each tile in its own
        # native CRS first keeps the warp cheap, and targeting a DEM-derived
        # template replaces the old project(res=1) + resample(dem) double pass.
        tiles <- lapply(seq_along(naip_int_cluster_rast_locs), function(i) {
            p  <- naip_int_cluster_rast_locs[i]
            r  <- terra::rast(p)
            hv <- terra::project(huc_vect, terra::crs(r))
            if (is.null(terra::intersect(terra::ext(r), terra::ext(hv)))) return(NULL)
            cr <- terra::crop(r, hv, snap = "out")
            if (terra::ncell(cr) == 0) return(NULL)
            # Template = the DEM cropped to this tile's footprint, so each
            # projected tile is already snapped to the DEM's grid.
            #
            # The guard above only tests tile-vs-HUC-polygon; the DEM often
            # covers less than the polygon, so a tile can touch the HUC and
            # still miss the DEM entirely. crop() THROWS "[crop] extents do
            # not overlap" in that case - it never returns the empty raster
            # the ncell() check below was waiting for - and future_lapply
            # cancels every remaining iteration, so a single stray tile used
            # to take the whole cluster down with it (137 and 151 wrote zero
            # files in job 786391). Test the extents ourselves first.
            pe <- terra::project(terra::ext(cr), terra::crs(cr),
                                 terra::crs(dem_rast))
            if (is.null(terra::intersect(pe, terra::ext(dem_rast)))) return(NULL)
            tmpl <- terra::crop(dem_rast, pe, snap = "out")
            if (terra::ncell(tmpl) == 0) return(NULL)
            # Land every projected tile on disk rather than in RAM. terra holds
            # in-memory cells as doubles, so one 46M-cell NAIP tile costs
            # 46e6 x 4 bands x 8 B = 1.5 GB and the list is held until mosaic()
            # is done - that aggregate, not any single raster, is what OOM'd
            # cluster 140 huc 042900010407 (MaxRSS 95.78G against a 96G cgroup;
            # its DEM is 52,074 x 43,500 = 2.27e9 cells because the HUC's bbox
            # is 52 x 43.5 km even though the polygon is only 264 km2).
            # File-backed tiles make peak RAM independent of tile count, and
            # mosaic() streams them back block by block.
            terra::project(cr, tmpl, method = "bilinear",
                           filename = file.path(scratch, sprintf("tile_%03d.tif", i)),
                           overwrite = TRUE, gdal = BIG_GDAL)
        })
        tiles <- Filter(Negate(is.null), tiles)
        if (length(tiles) == 0) {
            warning("no NAIP tiles overlap HUC ", huc_num, " - skipping")
            return(NULL)
        }

        # Every multi-band step below can cross the 4 GiB classic-TIFF ceiling,
        # so each one gets an explicit BIGTIFF target when spill_to() judges it
        # big enough; "" hands the decision back to terra (in-memory or its own
        # temp), which is safe below the threshold.
        n <- if (length(tiles) == 1) tiles[[1]] else
                 terra::mosaic(terra::sprc(tiles), fun = "max",
                               filename = spill_to(scratch, "mosaic",
                                                   union_ncell(tiles), 4),
                               overwrite = TRUE, gdal = BIG_GDAL)
        # mosaic() spans the tile union; snap back to the DEM's exact extent.
        # crop(extend=TRUE) does the old crop()+extend() pair in one pass, so
        # there is one fewer 4-band intermediate to write and re-read.
        dem_cells <- terra::ncell(dem_rast)
        n <- terra::crop(n, dem_rast, extend = TRUE,
                         filename = spill_to(scratch, "cropext", dem_cells, 4),
                         overwrite = TRUE, gdal = BIG_GDAL)
        n <- terra::mask(n, huc_vect,
                         filename = spill_to(scratch, "masked", dem_cells, 4),
                         overwrite = TRUE, gdal = BIG_GDAL)
        np <- vi2(n[[1]], n[[2]], n[[4]])
        # vi2()'s own single-band arithmetic only reaches 4 GiB past 1.07e9
        # cells, but its 2-band result reaches it at 537M, so pin that one too.
        np_file <- spill_to(scratch, "indices", dem_cells, 2)
        if (nzchar(np_file))
            np <- terra::writeRaster(np, np_file, overwrite = TRUE, gdal = BIG_GDAL)
        nall <- c(n, np)
        set.names(nall, c("r", "g", "b", "nir", "ndvi", "ndwi"))

        # Tiled + DEFLATE/predictor: smaller than the old line-striped LZW and far
        # better for the windowed reads in Raster_ChipsPatches_DL.R.
        #
        # BIGTIFF=YES is required, not optional: terra emits a *classic* TIFF
        # by default (verified - magic 4949 2a00), which dies at 4 GiB. Six
        # FLT4S bands cross that at ~180M cells, and 15 of the HUCs still to
        # process are bigger than that.
        #
        # NUM_THREADS is a fixed 2 rather than ALL_CPUS: the srun cgroup grants
        # 1 CPU, so ALL_CPUS made GDAL spawn a thread per *node* core (128),
        # each with its own deflate buffer - all memory cost, no speedup.
        writeRaster(nall,
                    filename = target_file,
                    overwrite = TRUE,
                    gdal = c("COMPRESS=DEFLATE", "PREDICTOR=2", "TILED=YES",
                             "BLOCKXSIZE=512", "BLOCKYSIZE=512",
                             "BIGTIFF=YES", "NUM_THREADS=2"))
        rm(n)
        rm(np)
        rm(nall)
        rm(tiles)
        gc()
    } else {
        message("NAIP already processed for: ", target_file)
    }
    
    return(NULL)  
}

# future_lapply cancels EVERY remaining iteration as soon as one raises, so an
# unguarded per-HUC failure throws away the whole cluster's work - in job 786391
# clusters 137 and 151 finished with zero files because one tile in one HUC
# errored. Catch here so a bad HUC costs only that HUC.
#
# A failed writeRaster can leave a truncated target_file behind, and the
# file.exists() guard at the top would then treat it as done forever, so remove
# it before returning.
process_huc <- function(huc_num) {
    tryCatch(
        process_huc_one(huc_num),
        error = function(e) {
            target_file <- paste0(outputPath, "cluster_", clusterSubset,
                                  "_huc_", huc_num, "_NAIP_metrics.tif")
            if (file.exists(target_file)) {
                message("removing partial output: ", target_file)
                unlink(target_file)
            }
            message("FAILED HUC ", huc_num, ": ", conditionMessage(e))
            NULL
        }
    )
}

###############################################################################################

slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
  corenum <- as.integer(slurm_cpus)
} else {
  corenum <- min(future::availableCores(), 4)
}
options(future.globals.maxSize= 64 * 1e9)
# plan(multisession, workers = corenum)
plan(future.callr::callr, workers = corenum)

# Run with future_lapply
future_lapply(
    cluster_hucs,
    FUN = process_huc,
    future.packages = c("terra", "sf", "dplyr"),
    future.seed = TRUE,
    # TRUE (auto-detect), not an explicit list: detection walks process_huc into
    # process_huc_one and picks up everything it closes over.
    future.globals = TRUE
    # future.globals = list(
    #     args = args,
    #     cluster_target = cluster_target,
    #     cluster_crs = cluster_crs,
    #     naip_int_cluster = naip_int_cluster,
    #     vi2 = vi2
    # )
)

gc()

# lapply(cluster_hucs, FUN = process_huc)