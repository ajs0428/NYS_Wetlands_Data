### Compute global min/max band statistics across HUC raster stacks
### Outputs a JSON file for use in the DL normalization pipeline
###
### Usage:
###   Rscript compute_global_band_stats.R <stack_dir> <output_json>
###
### Example:
###   Rscript R_Code_Analysis/DL_Raster_Normalize_Extract.R Data/HUC_Raster_Stacks/HUC_DL_Stacks/ \
###         Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values.json

library(terra)
library(jsonlite)

args <- c("Data/HUC_Raster_Stacks/HUC_DL_Stacks/",
          "Data/HUC_Raster_Stacks/HUC_DL_Stacks_Extracted_Values.json")

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2) {
  stop("Usage: Rscript compute_global_band_stats.R <stack_dir> <output_json>")
}

stack_dir <- args[1]
output_json <- args[2]

# --- Band configuration ---
# Bands that use min_max normalization (need global stats).
# shift_scale (NDVI, MNDWI, NDYI) and one_hot (Geomorph_local) are
# analytically defined in dl_band_config.json — skip them here.
# MOD_CLASS is the label band — also skip.
skip_bands <- c("MOD_CLASS", "NDVI", "MNDWI", "NDYI", "EVI", "GDVI",
                "n_ndvi","n_ndwi", "Geomorph_local")

# --- Discover stack files ---
stack_files <- list.files(stack_dir, pattern = "\\.tif$", full.names = TRUE)

if (length(stack_files) == 0) {
  stop("No .tif files found in ", stack_dir)
}

cat("Found", length(stack_files), "stack files\n")

# --- Initialize from first file ---
r1 <- rast(stack_files[1])
all_bands <- names(r1)
target_bands <- setdiff(all_bands, skip_bands)

cat("All bands:", paste(all_bands, collapse = ", "), "\n")
cat("Computing stats for:", paste(target_bands, collapse = ", "), "\n")
cat("Skipping (non min_max):", paste(intersect(all_bands, skip_bands), collapse = ", "), "\n\n")

global_mins <- setNames(rep(Inf, length(target_bands)), target_bands)
global_maxs <- setNames(rep(-Inf, length(target_bands)), target_bands)

# --- Iterate over stacks ---
for (f in stack_files) {
  cat("Processing:", basename(f), "\n")
  r <- rast(f)
  
  # Subset to target bands
  r_sub <- r[[target_bands]]
  
  # minmax(compute = TRUE) forces calculation from pixel values if
  # the metadata doesn't already store them. This reads the raster
  
  # but does NOT load it entirely into RAM — terra streams it.
  mm <- minmax(r_sub, compute = TRUE)
  
  global_mins <- pmin(global_mins, mm["min", ])
  global_maxs <- pmax(global_maxs, mm["max", ])
}

# --- Build output list ---
stats_list <- lapply(target_bands, \(band) {
  list(
    band = band,
    min  = unname(global_mins[band]),
    max  = unname(global_maxs[band])
  )
})
names(stats_list) <- target_bands

# --- Write JSON ---
dir.create(dirname(output_json), recursive = TRUE, showWarnings = FALSE)
write_json(stats_list, output_json, pretty = TRUE, auto_unbox = TRUE)

cat("\nGlobal band statistics written to:", output_json, "\n")
cat("\nSummary:\n")
for (band in target_bands) {
  cat(sprintf("  %-15s  min: %12.4f  max: %12.4f\n",
              band, global_mins[band], global_maxs[band]))
}
