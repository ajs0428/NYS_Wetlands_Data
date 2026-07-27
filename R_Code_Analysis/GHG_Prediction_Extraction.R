### Extract DL wetland-prediction values at NYDEC GHG flux site points
###
### Companion to GHG_Point_Extraction.R (which extracts the model *input*
### predictors). This one extracts the model *output* rasters produced by the
### NYS_Wetlands_DL project, matched to each point by its huc12 + cluster.
###
### There are two model heads per HUC; files are named by the exact
### `cluster_<N>_huc_<HUCID>` token with a fixed prefix/suffix:
###   DLpred_binary_<key>.tif           -> "Predicted Class"           -> DL_class
###   DLpred_binary_<key>_probs.tif     -> "WET Probability"           -> WET_prob
###   DLpred_multiclass_<key>_probs.tif -> "EMW/FSW/SSW Probability"   -> *_prob
### Bands are selected by their description (robust to band order), extracted at
### the site points. UPL Probability and the multiclass Predicted Class exist in
### these files too and are easy to add if wanted.
###
### Rasters are read as file-backed windows by terra::extract (no whole-raster
### load, no crop needed). Only the final points+predictions gpkg is written.
###
### Usage:
###   module load R/4.4.3
###   Rscript R_Code_Analysis/GHG_Prediction_Extraction.R <in_gpkg> <pred_dir> <out_gpkg>

suppressPackageStartupMessages({
  library(terra)
  library(sf)
  library(dplyr)
  library(stringr)
})

########################################################################################

args <- commandArgs(trailingOnly = TRUE)
in_gpkg  <- if (length(args) >= 1 && nzchar(args[1])) args[1] else
  "Data/FieldData/GHG/NYDEC_GHG_Sites_6347_wHUCs.gpkg"
pred_dir <- if (length(args) >= 2 && nzchar(args[2])) args[2] else
  "/ibstorage/anthony/NYS_Wetlands_DL/Data/HUC_DL_Predictions_v2"
out_gpkg <- if (length(args) >= 3 && nzchar(args[3])) args[3] else
  "Data/FieldData/GHG/NYDEC_GHG_Sites_6347_ExtractedPredictions.gpkg"

message("these are the arguments:\n",
  "1) input points gpkg: ", in_gpkg, "\n",
  "2) predictions dir:   ", pred_dir, "\n",
  "3) output gpkg:       ", out_gpkg, "\n")

setGDALconfig("GDAL_PAM_ENABLED", "FALSE")

if (!dir.exists(pred_dir) ||
    length(list.files(pred_dir, pattern = "\\.tif$")) == 0) {
  stop("No prediction rasters found in ", pred_dir)
}

########################################################################################
## Read points; ensure single-part POINT geometry and required id fields exist.
pts <- st_read(in_gpkg, quiet = TRUE)
pts <- st_cast(pts, "POINT")          # split any MULTIPOINT so 1 geometry = 1 row

req <- c("huc12", "cluster")
missing_flds <- setdiff(req, names(pts))
if (length(missing_flds)) {
  stop("Input is missing required field(s): ", paste(missing_flds, collapse = ", "))
}

pts$.rowid   <- seq_len(nrow(pts))    # stable id to rejoin values onto all attrs
pts$.huc12   <- as.character(pts$huc12)
pts$.cluster <- as.character(pts$cluster)

message("Read ", nrow(pts), " points across ",
  dplyr::n_distinct(paste(pts$.cluster, pts$.huc12)), " (cluster, huc12) group(s)")

########################################################################################
## Build the exact per-HUC filenames. The `cluster_<N>_huc_<HUCID>` key plus the
## fixed head prefix/suffix is fully specific -- no substring hazard, and it
## keeps the binary and multiclass heads (which share the key) separate.
pred_paths <- function(cluster_num, huc_num) {
  key <- paste0("cluster_", cluster_num, "_huc_", huc_num)
  files <- c(
    bin_class = paste0("DLpred_binary_",     key, ".tif"),
    bin_prob  = paste0("DLpred_binary_",     key, "_probs.tif"),
    mc_prob   = paste0("DLpred_multiclass_", key, "_probs.tif")
  )
  setNames(file.path(pred_dir, files), names(files)) # file.path() drops names
}

