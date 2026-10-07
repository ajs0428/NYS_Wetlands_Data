### Vector chips/patches for DL from RAW data
# Creates square patches in vector format (polygons) straight from a raw,
# statewide wetland layer (e.g. the full NWI) for every HUC12 in one cluster.
#
# Steps:
#   1. pull the cluster's HUC12s from the cluster zones gpkg
#   2. read only the raw wetland polygons that fall in the cluster's bbox
#   3. per HUC12: reclassify the wetlands (class scheme + class field), sample
#      non-overlapping square patches, split each patch into wetland/UPL polygons
#   4. write one gpkg per HUC12 (`_BINARY` tag for the binary scheme)
#
# Usage:
#   Rscript R_Code_Analysis/Vector_ChipsPatches_fromRAW_DL.R \
#       <cluster> <raw_wetlands.gpkg> <patch_radius_m> <MULTICLASS|BINARY> [class_field]
#   e.g. Rscript R_Code_Analysis/Vector_ChipsPatches_fromRAW_DL.R \
#       64 Data/NWI/NY_NWI_6347.gpkg 128 MULTICLASS ATTRIBUTE
#   Sources without a class column (e.g. NYS Informational wetlands) are BINARY only;
#   leave out class_field (or pass NONE) and every polygon becomes WET:
#       64 Data/Laba_NYS_Info_Wetlands/Informational_Freshwater_Wetland_Mapping_-4832045112583547805.gpkg 128 BINARY

library(sf)
library(dplyr)
library(stringr)
library(future)
library(future.apply)

set.seed(11)

########################################################################################

args <- c(
  64, # Cluster
  "Data/NWI/NY_NWI_6347.gpkg", # Raw wetland polygons (statewide)
  128, # Patch size radius
  "MULTICLASS", # Class scheme: "MULTICLASS" (EMW/FSW/SSW/UPL) or "BINARY" (WET/UPL)
  "ATTRIBUTE" # Field in the raw wetlands holding the class code (NWI: Cowardin ATTRIBUTE)
)

args <- commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

clusterTarget <- args[1]
wetlandPath <- args[2]
patchSize <- as.numeric(args[3])
# anything other than "BINARY" keeps the multiclass labels
classScheme <- if (isTRUE(toupper(args[4]) == "BINARY")) {
  "BINARY"
} else {
  "MULTICLASS"
}
# optional 5th arg; missing or "NONE" means the source has no class column
classField <- if (
  length(args) >= 5 && !toupper(args[5]) %in% c("", "NONE", "NA")
) {
  args[5]
} else {
  NA_character_
}

cat(
  "these are the arguments: \n",
  "1) Cluster number for HUC groups:",
  clusterTarget,
  "\n",
  "2) path to the raw wetland polygons :",
  wetlandPath,
  "\n",
  "3) patch size :",
  patchSize,
  "\n",
  "4) class scheme :",
  classScheme,
  "\n",
  "5) wetland class field :",
  classField,
  "\n"
)

########################################################################################
## Patch-center sampling
# Candidate centers come from three sources, in priority order:
#   1. one point on the surface of every wetland polygon (small wetlands get a shot)
#   2. points every `boundarySpacing` m along every polygon ring (incl. holes)
#   3. a regular grid every `interiorSpacing` m inside the polygons (large wetlands)
# Candidates whose box would cross the HUC edge are dropped, then a greedy pass
# keeps a candidate only if its box does not overlap any box already kept.
boxSide <- patchSize * 2
boundarySpacing <- boxSide # m between candidate points along polygon edges
interiorSpacing <- boxSide # m between candidate grid points inside polygons

hucPath <- "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
outDir <- "Data/Training_Data/R_Patches_Vector_fromRAW/"
dir.create(outDir, showWarnings = FALSE, recursive = TRUE)

########################################################################################
## Source name (used in the output filename and to pick the reclass scheme)
if (grepl("NWI", basename(wetlandPath))) {
  sourceWetlands <- "NWI"
} else if (grepl("NHP", basename(wetlandPath))) {
  sourceWetlands <- "NHP"
} else if (grepl("Laba|Info", basename(wetlandPath))) {
  sourceWetlands <- "Info"
} else {
  sourceWetlands <- sub(
    "_.*",
    "",
    tools::file_path_sans_ext(basename(wetlandPath))
  )
}
message("Wetland source: ", sourceWetlands)

# Multiclass needs a class column and a reclass scheme (only NWI so far)
if (classScheme == "MULTICLASS" && is.na(classField)) {
  stop("MULTICLASS needs a class field (arg 5); use BINARY for unclassed sources")
}
if (classScheme == "MULTICLASS" && sourceWetlands != "NWI") {
  stop("No multiclass reclass scheme for source '", sourceWetlands, "' yet")
}

