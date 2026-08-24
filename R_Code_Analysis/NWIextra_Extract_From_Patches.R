#!/usr/bin/env Rscript

args <- c(
  "Data/NWI/NY_NWI_6347.gpkg",
  "Data/Training_Data/R_Patches_Vector_NWIextra/", #
  "Data/Training_Data/R_Patches_Vector_Reviewed/",
  "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
)

args <- commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

if (length(args) < 3) {
  stop("At least three arguments must be supplied", call. = FALSE)
}
if (length(args) < 4 || is.na(args[4])) {
  args[4] <- "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"
}

message(
  "these are the arguments: \n",
  "1) The NWI wetland dataset:",
  args[1],
  "\n",
  "2) path to place to save vector NWI patches:",
  args[2],
  "\n",
  "3) path to the field-verified vector patches: ",
  args[3],
  "\n",
  "4) path to the HUC12 cluster zones: ",
  args[4],
  "\n"
)

NY_NWI <- args[1]
wetlandSavePath <- args[2]
fieldVerified <- args[3]
hucZones <- args[4]

# Force a rebuild of already-written NWIextra patch vectors. Set via the
# REMOVE_EXISTING env var (the .sh exports it) or as a 5th positional arg,
# which wins if given. Needed when the reviewed source patches changed: the
# per-HUC patch COUNT is derived from them, and without this every existing
# .gpkg is skipped by the file.exists() guard below so the new count never
# takes effect. Because the random boxes are drawn from a single seeded RNG
# stream in HUC order, a full rebuild (all outputs removed) reproduces the
# same placement; a partial one does not.
parse_flag <- function(x) {
  tolower(trimws(x)) %in% c("1", "true", "t", "yes", "y")
}
removeExisting <- if (length(args) >= 5 && nzchar(args[5])) {
  parse_flag(args[5])
} else {
  parse_flag(Sys.getenv("REMOVE_EXISTING", ""))
}
message("5) remove existing NWIextra patches: ", removeExisting, "\n")

if (!dir.exists(wetlandSavePath)) {
  dir.create(wetlandSavePath, recursive = TRUE)
}

### Goal: determine number of field/GIS verified patches per HUC12, then double
### that number by adding the same number of randomly placed NWI patches within
### the same HUC12 watershed.

library(sf)
library(dplyr)
library(tidyr)
library(stringr)

set.seed(11)

PATCH_HALF <- 128 # 256 m patches, same as FieldGPS_to_PatchVectors.R

#### List of field/GIS verified patch vector files.
# Each one has a varying number of 256x256m patches in it
list_of_field_verified <- list.files(
  fieldVerified,
  pattern = ".gpkg",
  full.names = TRUE
)

########################################################################################

#### HUC12 polygons (one feature per HUC12, with its cluster assignment)
zones <- st_read(hucZones, quiet = TRUE) |> st_transform("EPSG:6347")

#### Which HUC12 a patch footprint actually falls in (largest overlap wins)
locate_huc <- function(footprint) {
  cand <- zones[lengths(st_intersects(zones, footprint)) > 0, ]
  if (nrow(cand) == 0) {
    return(NA_character_)
  }
  overlap <- st_area(st_intersection(st_geometry(cand), footprint))
  cand$huc12[which.max(overlap)]
}

#### Inventory the reviewed patches: per file, the HUC12 (from the filename,
#### falling back to a spatial lookup when the filename HUC isn't in the zones
#### layer -- a couple of gps_jc files have typo'd HUC ids), the number of
#### patches (distinct PatchGroup), and the patch footprints (used to keep the
#### random NWI patches from overlapping them).
inventory_reviewed <- function(f) {
  ids <- str_match(basename(f), "cluster_(\\d+)_huc_(\\d+)")
  p <- st_read(f, quiet = TRUE)
  footprint <- st_union(st_geometry(p))

  huc <- ids[3]
  if (!huc %in% zones$huc12) {
    huc <- locate_huc(footprint)
    message(
      basename(f),
      ": filename HUC ",
      ids[3],
      " not in zones layer; patches actually fall in HUC ",
      huc
    )
  }

  # Files without PatchGroup have no per-patch id, so their patch count is
  # unknown -- they contribute footprints to avoid but no count.
  n <- if ("PatchGroup" %in% names(p)) {
    n_distinct(p$PatchGroup)
  } else {
    message("No PatchGroup column in ", basename(f), " - not counted")
    NA_integer_
  }
  list(
    file = basename(f),
    huc12 = huc,
    n_patches = n,
    footprint = footprint
  )
}

reviewed <- lapply(list_of_field_verified, inventory_reviewed)

huc_table <- tibble(
  file = sapply(reviewed, `[[`, "file"),
  huc12 = sapply(reviewed, `[[`, "huc12"),
  n_patches = sapply(reviewed, `[[`, "n_patches")
)
message("Reviewed patch inventory:")
print(huc_table, n = Inf)

