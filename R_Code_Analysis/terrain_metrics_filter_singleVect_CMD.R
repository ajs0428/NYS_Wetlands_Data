#!/usr/bin/env Rscript

args = c(22,
         "Data/TerrainProcessed/HUC_DEMs/",
         "slp",
         "Data/TerrainProcessed/HUC_TerrainMetrics/"
)
args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

CLUSTER <- args[1]
HUC_DEMs <- args[2]
METRIC <- args[3]
OUTPUT <- args[4]

cat("these are the arguments: \n",
    "- Cluster number (integer 1-200ish):", CLUSTER, "\n",
    "- Path to the DEMs in TerrainProcessed folder", HUC_DEMs, "\n",
    "- Metric (slp -- the single combined terrain stack):", METRIC, "\n",
    "- Path to the Save folder", OUTPUT, "\n"
)

###############################################################################################
library(terra)
library(sf)
library(MultiscaleDTM)
library(stringr)


setGDALconfig("GDAL_PAM_ENABLED", "FALSE") # does not create aux.xml files

# SLURM allocates 96 GB / 1 core per task — no in-script parallelism needed.
# Per-PID tempdir under the shared tmp root so concurrent jobs don't trample
# each other's terra spillover files (terra's tmpFiles() does not filter by
# session, so a sibling job's cleanup can delete in-progress spat_*.tif files
# belonging to another job).
tmp_root <- "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp"
tmp_session <- file.path(tmp_root, paste0("terrain_", METRIC, "_", Sys.getpid()))
dir.create(tmp_session, recursive = TRUE, showWarnings = FALSE)
# terra cap derived from the SLURM per-task cgroup so it tracks the SBATCH
# directives, not node RAM. step_terrain.sh unsets SLURM_MEM_PER_CPU before
# srun, so it re-exports the budget as TASK_MEM_MB. This step is single-process
# (no in-script parallelism), so the whole task budget goes to terra, less ~15%
# headroom. Falls back to 80 GB off-SLURM (local runs).
.task_mem_gb <- as.numeric(Sys.getenv("TASK_MEM_MB", "0")) / 1024
memmax_gb    <- if (.task_mem_gb > 0) max(4L, as.integer(floor(.task_mem_gb * 0.85))) else 80L
terraOptions(memmax = memmax_gb, tempdir = tmp_session)

###############################################################################################
### BAND CONTRACT
###
### One combined terrain raster per HUC:
###   <OUTPUT>/cluster_<n>_huc_<hucid>_terrain_slp_local.tif
###
### Multiscale filtering (aggregate -> cubicspline resample at 5/100/500 m) was
### removed 2026-07: only the unsmoothed "local" scale was ever written, and the
### 100m/500m calls had been commented out for a year. Every metric is now
### computed directly on the HUC DEM. The "_local" filename/band suffix is kept
### even though there is no longer a second scale to distinguish it from —
### huc_stack.R and check_stack_ready.sh select the terrain file with a
### "slp" + "local" filename filter, and DL_Extract_Normalize_Stats_FullRasters.R
### keys its one-hot skip on the band name "Geomorph_local".
###
### meanc (mean curvature, MultiscaleDTM::Qfit) and dmv (deviation from mean
### elevation, MultiscaleDTM::DMV) were folded back in 2026-07 as extra bands of
### this same file rather than the separate curv/dmv metrics they used to be.
### Plan (planc) and profile (profc) curvature are deliberately NOT produced.
### TPI_local is part of the stack as of 2026-07 (huc_stack.R used to drop it).
###
### This vector is mirrored (with a pointer comment) by:
###   - R_Code_Analysis/huc_stack.R          terr_expected_bands()
###   - R_Code_Analysis/Pipeline_Check_CMD.R (via huc_stack.R)
###   - Shell_Scripts/check_stack_ready.sh   TERR_BANDS
### Change it here first, then update those.
SCALE_LABEL   <- "local"
TERRAIN_BANDS <- paste0(c("slope", "TPI", "Geomorph", "meanc", "dmv"),
                        "_", SCALE_LABEL)

# Window sizes, in DEM cells, for the MultiscaleDTM metrics.
# DMV_W is deliberately much wider than the 3x3 the old dmv metric used: at
# w = 3x3 on a 1 m DEM, DMV (elevation minus the window mean) is numerically
# identical to terra's TPI (elevation minus the mean of the 8 neighbours) —
# measured r = 1.0000 on a test HUC — so it carried no information TPI did not.
# At 21x21 it is a broader-context deviation and the two bands are independent
# predictors: TPI_local is pit/peak roughness, dmv_local is position relative to
# the surrounding ~20 m of terrain (the scale wetland depressions sit at).
CURV_W <- c(3, 3)     # Qfit window for mean curvature (local surface fit)
DMV_W  <- c(21, 21)   # DMV window (~21 m on a 1 m DEM)

