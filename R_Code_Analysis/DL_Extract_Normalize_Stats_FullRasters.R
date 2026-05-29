### Compute global min/max band statistics across full HUC raster stacks
### Outputs a JSON file for use in the DL normalization pipeline.
###
### Stacks are assembled in memory per HUC via the shared huc_stack.R recipe
### (build_huc_stack_full) -- no saved *_stack.tif files are read, so the
### normalization stats stay in lock-step with the bands the chip/point
### pipelines produce, and source rasters are never duplicated on disk.
###
### Population: ALL HUCs in the requested cluster (from the cluster polygon),
### not just HUCs that happen to have training patches -- so the min/max ranges
### cover the full prediction domain the PyTorch model normalizes against.
###
### Usage:
###   Rscript DL_Extract_Normalize_Stats_FullRasters.R <cluster> <output_json>
### Example:
###   Rscript R_Code_Analysis/DL_Extract_Normalize_Stats_FullRasters.R 250 \
###         Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values.json

library(terra)
library(sf)
library(jsonlite)
library(future)
library(future.apply)

source("R_Code_Analysis/huc_stack.R")

args <- c("225", "Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values.json")

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2) {
  stop(
    "Usage: Rscript DL_Extract_Normalize_Stats_FullRasters.R <cluster> <output_json>"
  )
}

clusterSubset <- args[1]
output_json <- args[2]

cat("Cluster:", clusterSubset, "\n")
cat("Output :", output_json, "\n\n")

setGDALconfig("GDAL_PAM_ENABLED", "FALSE")

# --- Band configuration ------------------------------------------------------
# Bands that use min_max normalization (need global stats).
# shift_scale (NDVI, MNDWI, NDYI) and one_hot (Geomorph_local) are
# analytically defined in dl_band_config.json -- skip them here.
# MOD_CLASS is the label band -- also skip (and it is not in the predictor
# stack anyway; kept here for safety).
skip_bands <- c(
  "MOD_CLASS",
  "NDVI",
  "MNDWI",
  "NDYI",
  "EVI",
  "GDVI",
  "n_ndvi",
  "n_ndwi",
  "Geomorph_local"
)

# --- Discover all HUCs in the cluster ----------------------------------------
huc_poly <- sf::st_read(
  "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
  quiet = TRUE,
  query = paste0(
    "SELECT * FROM NY_Cluster_Zones_250_CROP_NAomit_6347 WHERE cluster = '",
    clusterSubset,
    "'"
  )
)
huc_numbers <- huc_poly$huc12

if (length(huc_numbers) == 0) {
  stop("No HUCs found for cluster ", clusterSubset)
}
cat("Found", length(huc_numbers), "HUCs in cluster", clusterSubset, "\n\n")

# --- Per-HUC min/max (streamed, no full load into RAM) -----------------------
per_huc_minmax <- function(huc_number) {
  source("R_Code_Analysis/huc_stack.R") # ensure recipe is available in callr workers
  setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
  # 4 callr workers share the per-task cgroup (mem-per-cpu * cpus-per-task);
  # cap each well under its ~1/4 share. minmax streams, so this is plenty.
  terraOptions(memfrac = 0.4, memmax = 16, tempdir = "Data/tmp")

  paths <- huc_source_paths(huc_number, clusterSubset)
  if (!huc_sources_ready(paths, huc_number)) {
    return(NULL)
  }

  # Stream minmax per source raster as-read (no align/resample/stack -- min/max
  # is grid-invariant, so resampling everything onto the DEM grid is pure waste
  # and is what OOMs build_huc_stack_full under parallel workers).
  tryCatch(huc_minmax(paths, skip = skip_bands), error = function(e) {
    message("minmax failed for HUC ", huc_number, ": ", conditionMessage(e))
    NULL
  })
}

# --- Parallel map ------------------------------------------------------------
slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")
corenum <- if (nzchar(slurm_cpus)) {
  as.integer(slurm_cpus)
} else {
  min(future::availableCores(), 2)
}
cat("Workers:", corenum, "\n")
options(future.globals.maxSize = 48.0 * 1e9)
plan(future.callr::callr, workers = corenum)

results <- future_lapply(
  huc_numbers,
  per_huc_minmax,
  future.seed = TRUE,
  future.packages = c("terra", "stringr", "tidyterra")
)
results <- Filter(Negate(is.null), results)

if (length(results) == 0) {
  stop("No HUCs produced statistics (all missing sources or failed).")
}

# --- Reduce: global min/max per band -----------------------------------------
target_bands <- names(results[[1]]$min)
global_mins <- setNames(rep(Inf, length(target_bands)), target_bands)
global_maxs <- setNames(rep(-Inf, length(target_bands)), target_bands)

for (res in results) {
  global_mins <- pmin(global_mins, res$min[target_bands], na.rm = TRUE)
  global_maxs <- pmax(global_maxs, res$max[target_bands], na.rm = TRUE)
}

cat(
  "\nComputed stats over",
  length(results),
  "HUCs for bands:\n  ",
  paste(target_bands, collapse = ", "),
  "\n"
)

# --- Build output list -------------------------------------------------------
stats_list <- lapply(target_bands, \(band) {
  list(
    band = band,
    min = unname(global_mins[band]),
    max = unname(global_maxs[band])
  )
})
names(stats_list) <- target_bands

# --- Write JSON --------------------------------------------------------------
dir.create(dirname(output_json), recursive = TRUE, showWarnings = FALSE)
write_json(stats_list, output_json, pretty = TRUE, auto_unbox = TRUE)

cat("\nGlobal band statistics written to:", output_json, "\n\nSummary:\n")
for (band in target_bands) {
  cat(sprintf(
    "  %-15s  min: %12.4f  max: %12.4f\n",
    band,
    global_mins[band],
    global_maxs[band]
  ))
}