## Extract prediction values for one (cluster, huc12) group of points.
## For each raster, bands are pulled by matching a code against the band
## descriptions (e.g. "WET Probability"), so band order is irrelevant.
extract_group <- function(cluster_num, huc_num, grp) {
  message("Processing: cluster ", cluster_num, " | HUC ", huc_num,
    " | ", nrow(grp), " point(s)")

  pp <- pred_paths(cluster_num, huc_num)
  if (!any(file.exists(pp))) {
    message("  No prediction raster for cluster ", cluster_num, " HUC ", huc_num,
      "; points kept with NA")
    return(NULL)
  }

  ## Extract one pass over `path`, returning a data.frame with column `out_name`
  ## per entry of code_map (named out_name -> band-description code). Rasters
  ## share the GHG CRS; points are projected to the raster CRS defensively.
  extract_by_desc <- function(path, code_map, label) {
    na_df <- as.data.frame(setNames(
      rep(list(rep(NA_real_, nrow(grp))), length(code_map)), names(code_map)))
    if (!file.exists(path)) {
      message("  Missing ", label, " raster; ",
        paste(names(code_map), collapse = ", "), " -> NA")
      return(na_df)
    }
    r  <- rast(path)
    pv <- project(vect(grp), crs(r))
    ev <- terra::extract(r, pv, ID = FALSE)        # all bands, cols = band names
    cols <- lapply(code_map, function(code) {
      idx <- grep(code, names(r), ignore.case = TRUE)
      if (length(idx) == 0) {
        message("  Band '", code, "' not found in ", basename(path)); rep(NA_real_, nrow(grp))
      } else ev[[idx[1]]]
    })
    as.data.frame(setNames(cols, names(code_map)))
  }

  out <- data.frame(.rowid = grp$.rowid)
  out <- cbind(out,
    extract_by_desc(pp[["bin_class"]], c(DL_class = "Predicted Class"), "binary class"),
    extract_by_desc(pp[["bin_prob"]],  c(WET_prob = "WET"),             "binary probability"),
    extract_by_desc(pp[["mc_prob"]],   c(EMW_prob = "EMW", FSW_prob = "FSW",
                                         SSW_prob = "SSW"),             "multiclass probability"))
  out
}

########################################################################################
## Run every group; collect prediction rows keyed by .rowid.
groups <- split(pts, list(pts$.cluster, pts$.huc12), drop = TRUE)
results <- lapply(groups, function(grp) {
  extract_group(grp$.cluster[1], grp$.huc12[1], grp)
})
results <- results[!vapply(results, is.null, logical(1))]

if (length(results) == 0) {
  stop("No predictions extracted for any group; check that prediction rasters ",
    "exist in ", pred_dir, " for the clusters/HUCs in ", in_gpkg)
}

preds <- bind_rows(results)

########################################################################################
## Join predictions back onto the full point set (left join keeps every original
## point/attribute; groups with no raster simply get NA prediction columns).
out <- pts |>
  select(-.huc12, -.cluster) |>
  left_join(preds, by = ".rowid") |>
  select(-.rowid)

pred_cols <- c("DL_class", "WET_prob", "EMW_prob", "FSW_prob", "SSW_prob")
for (col in pred_cols) {
  message("  ", col, ": ", sum(!is.na(out[[col]])), " of ", nrow(out), " points non-NA")
}

dir.create(dirname(out_gpkg), recursive = TRUE, showWarnings = FALSE)
st_write(out, out_gpkg, delete_dsn = TRUE, quiet = TRUE)
message("Wrote ", nrow(out), " points with ", paste(pred_cols, collapse = ", "),
  " to ", out_gpkg)