#### Footprints of ALL reviewed patches (not just the current HUC's): patches
#### from a neighboring HUC's file can straddle the boundary, and the random
#### boxes must not overlap any of them.
all_footprints <- do.call(c, lapply(reviewed, `[[`, "footprint"))

########################################################################################

#### Read the NWI clipped to a bounding geometry, with the same reliability
#### filters as NWI_Extract_From_Patches.R. Used both to place the random
#### patches (guaranteeing wetland content) and to classify them.
read_nwi_filtered <- function(bound_geom) {
  p_text <- st_bbox(bound_geom) |> st_as_sfc() |> st_as_text()

  st_read(
    NY_NWI,
    layer = "NY_Wetlands",
    wkt_filter = p_text,
    quiet = TRUE
  ) |>
    st_set_geometry("geom") |>
    filter(!str_detect(ATTRIBUTE, "R1|R3|R2|R4|R5")) |> # remove big rivers and small streams (unreliable)
    filter(!(str_detect(ATTRIBUTE, "L1") & as.numeric(st_area(geom)) > 2E5)) |> # remove big lakes
    filter(!str_detect(WETLAND_TYPE, "Marine|Estuarine|Other")) # remove marine/estuarine
}

#### Sample n non-overlapping 256m boxes inside a HUC12 polygon, avoiding the
#### existing reviewed-patch footprints. Box centers are drawn from the
#### filtered NWI wetland polygons, so every patch is guaranteed to contain
#### NWI wetland.
sample_patch_boxes <- function(huc_poly, n, avoid, nwi, max_iter = 25) {
  # Shrink the HUC so sampled boxes stay fully inside it; small/narrow HUCs
  # that vanish under the negative buffer fall back to the full polygon.
  inner <- st_buffer(huc_poly, -PATCH_HALF)
  if (all(st_is_empty(inner))) {
    inner <- huc_poly
  }

  # Wetland area eligible to be a patch center: vegetated NWI (PEM/PSS/PFO,
  # i.e. what classifies to EMW/SSW/FSW -- OpenWater classifies to UPL, so
  # centering there would not guarantee a wetland class) within the shrunk HUC.
  nwi_veg <- nwi |> filter(str_detect(ATTRIBUTE, "PEM|PSS|PFO"))
  kept <- st_sfc(crs = st_crs(huc_poly))
  if (nrow(nwi_veg) == 0) {
    message("No vegetated NWI wetlands in the HUC to center patches on")
    return(kept)
  }
  wet_src <- st_intersection(
    st_union(st_make_valid(st_geometry(nwi_veg))),
    inner
  )
  if (length(wet_src) > 0 && !all(st_is_empty(wet_src))) {
    # st_intersection can return a GEOMETRYCOLLECTION with slivers -- keep polygons
    wet_src <- suppressWarnings(st_collection_extract(wet_src, "POLYGON"))
  }
  if (length(wet_src) == 0 || all(st_is_empty(wet_src))) {
    message("No NWI wetlands inside the HUC to center patches on")
    return(kept)
  }

  for (i in seq_len(max_iter)) {
    need <- n - length(kept)
    if (need <= 0) {
      break
    }
    pts <- st_sample(wet_src, size = need * 4, type = "random")
    if (length(pts) == 0) {
      next
    }
    boxes <- st_buffer(pts, PATCH_HALF, endCapStyle = "SQUARE")

    # The -128m center buffer keeps box EDGES inside the HUC but corners reach
    # 181m diagonally, so a box near a slanted boundary can still poke out --
    # and chips are cropped from per-HUC rasters, so it must not. Reject those.
    boxes <- boxes[lengths(st_within(boxes, huc_poly)) > 0]

    # Drop candidates that touch existing patches or already-kept boxes
    blocked <- c(avoid, kept)
    if (length(blocked) > 0) {
      boxes <- boxes[lengths(st_intersects(boxes, blocked)) == 0]
    }
    # Greedy de-overlap among the remaining candidates
    for (j in seq_along(boxes)) {
      if (length(kept) >= n) {
        break
      }
      if (
        length(kept) == 0 ||
          lengths(st_intersects(boxes[j], kept)) == 0
      ) {
        kept <- c(kept, boxes[j])
      }
    }
  }
  if (length(kept) < n) {
    message("Only placed ", length(kept), " of ", n, " random patches")
  }
  kept
}