# Geomorphon parameters (unchanged from the previous slp branch).
GEOMORPH_SEARCH     <- 100    # metres
GEOMORPH_SKIP       <- 10
GEOMORPH_FLAT_ANGLE <- 1.5    # degrees

if (!identical(METRIC, "slp")) {
    stop("METRIC must be 'slp'. Curvature (meanc) and DMV are no longer separate\n",
         "  metrics — they are bands of the combined terrain stack. Got: '", METRIC, "'")
}
###############################################################################################

# A terrain file is up to date only if its band names match the contract above.
# Plain file.exists() is not enough: the 2026-07 change added meanc/dmv, so
# every pre-existing 3-band *_terrain_slp_local.tif has to be rebuilt.
# Set FORCE_TERRAIN=1 to rebuild regardless.
terrain_up_to_date <- function(output_file) {
    force <- Sys.getenv("FORCE_TERRAIN", "0")
    if (nzchar(force) && !force %in% c("0", "false", "FALSE")) return(FALSE)
    if (!file.exists(output_file)) return(FALSE)

    got <- tryCatch(names(rast(output_file)), error = function(e) character(0))
    if (identical(got, TERRAIN_BANDS)) return(TRUE)

    message("Rebuilding (band contract mismatch): ", basename(output_file),
            "\n    on disk : ", paste(got, collapse = ", "),
            "\n    expected: ", paste(TERRAIN_BANDS, collapse = ", "))
    FALSE
}

build_terrain <- function(dem_path, output_file) {
    setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
    if (terrain_up_to_date(output_file)) {
        message("terrain stack already current, skipping: ", basename(output_file))
        return(invisible(NULL))
    }

    message("Creating terrain stack for: ", output_file)
    dem_rast <- rast(dem_path)

    # slope + TPI (fine-scale pit/peak roughness; complements the wider dmv)
    slp <- terra::terrain(dem_rast, v = c("slope", "TPI"))

    # geomorphon landform classes (categorical; one-hot encoded downstream)
    system.time({
        sg <- rgeomorphon::geomorphons(elevation = dem_rast,
                                       search = GEOMORPH_SEARCH,
                                       use_meters = TRUE,
                                       skip = GEOMORPH_SKIP,
                                       flat_angle_deg = GEOMORPH_FLAT_ANGLE)
    })

    # mean curvature only — planc/profc are intentionally not produced
    meanc <- MultiscaleDTM::Qfit(dem_rast, w = CURV_W,
                                 metrics = c("meanc"), include_scale = FALSE)

    # Deviation from mean elevation over DMV_W.
    # na.rm = TRUE is required at this window size: the HUC DEMs are masked to
    # the watershed, so with the default na.rm = FALSE every cell within
    # DMV_W/2 (10 cells) of the mask edge or any internal nodata hole comes back
    # NA — 18% of valid DEM cells on a test tile, versus 2% for the 3x3 metrics.
    # It only fills that collar: where both settings are defined the values are
    # bit-identical (max abs diff = 0), so interior pixels are unaffected.
    dmv <- MultiscaleDTM::DMV(dem_rast, w = DMV_W, stand = "none",
                              na.rm = TRUE, include_scale = FALSE)

    terr_stack <- c(slp, sg, meanc, dmv)
    stopifnot(nlyr(terr_stack) == length(TERRAIN_BANDS))

    writeRaster(terr_stack,
                filename = output_file,
                overwrite = TRUE,
                names = TERRAIN_BANDS)

    rm(slp, sg, meanc, dmv, terr_stack, dem_rast)
    gc(verbose = FALSE)

    return(invisible(NULL))
}


###############################################################################################

terrain_function <- function(dem_path, metric) {
    setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
    cluster_huc_name <- str_remove(basename(dem_path), "\\.tif$")
    message(paste0("\n=== Processing: ", cluster_huc_name, " ==="))

    output_file <- paste0(OUTPUT, cluster_huc_name, "_terrain_", metric,
                          "_", SCALE_LABEL, ".tif")

    tryCatch({
        build_terrain(dem_path, output_file)
    }, error = function(e) {
        message(paste0("ERROR at: ", cluster_huc_name, " - ", e$message))
        return(NA)
    })

    # Cleanup
    gc(verbose = FALSE)
    tmpFiles(remove = TRUE)

    return(invisible(NULL))
}
###############################################################################################

list_of_huc_dems <- list.files(
    HUC_DEMs,
    pattern = paste0("^cluster_", CLUSTER, "_.*\\.tif$"),
    full.names = TRUE
) |> str_subset(pattern = "wbt", negate = TRUE)

message(paste0("Found ", length(list_of_huc_dems), " DEMs to process"))

###############################################################################################

lapply(list_of_huc_dems, terrain_function, metric = METRIC)

# Clean up this job's private tempdir on success.
unlink(tmp_session, recursive = TRUE, force = TRUE)