########################################################################################
## Reclassification
# NWI scheme from TrainingDataGenerationFlex_CMD.R, keyed on the Cowardin code in
# `classField`. Riverine, marine/estuarine and lakes (L1) < 2e5 m^2 are dropped;
# OpenWater (OWW) is dropped later, so both end up as UPL in the patches.
# Codes that match no rule (e.g. PEM/PFO mixes) become "Other" for GIS review.
reclass_nwi <- function(wet) {
  code <- wet[[classField]]
  # NWI type column is WETLAND_TY in older exports, WETLAND_TYPE in newer ones
  type_col <- intersect(c("WETLAND_TY", "WETLAND_TYPE"), names(wet))
  wet_type <- if (length(type_col)) wet[[type_col[1]]] else rep("", nrow(wet))
  area <- as.numeric(st_area(wet))
  wet |>
    mutate(.code = code, .type = wet_type, .area = area) |>
    filter(!str_detect(.code, "R1|R3|R2|R4|R5")) |> # remove big rivers and small streams (unreliable)
    filter(!(str_detect(.code, "L1") & .area < 2E5)) |> # remove small L1 lakes
    filter(!str_detect(.type, "Marine|Estuarine|Other")) |> # remove marine/estuarine
    mutate(
      MOD_CLASS = case_when(
        str_detect(.code, "L1|L2|PUB|PUS|PAB|R2|R3") &
          !str_detect(.code, "PFO|PEM|PSS") ~ "OWW",
        str_detect(.code, "PSS") & !str_detect(.code, "PFO|PEM") ~ "SSW",
        str_detect(.code, "PEM") & !str_detect(.code, "PFO|PSS") ~ "EMW",
        str_detect(.code, "PFO") & !str_detect(.code, "PSS|PEM") ~ "FSW",
        str_detect(.code, "PSS") & str_detect(.code, "PFO") ~ "FSW",
        str_detect(.code, "PSS") & str_detect(.code, "PEM") ~ "EMW",
        .default = "Other"
      )
    ) |>
    select(-.code, -.type, -.area)
}

# NWI with a class field gets the NWI filters in both schemes; any source without
# one (or non-NWI in BINARY) keeps every polygon as WET.
reclass_wetlands <- function(wet) {
  if (sourceWetlands == "NWI" && !is.na(classField)) {
    wet <- reclass_nwi(wet) |> filter(MOD_CLASS != "OWW")
  }
  if (classScheme == "BINARY") {
    wet <- wet |> mutate(MOD_CLASS = "WET")
  }
  wet
}

########################################################################################
## Cluster HUC12s and the raw wetlands that fall in them
huc_cluster <- st_read(
  hucPath,
  quiet = TRUE,
  query = paste0(
    "SELECT * FROM NY_Cluster_Zones_250_CROP_NAomit_6347 WHERE cluster = ",
    as.integer(clusterTarget)
  )
)
if (nrow(huc_cluster) == 0) {
  stop("No HUC12s found for cluster ", clusterTarget, " in ", hucPath)
}
huc_ids <- unique(huc_cluster$huc12)
message("Cluster ", clusterTarget, ": ", length(huc_ids), " HUC12s")

# use the largest layer (raw NWI gpkg also carries a 1-feature state outline layer)
wet_layers <- st_layers(wetlandPath)
wet_layer <- wet_layers$name[which.max(wet_layers$features)]
wet_template <- st_read(
  wetlandPath,
  query = paste0('SELECT * FROM "', wet_layer, '" LIMIT 0'),
  quiet = TRUE
)
if (!is.na(classField) && !classField %in% names(wet_template)) {
  stop(
    "Class field '",
    classField,
    "' not in layer '",
    wet_layer,
    "'; columns: ",
    paste(setdiff(names(wet_template), attr(wet_template, "sf_column")), collapse = ", ")
  )
}

# spatial-index read of only the cluster's bbox instead of the whole state;
# the filter has to be in the raw layer's CRS (e.g. Info wetlands are EPSG:26918)
cluster_bbox <- st_as_sfc(st_bbox(huc_cluster)) |>
  st_transform(st_crs(wet_template))
wet_cluster <- st_read(
  wetlandPath,
  layer = wet_layer,
  wkt_filter = st_as_text(cluster_bbox),
  quiet = TRUE
)
if (st_crs(wet_cluster) != st_crs(huc_cluster)) {
  wet_cluster <- st_transform(wet_cluster, st_crs(huc_cluster))
}
st_geometry(wet_cluster) <- "geom"
wet_cluster <- wet_cluster[!st_is_empty(wet_cluster), ] |>
  st_zm() |> # some sources (e.g. Info wetlands) carry Z/M, which GEOS rejects
  st_make_valid()
message("Raw wetland polygons in cluster bbox: ", nrow(wet_cluster))

########################################################################################
# Greedy non-overlap thinning of square boxes: two boxes of side `side` centered at
# p and q do not overlap when max(|dx|, |dy|) >= side. Earlier rows win.
thin_boxes <- function(xy, side) {
  keep <- logical(nrow(xy))
  kx <- numeric(0)
  ky <- numeric(0)
  for (i in seq_len(nrow(xy))) {
    if (
      length(kx) == 0 ||
        all(pmax(abs(kx - xy[i, 1]), abs(ky - xy[i, 2])) >= side)
    ) {
      keep[i] <- TRUE
      kx <- c(kx, xy[i, 1])
      ky <- c(ky, xy[i, 2])
    }
  }
  keep
}
########################################################################################

