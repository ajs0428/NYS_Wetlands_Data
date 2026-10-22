#!/usr/bin/env Rscript
# Build a HUC12 vector of the watersheds that hold training patches for the
# factorial experiment (NYS_Wetlands_DL @ factorial-v3), for the manuscript map.
#
# Reads the per-HUC patch rasters in each training arm folder, pulls the HUC12 id
# from the `_huc_<HUCID>_` part of the filename, and tags the matching polygons in
# the cluster-zone HUC12 layer.
#
# Output: Data/NY_HUCS/NY_HUC12_Factorial_Training_Locations.gpkg
#   in_<arm> / n_<arm>   presence flag + patch count per training arm
#   train_source         summary class for symbology
#   reviewed_sources     label-source prefixes of the reviewed patches in the HUC
#
# Usage: Rscript R_Code_Analysis/HUC12_Factorial_Training_Locations.R [all_hucs]
#   all_hucs = TRUE keeps every HUC12 (non-training ones get train_source = "None");
#   FALSE (default) writes only the training HUCs.

suppressPackageStartupMessages(library(sf))

args <- c("FALSE")
args <- commandArgs(trailingOnly = TRUE)
all_hucs <- if (length(args) >= 1) as.logical(args[1]) else FALSE

base_dir  <- "/ibstorage/anthony/NYS_Wetlands_Data/Data"
huc_gpkg  <- file.path(base_dir, "NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg")
out_gpkg  <- file.path(base_dir, "NY_HUCS/NY_HUC12_Factorial_Training_Locations.gpkg")
train_dir <- file.path(base_dir, "Training_Data")

arms <- c(R_Patches            = "R_Patches",
          R_Patches_NWI        = "R_Patches_NWI",
          R_Patches_NWIextra   = "R_Patches_NWIextra",
          R_Patches_NWIextra10 = "R_Patches_NWIextra10")

# ---- patch inventory: one row per patch raster ----
patch_tbl <- do.call(rbind, lapply(names(arms), function(a) {
  f <- list.files(file.path(train_dir, arms[[a]]), pattern = "_huc_[0-9]+_.*\\.tif$")
  if (length(f) == 0) stop("No patch rasters found in ", arms[[a]])
  data.frame(arm     = a,
             file    = f,
             cluster = as.integer(sub(".*cluster_([0-9]+)_huc_.*", "\\1", f)),
             huc12   = sub(".*_huc_([0-9]+)_.*", "\\1", f),
             prefix  = sub("_cluster_[0-9]+_huc_.*", "", f),
             stringsAsFactors = FALSE)
}))

hucs <- st_read(huc_gpkg, quiet = TRUE)
hucs$huc12 <- as.character(hucs$huc12)

# Sanity: every patch HUC must exist in the layer, under the same cluster
miss <- setdiff(unique(patch_tbl$huc12), hucs$huc12)
if (length(miss)) stop("Patch HUC12s not in HUC layer: ", paste(miss, collapse = ", "))
pairs <- unique(patch_tbl[, c("huc12", "cluster")])
chk   <- merge(pairs, st_drop_geometry(hucs)[, c("huc12", "cluster")],
               by = "huc12", suffixes = c("_patch", "_layer"))
bad   <- chk[chk$cluster_patch != chk$cluster_layer, ]
if (nrow(bad)) {
  warning("Cluster id mismatch between patch filenames and HUC layer:")
  print(bad)
}

# ---- per-HUC flags and counts ----
for (a in names(arms)) {
  cnt <- table(patch_tbl$huc12[patch_tbl$arm == a])
  n   <- as.integer(cnt[hucs$huc12])
  n[is.na(n)] <- 0L
  hucs[[paste0("n_", a)]]  <- n
  hucs[[paste0("in_", a)]] <- n > 0
}

# Reviewed label sources (R_Patches prefixes), e.g. "ADK_WCT_AJS; NWI_SM"
rev_tbl <- patch_tbl[patch_tbl$arm == "R_Patches", ]
rev_src <- tapply(rev_tbl$prefix, rev_tbl$huc12,
                  function(p) paste(sort(unique(p)), collapse = "; "))
hucs$reviewed_sources <- as.character(rev_src[hucs$huc12])

# Summary class. The arms are nested: R_Patches, _NWI and _NWIextra share the
# same HUCs, and NWIextra10 adds more HUCs on top.
hucs$train_source <- with(st_drop_geometry(hucs), ifelse(
  in_R_Patches & in_R_Patches_NWI & in_R_Patches_NWIextra & in_R_Patches_NWIextra10,
    "All arms (Reviewed, NWI, NWIextra, NWIextra10)",
  ifelse(in_R_Patches_NWIextra10 &
           !(in_R_Patches | in_R_Patches_NWI | in_R_Patches_NWIextra),
    "NWIextra10 only",
  ifelse(in_R_Patches | in_R_Patches_NWI | in_R_Patches_NWIextra | in_R_Patches_NWIextra10,
    "Other combination", "None"))))

if (!all_hucs) hucs <- hucs[hucs$train_source != "None", ]

hucs <- hucs[, c("huc12", "name", "cluster", "train_source",
                 paste0("in_", names(arms)), paste0("n_", names(arms)),
                 "reviewed_sources")]

st_write(hucs, out_gpkg, layer = "NY_HUC12_Factorial_Training_Locations",
         delete_dsn = TRUE, quiet = TRUE)

cat("Wrote", nrow(hucs), "HUC12 polygons to", out_gpkg, "\n")
print(table(hucs$train_source))
cat("Patch totals:\n")
print(colSums(st_drop_geometry(hucs)[, paste0("n_", names(arms))]))