#### Clip NWI into the patch boxes and classify -- same classes as
#### NWI_Extract_From_Patches.R so the output schema matches the reviewed
#### files. `nwi` is the already-filtered NWI from read_nwi_filtered().
classify_nwi_boxes <- function(p_boxes, nwi) {
  # Clip NWI to each patch box; PatchGroup + metadata come from p_boxes.
  if (nrow(nwi) > 0) {
    p_nwi <- st_intersection(p_boxes, nwi) |>
      st_collection_extract("POLYGON") |>
      sf::st_set_geometry("geom") |>
      dplyr::select(
        PatchGroup,
        ReviewerName,
        Confidence,
        BoundariesAltered,
        Comments,
        ATTRIBUTE,
        WETLAND_TYPE
      )
    p_out_nwi <- st_difference(p_boxes, st_union(st_geometry(nwi)))
  } else {
    p_nwi <- NULL
    p_out_nwi <- p_boxes
  }

  # Upland = each box minus the wetlands; metadata + PatchGroup carried from boxes.
  p_out_nwi <- p_out_nwi |>
    st_collection_extract("POLYGON") |>
    sf::st_set_geometry("geom") |>
    mutate(ATTRIBUTE = "UPL", WETLAND_TYPE = "UPL")

  bind_rows(p_nwi, p_out_nwi) |>
    mutate(
      WetClass = case_when(
        str_detect(ATTRIBUTE, "L1|L2|PUB|PUS|PAB|R2|R3") &
          !str_detect(ATTRIBUTE, "PFO|PEM|PSS") ~ "OpenWater",
        str_detect(ATTRIBUTE, "PSS") &
          !str_detect(ATTRIBUTE, "PFO|PEM") ~ "ScrubShrub",
        str_detect(ATTRIBUTE, "PEM") &
          !str_detect(ATTRIBUTE, "PFO|PSS") ~ "Emergent",
        str_detect(ATTRIBUTE, "PFO") &
          !str_detect(ATTRIBUTE, "PSS|PEM") ~ "Forested",
        str_detect(ATTRIBUTE, "PSS") &
          str_detect(ATTRIBUTE, "PFO") ~ "Forested",
        str_detect(ATTRIBUTE, "PSS") &
          str_detect(ATTRIBUTE, "PEM") ~ "Emergent",
        .default = ATTRIBUTE
      )
    ) |>
    dplyr::mutate(
      MOD_CLASS = case_when(
        WetClass == "Emergent" ~ "EMW", #MOD_CLASS is for modeling
        WetClass == "Forested" ~ "FSW",
        WetClass == "ScrubShrub" ~ "SSW",
        WetClass == "OpenWater" ~ "UPL",
        WetClass == "UPL" ~ "UPL",
        .default = "Other"
      ),
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
}

########################################################################################

#### One output file per HUC12: as many random NWI patches as there are
#### reviewed patches across all files in that HUC (so patch count doubles).
extractNWIrandom <- function(huc_id) {
  files_here <- huc_table |> filter(huc12 == huc_id)
  cluster_id <- zones$cluster[match(huc_id, zones$huc12)]
  n <- sum(files_here$n_patches, na.rm = TRUE)

  p_path <- paste0(
    wetlandSavePath,
    "NWIextra_cluster_",
    cluster_id,
    "_huc_",
    huc_id,
    "_256m.gpkg"
  )
  message("New file being created for: ", p_path)
  # REMOVE_EXISTING wipes this HUC's file first so the rebuilt patches reflect
  # the current reviewed patch count and footprints. A HUC that drops out of
  # the reviewed data entirely is never iterated over, so remove its
  # NWIextra_* file by hand.
  if (file.exists(p_path)) {
    if (removeExisting) {
      message("REMOVE_EXISTING: deleting existing ", basename(p_path))
      file.remove(p_path)
    } else {
      message("File already exists")
      return(invisible(NULL))
    }
  }
  if (n == 0) {
    message("No countable patches for HUC ", huc_id, " - skipping")
    return(invisible(NULL))
  }

  huc_poly <- zones |> filter(huc12 == huc_id) |> st_union()
  if (length(huc_poly) == 0 || all(st_is_empty(huc_poly))) {
    message("HUC ", huc_id, " not found in ", basename(hucZones), " - skipping")
    return(invisible(NULL))
  }

  nwi <- read_nwi_filtered(huc_poly)
  if (nrow(nwi) == 0) {
    message("No usable NWI wetlands in HUC ", huc_id, " - skipping")
    return(invisible(NULL))
  }

  boxes <- sample_patch_boxes(huc_poly, n, all_footprints, nwi)
  if (length(boxes) == 0) {
    message("Could not place any random patches in HUC ", huc_id, " - skipping")
    return(invisible(NULL))
  }

  # One square box per patch. The metadata columns are set to the
  # original-creation defaults -- these are NWI-derived delineations and must
  # not inherit the field-review provenance.
  p_boxes <- st_sf(geom = boxes) |>
    dplyr::mutate(
      PatchGroup = dplyr::row_number(),
      ReviewerName = "TBD",
      Confidence = -999,
      BoundariesAltered = NA,
      Comments = "NoComment"
    )

  p_nwi_p <- classify_nwi_boxes(p_boxes, nwi)

  st_write(p_nwi_p, dsn = p_path)

  message("Done writing file at: ", p_path)
}

####################################################################################

lapply(
  unique(na.omit(huc_table$huc12[!is.na(huc_table$n_patches)])),
  extractNWIrandom
)

#### count patches
# l <- list.files(wetlandSavePath, full.names = TRUE)

# lapply(l, \(x) {
#   st_read(x, quiet = TRUE) |> group_by(PatchGroup) |> reframe(n = n()) |> nrow()
# }) |>
#   unlist() |>
#   sum()
