#!/usr/bin/env Rscript
# Build a HUC12 vector of the watersheds that hold production-model patches
# (NYS_Wetlands_Prod, R_Patches_Prod) and tag each as test or train, per a
# NYS_Wetlands_Prod/splits/test_hucs_*.json split file. Companion to
# HUC12_Factorial_Training_Locations.R.
#
# Split logic mirrors prod/prod_split.py: a HUC12 listed in the split file's
# "test_hucs" is test; every other patch HUC12 is train/val. Val is drawn per
# seed from the non-test HUCs (Python RNG), so it is not split out here --
# "train" below means the train+val pool. Region uses the split file's own
# region_prefixes snapshot (longest prefix wins, as in prod_split.region_of).
#
# Output: Data/NY_HUCS/NY_HUC12_Prod_Training_Locations_<split name>.gpkg
#   split      "test" / "train" (or "None" when all_hucs = TRUE)
#   region     stratification region from the split file
#   n_patches  patch rasters in the HUC
#   sources    label-source prefixes of the patches in the HUC
#
# Usage: Rscript R_Code_Analysis/HUC12_Prod_Training_Locations.R \
#          [split_json] [patch_dir] [all_hucs]
#   split_json  name ("test_hucs_v2") or path; default test_hucs_v2
#   patch_dir   default NYS_Wetlands_Prod/Data/Training_Data/R_Patches_Prod
#               (the copy prod training reads)
#   all_hucs    TRUE keeps every HUC12 (non-patch ones get split = "None");
#               FALSE (default) writes only the patch HUCs.

suppressPackageStartupMessages({
  library(sf)
  library(jsonlite)
})

args <- c("test_hucs_v2", "", "FALSE")
args <- commandArgs(trailingOnly = TRUE)

prod_dir   <- "/ibstorage/anthony/NYS_Wetlands_Prod"
base_dir   <- "/ibstorage/anthony/NYS_Wetlands_Data/Data"
split_arg  <- if (length(args) >= 1 && nzchar(args[1])) args[1] else "test_hucs_v2"
patch_dir  <- if (length(args) >= 2 && nzchar(args[2])) args[2] else
                file.path(prod_dir, "Data/Training_Data/R_Patches_Prod")
all_hucs   <- if (length(args) >= 3) as.logical(args[3]) else FALSE

# Accept a bare split name or a path
split_json <- if (file.exists(split_arg)) split_arg else
                file.path(prod_dir, "splits", sub("(\\.json)?$", ".json", split_arg))
if (!file.exists(split_json)) stop("Split file not found: ", split_json)
split <- fromJSON(split_json)
split_name <- if (!is.null(split$name)) split$name else
                sub("\\.json$", "", basename(split_json))
test_hucs <- as.character(split$test_hucs)

huc_gpkg <- file.path(base_dir, "NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg")
out_layer <- paste0("NY_HUC12_Prod_Training_Locations_", split_name)
out_gpkg  <- file.path(base_dir, "NY_HUCS", paste0(out_layer, ".gpkg"))

# ---- patch inventory: one row per patch raster ----
f <- list.files(patch_dir, pattern = "\\.tif$")
if (length(f) == 0) stop("No patch rasters found in ", patch_dir)
no_huc <- f[!grepl("_huc_[0-9]+_", f)]
if (length(no_huc)) stop("Patches without a '_huc_<id>_' token: ",
                         paste(head(no_huc), collapse = ", "))
patch_tbl <- data.frame(file    = f,
                        cluster = as.integer(sub(".*cluster_([0-9]+)_huc_.*", "\\1", f)),
                        huc12   = sub(".*_huc_([0-9]+)_.*", "\\1", f),
                        prefix  = sub("_cluster_[0-9]+_huc_.*", "", f),
                        stringsAsFactors = FALSE)
patch_hucs <- unique(patch_tbl$huc12)

# Split file vs. patch dir consistency (prod_split.resolve_split would fail on the first)
if (!is.null(split$patch_dir) && split$patch_dir != basename(patch_dir))
  warning("Split file was drawn on ", split$patch_dir, ", not ", basename(patch_dir))
gone <- setdiff(test_hucs, patch_hucs)
if (length(gone)) warning("Test HUC12s with no patches in ", basename(patch_dir), ": ",
                          paste(gone, collapse = ", "))
if (!is.null(split$n_patches_total) && split$n_patches_total != nrow(patch_tbl))
  message("Note: split was drawn on ", split$n_patches_total, " patches / ",
          split$n_hucs_total, " HUC12s; patch dir now has ", nrow(patch_tbl),
          " / ", length(patch_hucs), ". Added HUC12s fall in train.")

hucs <- st_read(huc_gpkg, quiet = TRUE)
hucs$huc12 <- as.character(hucs$huc12)

miss <- setdiff(patch_hucs, hucs$huc12)
if (length(miss)) stop("Patch HUC12s not in HUC layer: ", paste(miss, collapse = ", "))
pairs <- unique(patch_tbl[, c("huc12", "cluster")])
chk   <- merge(pairs, st_drop_geometry(hucs)[, c("huc12", "cluster")],
               by = "huc12", suffixes = c("_patch", "_layer"))
bad   <- chk[chk$cluster_patch != chk$cluster_layer, ]
if (nrow(bad)) {
  warning("Cluster id mismatch between patch filenames and HUC layer:")
  print(bad)
}

# ---- per-HUC attributes ----
cnt <- table(patch_tbl$huc12)
hucs$n_patches <- as.integer(cnt[hucs$huc12])
hucs$n_patches[is.na(hucs$n_patches)] <- 0L

hucs$split <- ifelse(hucs$huc12 %in% test_hucs, "test",
              ifelse(hucs$n_patches > 0, "train", "None"))

src <- tapply(patch_tbl$prefix, patch_tbl$huc12,
              function(p) paste(sort(unique(p)), collapse = "; "))
hucs$sources <- as.character(src[hucs$huc12])

# Region from the split file's own prefix snapshot (longest match wins)
prefixes <- unlist(split$region_prefixes)
region_of <- function(h) {
  hits <- names(prefixes)[startsWith(h, names(prefixes))]
  if (length(hits) == 0) return(NA_character_)
  unname(prefixes[hits[which.max(nchar(hits))]])
}
hucs$region <- NA_character_
has <- hucs$n_patches > 0
if (length(prefixes)) hucs$region[has] <- vapply(hucs$huc12[has], region_of, "")
if (length(prefixes) && any(is.na(hucs$region[has])))
  warning("Patch HUC12s in no region: ",
          paste(hucs$huc12[has & is.na(hucs$region)], collapse = ", "))
hucs$split_file <- split_name

if (!all_hucs) hucs <- hucs[hucs$split != "None", ]

hucs <- hucs[, c("huc12", "name", "cluster", "split", "region",
                 "n_patches", "sources", "split_file")]

st_write(hucs, out_gpkg, layer = out_layer, delete_dsn = TRUE, quiet = TRUE)

cat("Wrote", nrow(hucs), "HUC12 polygons to", out_gpkg, "\n")
d <- st_drop_geometry(hucs)[hucs$split != "None", ]
d$region[is.na(d$region)] <- "(no region)"
cat("\nHUC12s by split x region:\n");  print(addmargins(table(d$region, d$split)))
cat("\nPatches by split x region:\n")
print(addmargins(xtabs(n_patches ~ region + split, data = d)))
