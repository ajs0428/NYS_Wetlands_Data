### validate_huc_stack.R
###
### One-off equivalence check for the in-memory stacking refactor.
### NOT part of the pipeline -- run interactively (or `Rscript`) on the HPC,
### where Data/ lives, BEFORE deleting the old saved *_stack.tif files.
###
### It rebuilds one patch stack in memory (huc_stack.R) and compares it to a
### crop of the corresponding OLD saved stack, on the bands they share. Any
### net-new bands (e.g. the added ortho_* layers) are reported separately --
### they are expected to exist only in the new stack.

library(terra)
library(sf)
library(dplyr)
library(stringr)
source("R_Code_Analysis/huc_stack.R")

## ---- FILL IN: pick a HUC that has BOTH a reviewed patch gpkg and an old stack
CLUSTER   <- "250"
HUC       <- "041402011009"                 # 12-digit HUC
PATCHSIZE <- 128                             # same as the chip script's patchSize
SOURCE    <- "NWI"                           # wetland source prefix (NWI/NHP/Laba/...)
PATCH_DIR <- "Data/Training_Data/R_Patches_Vector_Reviewed/"
OLD_STACK <- paste0("Data/HUC_Raster_Stacks/HUC_DL_Stacks/",
                    "cluster_", CLUSTER, "_huc_", HUC, "_stack.tif")
## ----------------------------------------------------------------------------

setGDALconfig("GDAL_PAM_ENABLED", "FALSE")

## 1. Reconstruct one patch vector exactly like Raster_ChipsPatches_DL.R does
gpkg <- list.files(PATCH_DIR, pattern = "\\.gpkg$", full.names = TRUE)
gpkg <- gpkg[grepl(HUC, gpkg) & grepl(SOURCE, gpkg) & grepl(paste0("cluster_", CLUSTER, "_"), gpkg)]
stopifnot(length(gpkg) >= 1)

tw       <- st_read(gpkg[1], quiet = TRUE)
tw_valid <- tw[st_is_valid(tw), ]
tw_union <- tw_valid |> st_union() |> st_cast("POLYGON") |> st_as_sf() |>
  mutate(group_id = row_number())
st_geometry(tw_union) <- "geom"
tw_union_area <- tw_union |>
  mutate(area = as.numeric(st_area(geom))) |>
  filter(area >= ((PATCHSIZE * 2)^2) - 0.5)
tw_grouped <- tw_valid |> st_join(tw_union_area, left = FALSE) |>
  filter(st_is_valid(geometry)) |> group_split(group_id)
stopifnot(length(tw_grouped) >= 1)

tw_vect <- vect(tw_grouped[[1]])             # first patch in this HUC

## 2. Build the patch stack in memory (new path)
paths <- huc_source_paths(HUC, CLUSTER)
stopifnot(huc_sources_ready(paths, HUC))
new <- build_huc_stack_patch(paths, tw_vect)

## 3. Crop the OLD saved stack to the same patch
old <- crop(rast(OLD_STACK), tw_vect, mask = TRUE)

## 4. Compare
cat("\n--- bands ---\n")
cat("new only (expected: ortho_*):", paste(setdiff(names(new), names(old)), collapse = ", "), "\n")
cat("old only (expected: none)   :", paste(setdiff(names(old), names(new)), collapse = ", "), "\n")

common <- intersect(names(new), names(old))
cat("\n--- per-band max abs difference on shared bands (expect ~0, <=1e-4) ---\n")
d <- abs(new[[common]] - old[[common]])
print(global(d, "max", na.rm = TRUE))

cat("\n--- geometry on shared bands ---\n")
cat("dims identical:", identical(dim(new[[common]]), dim(old[[common]])), "\n")
cat("extent identical:", identical(as.vector(ext(new)), as.vector(ext(old))), "\n")