vect_chip_patch_create <- function(huc_num) {
  fn_full_patch <- paste0(
    outDir,
    sourceWetlands,
    "_cluster_",
    clusterTarget,
    "_huc_",
    huc_num,
    "_",
    patchSize * 2,
    "m",
    if (classScheme == "BINARY") "_BINARY" else "",
    ".gpkg"
  )
  if (file.exists(fn_full_patch)) {
    message("Already file ", fn_full_patch)
    return(invisible(NULL))
  }

  huc_geom <- st_union(huc_cluster[huc_cluster$huc12 == huc_num, ])
  # wetlands touching the HUC; patches are kept fully inside it further down
  target_wetlands <- wet_cluster[
    lengths(st_intersects(wet_cluster, huc_geom)) > 0,
  ] |>
    reclass_wetlands()
  if (nrow(target_wetlands) == 0) {
    message("HUC ", huc_num, ": no wetlands after reclass, skipping")
    return(invisible(NULL))
  }
  tw_geom <- st_geometry(target_wetlands)

  ## 1. one guaranteed-interior point per polygon (centroids can fall outside)
  pt_surface <- st_point_on_surface(tw_geom)

  ## 2. points along every ring; rings shorter than the spacing are covered by 1.
  tw_rings <- st_boundary(tw_geom) |>
    st_cast("MULTILINESTRING") |>
    st_cast("LINESTRING")
  tw_rings <- tw_rings[as.numeric(st_length(tw_rings)) >= boundarySpacing]
  pt_boundary <- st_line_sample(tw_rings, density = 1 / boundarySpacing) |>
    st_cast("POINT")

  ## 3. regular grid inside polygons, offset randomly so it isn't HUC-aligned
  grid_offset <- st_bbox(huc_geom)[c("xmin", "ymin")] -
    runif(2, 0, interiorSpacing)
  pt_grid <- st_make_grid(
    huc_geom,
    cellsize = interiorSpacing,
    offset = grid_offset,
    what = "centers"
  )
  pt_grid <- pt_grid[lengths(st_intersects(pt_grid, tw_geom)) > 0]

  shuffle <- function(x) x[sample(length(x))]
  cand <- c(shuffle(pt_surface), shuffle(pt_boundary), shuffle(pt_grid))
  cand_box <- st_buffer(cand, dist = patchSize, endCapStyle = "SQUARE")
  in_huc <- lengths(st_within(cand_box, huc_geom)) > 0
  cand <- cand[in_huc]
  keep <- thin_boxes(st_coordinates(cand), boxSide)

  message(
    "HUC ",
    huc_num,
    ": wetlands = ",
    nrow(target_wetlands),
    "; candidates surface/boundary/grid = ",
    length(pt_surface),
    "/",
    length(pt_boundary),
    "/",
    length(pt_grid),
    "; inside HUC = ",
    length(cand),
    "; kept patches = ",
    sum(keep)
  )
  if (sum(keep) == 0) {
    return(invisible(NULL))
  }

  # Stamp an integer patch identifier onto each box (one row = one patch)
  # so every polygon split out of the box below inherits the same PatchGroup.
  patch_boxes <- st_sf(
    geom = st_buffer(cand[keep], dist = patchSize, endCapStyle = "SQUARE")
  ) |>
    dplyr::mutate(MOD_CLASS = "UPL", PatchGroup = dplyr::row_number())
  tw_intersection <- st_intersection(
    target_wetlands |> dplyr::select(MOD_CLASS),
    patch_boxes |> dplyr::select(PatchGroup)
  ) |>
    dplyr::select(MOD_CLASS, PatchGroup, geom)
  tu_intersection <- st_difference(
    patch_boxes,
    st_union(target_wetlands)
  ) |>
    dplyr::select(MOD_CLASS, PatchGroup, geom)
  cmb_tutw <- bind_rows(tw_intersection, tu_intersection) |>
    st_collection_extract("POLYGON") |>
    mutate(
      ReviewerName = "TBD",
      Confidence = -999,
      BoundariesAltered = NA,
      Comments = "NoComment"
    ) |>
    st_cast(to = "MULTIPOLYGON") |>
    dplyr::select(
      ReviewerName,
      Confidence,
      BoundariesAltered,
      Comments,
      MOD_CLASS,
      PatchGroup
    )

  st_write(cmb_tutw, dsn = fn_full_patch, append = FALSE, quiet = TRUE)
  message("Wrote ", fn_full_patch)
  return(invisible(NULL))
}


### Parallel
slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
  corenum <- as.integer(slurm_cpus)
} else {
  corenum <- min(future::availableCores(), 4)
}

print(corenum)
options(future.globals.maxSize = 32.0 * 1e9)
# plan(multisession, workers = corenum)
plan(future.callr::callr, workers = corenum)

invisible(future_lapply(
  huc_ids,
  vect_chip_patch_create,
  future.seed = TRUE,
  future.packages = c("sf", "dplyr", "stringr"),
  future.globals = TRUE
))

### Non-parallel
# system.time({t <- lapply(huc_ids, vect_chip_patch_create)})
