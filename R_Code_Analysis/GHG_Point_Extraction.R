### Extract DL predictor values at NYDEC GHG flux site points
###
### The GHG sites gpkg already carries the huc12 and cluster each point falls in
### (fields `huc12`, `cluster`). For every (cluster, huc12) group this script
### resolves that HUC's source rasters, assembles the SAME in-memory predictor
### stack the deep-learning pipeline uses (band recipe from huc_stack.R:
### DEM, terrain slope, hydro w/ log(flowacc), CHM, NAIP w/o ndvi/ndwi,
### ortho `_lo`, lidar), and extracts band values at the site points.
###
### Nothing is written to disk except the final points+predictors gpkg. Predictor
### stacks are built lazily and cropped to each HUC's point extent, so only a
### small window per HUC is ever read.
###
### Usage:
###   module load R/4.4.3
###   Rscript R_Code_Analysis/GHG_Point_Extraction.R <in_gpkg> <out_gpkg>

suppressPackageStartupMessages({
  library(terra)
  library(sf)
  library(dplyr)
  library(stringr)
})

source("R_Code_Analysis/huc_stack.R") # shared in-memory stack recipe (band contract)

########################################################################################

args <- c(
  "Data/FieldData/GHG/NYDEC_GHG_Sites_6347_wHUCs.gpkg", # input points
  "Data/FieldData/GHG/NYDEC_GHG_Sites_6347_ExtractedPredictors.gpkg" # output
)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1 && nzchar(args[1])) {
  in_gpkg <- args[1]
} else {
  in_gpkg <- "Data/FieldData/GHG/NYDEC_GHG_Sites_6347_wHUCs.gpkg"
}
if (length(args) >= 2 && nzchar(args[2])) {
  out_gpkg <- args[2]
} else {
  out_gpkg <- "Data/FieldData/GHG/NYDEC_GHG_Sites_6347_ExtractedPredictors.gpkg"
}

message(
  "these are the arguments:\n",
  "1) input points gpkg: ",
  in_gpkg,
  "\n",
  "2) output gpkg:       ",
  out_gpkg,
  "\n"
)

setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
terraOptions(memmax = 20, memfrac = 0.4, tempdir = "Data/tmp")

########################################################################################
## Read points; ensure single-part POINT geometry and required id fields exist.
pts <- st_read(in_gpkg, quiet = TRUE)
pts <- st_cast(pts, "POINT") # split any MULTIPOINT so 1 geometry = 1 row

req <- c("huc12", "cluster")
missing_flds <- setdiff(req, names(pts))
if (length(missing_flds)) {
  stop(
    "Input is missing required field(s): ",
    paste(missing_flds, collapse = ", ")
  )
}

## Stable row id to rejoin extracted values back onto every original attribute.
pts$.rowid <- seq_len(nrow(pts))

## Normalize ids to the strings used inside raster filenames.
pts$.huc12 <- as.character(pts$huc12)
pts$.cluster <- as.character(pts$cluster)

message(
  "Read ",
  nrow(pts),
  " points across ",
  dplyr::n_distinct(paste(pts$.cluster, pts$.huc12)),
  " (cluster, huc12) group(s)"
)

########################################################################################
## Extract predictors for one (cluster, huc12) group of points.
extract_group <- function(cluster_num, huc_num, grp) {
  message(
    "Processing: cluster ",
    cluster_num,
    " | HUC ",
    huc_num,
    " | ",
    nrow(grp),
    " point(s)"
  )

  paths <- huc_source_paths(huc_num, cluster_num)
  if (!huc_sources_ready(paths, huc_num)) {
    message(
      "  Skipping HUC ",
      huc_num,
      ": one or more source datasets missing; ",
      "points kept with NA predictors"
    )
    return(NULL)
  }

  lyrs <- tryCatch(huc_layers(paths), error = function(e) {
    message("  Error opening layers: ", conditionMessage(e))
    NULL
  })
  if (is.null(lyrs)) {
    return(NULL)
  }

  ## Work in the raster (DEM) CRS: reproject points, crop the stack to their
  ## extent, extract. Rasters share the GHG CRS, but project defensively.
  ref_crs <- crs(lyrs$dem)
  pts_vect <- project(vect(grp), ref_crs)

  ## Buffer the points into a non-degenerate crop window. Repeat GHG rounds sit
  ## at the identical location, so ext(points) is zero-area and crop() rejects
  ## it. build_huc_stack_patch was built for polygon patches; hand it a buffered
  ## polygon for the crop window but extract at the true point locations. Width
  ## is sized off the coarsest source (terrain) so bilinear neighbors exist.
  crop_geom <- terra::buffer(pts_vect, width = max(res(lyrs$terr)) * 10)

  stack_rast <- tryCatch(
    build_huc_stack_patch(paths, crop_geom, mask = FALSE, lyrs = lyrs),
    error = function(e) {
      message("  Error building stack: ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(stack_rast)) {
    return(NULL)
  }

  vals <- tryCatch(
    terra::extract(stack_rast, pts_vect, ID = FALSE),
    error = function(e) {
      message("  Error extracting: ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(vals)) {
    return(NULL)
  }

  vals$.rowid <- grp$.rowid
  vals$.band_key <- paste(names(stack_rast), collapse = "|")
  vals
}

########################################################################################
## Run every group; collect predictor rows keyed by .rowid.
groups <- split(pts, list(pts$.cluster, pts$.huc12), drop = TRUE)
results <- lapply(groups, function(grp) {
  extract_group(grp$.cluster[1], grp$.huc12[1], grp)
})
results <- results[!vapply(results, is.null, logical(1))]

if (length(results) == 0) {
  stop(
    "No predictors extracted for any group; check that source rasters exist ",
    "for the clusters/HUCs in ",
    in_gpkg
  )
}

## Guard the band contract: every group must yield the same bands, in order.
band_keys <- unique(vapply(results, function(r) r$.band_key[1], character(1)))
if (length(band_keys) > 1) {
  warning(
    "Band set differs across HUCs:\n  ",
    paste(band_keys, collapse = "\n  ")
  )
}

preds <- bind_rows(lapply(results, function(r) {
  r[, setdiff(names(r), ".band_key"), drop = FALSE]
}))

########################################################################################
## Join predictors back onto the full point set (left join keeps every original
## point/attribute; groups with missing rasters simply get NA predictor columns).
out <- pts |>
  select(-.huc12, -.cluster) |>
  left_join(preds, by = ".rowid") |>
  select(-.rowid)

n_with <- sum(!is.na(out[[setdiff(names(preds), ".rowid")[1]]]))
message("Extracted predictors for ", n_with, " of ", nrow(out), " points")

dir.create(dirname(out_gpkg), recursive = TRUE, showWarnings = FALSE)
st_write(out, out_gpkg, delete_dsn = TRUE, quiet = TRUE)
message(
  "Wrote ",
  nrow(out),
  " points with ",
  length(setdiff(names(preds), ".rowid")),
  " predictor bands to ",
  out_gpkg
)
