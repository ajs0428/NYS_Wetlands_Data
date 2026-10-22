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

# Knobs for building a LARGER extra set (e.g. the 10x NWI arm). All come from
# env vars exported by nwiextra_in_patch_extract.sh; the defaults reproduce the
# original 1x NWIextra build exactly (same seed stream, same filenames).
#   MULTIPLIER   new patches per HUC = MULTIPLIER x reviewed patch count
#   FILE_PREFIX  output filename prefix (NWIextra -> NWIextra_cluster_..gpkg)
#   AVOID_DIRS   comma-separated extra vector folders whose patch footprints the
#                new boxes must not overlap (reviewed footprints always are)
#   MIN_GAP      metres of clearance required from every blocked footprint and
#                between new boxes (0 = merely non-touching)
#   SEED         RNG seed
#   PER_HUC_SEED 1 = reseed per HUC (SEED + HUC rank) so a resumed run
#                reproduces a full one; 0 = one stream across HUCs (original)
#   MAX_ITER     rejection-sampling rounds per HUC before logging a shortfall
#   ONLY_HUCS    comma-separated HUC12 ids to restrict the run to (testing)
env_num <- function(name, default) {
  v <- Sys.getenv(name, "")
  if (nzchar(v)) as.numeric(v) else default
}
env_list <- function(name) {
  v <- trimws(strsplit(Sys.getenv(name, ""), ",")[[1]])
  v[nzchar(v)]
}
multiplier <- env_num("MULTIPLIER", 1)
filePrefix <- Sys.getenv("FILE_PREFIX", "NWIextra")
avoidDirs <- env_list("AVOID_DIRS")
minGap <- env_num("MIN_GAP", 0)
seed <- env_num("SEED", 11)
perHucSeed <- parse_flag(Sys.getenv("PER_HUC_SEED", "0"))
maxIter <- env_num("MAX_ITER", 25)
onlyHucs <- env_list("ONLY_HUCS")
# Spill mode (the 10x build): see the SPILL section at the bottom.
#   SPILL        1 = place each HUC's shortfall in other stack-ready HUCs
#   READY_PAIRS  cluster:huc list of HUCs with the full factorial stack
#                (check_stack_ready.sh *_valid_pairs.txt); required for SPILL
#   COUNT_DIR    raster patch folder whose per-HUC file count (x MULTIPLIER)
#                sets the target, e.g. R_Patches/ -- counts only patches that
#                actually made it into the training set
#   STALL_LIMIT  give up on a HUC after this many rounds that add no box
spill <- parse_flag(Sys.getenv("SPILL", "0"))
readyPairs <- Sys.getenv("READY_PAIRS", "")
countDir <- Sys.getenv("COUNT_DIR", "")
stallLimit <- env_num("STALL_LIMIT", Inf)
message(
  "multiplier: ", multiplier, " | prefix: ", filePrefix,
  " | avoid dirs: ", if (length(avoidDirs)) paste(avoidDirs, collapse = ", ") else "none",
  " | min gap: ", minGap, " m | seed: ", seed, " (per-HUC: ", perHucSeed, ")",
  " | max iter: ", maxIter,
  if (length(onlyHucs)) paste0(" | only HUCs: ", paste(onlyHucs, collapse = ", ")) else "",
  " | spill: ", spill,
  if (spill) paste0(" (ready pairs: ", readyPairs, ", count dir: ", countDir, ", stall limit: ", stallLimit, ")") else "",
  "\n"
)

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

set.seed(seed)

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

#### Footprints of previously generated extra sets (AVOID_DIRS, e.g. the 1x
#### NWIextra when building the 10x set) so the new boxes are new ground and
#### the label-quantity pools nest without duplicate locations.
for (d in avoidDirs) {
  fs <- list.files(d, pattern = "\\.gpkg$", full.names = TRUE)
  if (length(fs) == 0) {
    stop("AVOID_DIRS folder has no .gpkg files: ", d, call. = FALSE)
  }
  fp <- do.call(c, lapply(fs, \(f) st_union(st_geometry(st_read(f, quiet = TRUE)))))
  message("Avoiding ", length(fs), " footprint files from ", d)
  all_footprints <- c(all_footprints, fp)
}

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
sample_patch_boxes <- function(huc_poly, n, avoid, nwi, max_iter = 25, gap = 0,
                               stall_limit = Inf) {
  # Clearance test: plain intersection (touching counts) when gap = 0.
  hits <- function(x, y) {
    if (gap > 0) st_is_within_distance(x, y, gap) else st_intersects(x, y)
  }
  # Only footprints near this HUC matter; pre-filtering keeps the per-round
  # tests cheap when the kept set grows into the hundreds.
  if (length(avoid) > 0) {
    avoid <- avoid[lengths(st_is_within_distance(avoid, huc_poly, gap + 1)) > 0]
  }
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

  stalled <- 0
  for (i in seq_len(max_iter)) {
    need <- n - length(kept)
    if (need <= 0) {
      break
    }
    # A HUC that is packed full stops yielding boxes; give up after
    # stall_limit empty rounds instead of burning all max_iter rounds.
    if (stalled >= stall_limit) {
      break
    }
    n_before <- length(kept)
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
      boxes <- boxes[lengths(hits(boxes, blocked)) == 0]
    }
    # Greedy de-overlap among the remaining candidates
    for (j in seq_along(boxes)) {
      if (length(kept) >= n) {
        break
      }
      if (
        length(kept) == 0 ||
          lengths(hits(boxes[j], kept)) == 0
      ) {
        kept <- c(kept, boxes[j])
      }
    }
    stalled <- if (length(kept) > n_before) 0 else stalled + 1
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

#### Label the boxes with NWI and write one HUC's file. The metadata columns
#### are set to the original-creation defaults -- these are NWI-derived
#### delineations and must not inherit the field-review provenance.
write_boxes <- function(boxes, nwi, p_path) {
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

out_path <- function(huc_id) {
  paste0(
    wetlandSavePath,
    filePrefix,
    "_cluster_",
    zones$cluster[match(huc_id, zones$huc12)],
    "_huc_",
    huc_id,
    "_256m.gpkg"
  )
}

#### One output file per HUC12: as many random NWI patches as there are
#### reviewed patches across all files in that HUC (so patch count doubles),
#### times MULTIPLIER.
extractNWIrandom <- function(huc_id) {
  files_here <- huc_table |> filter(huc12 == huc_id)
  cluster_id <- zones$cluster[match(huc_id, zones$huc12)]
  n <- round(multiplier * sum(files_here$n_patches, na.rm = TRUE))

  p_path <- paste0(
    wetlandSavePath,
    filePrefix,
    "_cluster_",
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

  if (perHucSeed) {
    set.seed(seed + match(huc_id, sort(unique(huc_table$huc12))))
  }
  boxes <- sample_patch_boxes(
    huc_poly, n, all_footprints, nwi,
    max_iter = maxIter, gap = minGap, stall_limit = stallLimit
  )
  message("Placed ", length(boxes), " of ", n, " patches in HUC ", huc_id)
  if (length(boxes) == 0) {
    message("Could not place any random patches in HUC ", huc_id, " - skipping")
    return(invisible(NULL))
  }

  write_boxes(boxes, nwi, p_path)
}

####################################################################################

if (!spill) {
  run_hucs <- unique(na.omit(huc_table$huc12[!is.na(huc_table$n_patches)]))
  if (length(onlyHucs)) {
    run_hucs <- intersect(run_hucs, onlyHucs)
  }
  lapply(run_hucs, extractNWIrandom)
}

####################################################################################
#### SPILL mode (the 10x build). Some reviewed HUCs cannot hold MULTIPLIER x
#### their patch count -- there is not enough vegetated NWI to center that many
#### non-overlapping boxes on. Each reviewed HUC is filled to capacity, then its
#### shortfall is placed, in order, in
####   1. stack-ready HUCs in the SAME cluster, nearest first, then
####   2. the nearest stack-ready HUCs anywhere else,
#### skipping HUCs already packed full. "Stack-ready" = the full factorial
#### source suite (lidar + leaf-off ortho), from READY_PAIRS, so every box
#### rasterizes. Reviewed HUCs are never spill targets: they hold field TEST
#### patches, and the DL huc12 leakage guard would drop extras placed there.
#### Every box still lies wholly inside one HUC12 and each HUC gets one file.
#### Boxes placed for one source HUC block the next, so this is all-or-nothing
#### (one seeded stream, fixed order): it refuses to run over existing outputs
#### unless REMOVE_EXISTING. <prefix>_spill_manifest.csv records which source
#### HUC each target HUC's boxes were placed for.
if (spill) {
  if (!nzchar(readyPairs) || !file.exists(readyPairs)) {
    stop("SPILL needs READY_PAIRS (check_stack_ready.sh *_valid_pairs.txt)", call. = FALSE)
  }
  ready <- unique(sub("^.*:", "", trimws(readLines(readyPairs))))
  ready <- ready[nzchar(ready) & ready %in% zones$huc12]
  message("Stack-ready HUCs: ", length(ready))

  # Per-HUC targets: MULTIPLIER x patch count, from the rasters in COUNT_DIR if
  # given (patches that are actually in the training set), else the vectors.
  if (nzchar(countDir)) {
    cnt <- table(str_match(list.files(countDir, pattern = "\\.tif$"), "_huc_(\\d+)_")[, 2])
    targets <- tibble(huc12 = names(cnt), n_src = as.integer(cnt))
  } else {
    targets <- huc_table |>
      filter(!is.na(n_patches), !is.na(huc12)) |>
      group_by(huc12) |>
      summarise(n_src = sum(n_patches))
  }
  targets <- targets |>
    filter(huc12 %in% zones$huc12) |>
    mutate(target = round(multiplier * n_src)) |>
    arrange(huc12)
  if (length(onlyHucs)) {
    targets <- targets |> filter(huc12 %in% onlyHucs)
  }
  message("Spill targets: ", nrow(targets), " source HUCs, ", sum(targets$target), " patches")

  existing <- list.files(wetlandSavePath, pattern = paste0("^", filePrefix, "_.*\\.gpkg$"), full.names = TRUE)
  if (length(existing) > 0) {
    if (!removeExisting) {
      stop(
        length(existing), " ", filePrefix, " files already in ", wetlandSavePath,
        "; spill mode is all-or-nothing -- rerun with REMOVE_EXISTING=1",
        call. = FALSE
      )
    }
    message("REMOVE_EXISTING: deleting ", length(existing), " existing files")
    file.remove(existing)
  }

  reviewed_hucs <- unique(na.omit(huc_table$huc12))
  spill_pool <- setdiff(ready, reviewed_hucs)
  centroids <- zones |>
    group_by(huc12) |>
    summarise(cluster = first(cluster)) |>
    st_centroid()

  placed <- list() # huc -> sfc of boxes
  nwi_cache <- list()
  saturated <- character()
  manifest <- list()

  place <- function(huc_id, n, source_huc) {
    huc_poly <- zones |> filter(huc12 == huc_id) |> st_union()
    if (is.null(nwi_cache[[huc_id]])) {
      nwi_cache[[huc_id]] <<- read_nwi_filtered(huc_poly)
    }
    nwi <- nwi_cache[[huc_id]]
    b <- if (nrow(nwi) == 0) {
      st_sfc(crs = st_crs(huc_poly))
    } else {
      sample_patch_boxes(
        huc_poly, n, all_footprints, nwi,
        max_iter = maxIter, gap = minGap, stall_limit = stallLimit
      )
    }
    if (length(b) < n) {
      saturated <<- c(saturated, huc_id)
    }
    if (length(b) > 0) {
      # c(NULL, sfc) would drop the sfc class, so start from the first batch
      placed[[huc_id]] <<- if (is.null(placed[[huc_id]])) b else c(placed[[huc_id]], b)
      all_footprints <<- c(all_footprints, b)
    }
    manifest[[length(manifest) + 1]] <<- tibble(
      huc12 = huc_id,
      cluster = zones$cluster[match(huc_id, zones$huc12)],
      source_huc12 = source_huc,
      requested = n,
      placed = length(b)
    )
    message("  ", huc_id, " (for ", source_huc, "): placed ", length(b), " of ", n)
    length(b)
  }

  # Phase 1: every source HUC fills itself (if stack-ready).
  targets$need <- targets$target
  for (k in seq_len(nrow(targets))) {
    h <- targets$huc12[k]
    if (h %in% ready) {
      message("Own HUC ", h, ": target ", targets$target[k])
      targets$need[k] <- targets$need[k] - place(h, targets$target[k], h)
    } else {
      message("Own HUC ", h, " not stack-ready; all ", targets$target[k], " spill")
    }
  }
  message("Phase 1 placed ", sum(targets$target - targets$need), "; shortfall ", sum(targets$need))

  # Phase 2: spill each shortfall, same cluster first, then nearest anywhere.
  for (k in which(targets$need > 0)) {
    h <- targets$huc12[k]
    src <- centroids[centroids$huc12 == h, ]
    cand <- centroids[centroids$huc12 %in% setdiff(spill_pool, saturated), ]
    cand$same <- cand$cluster == src$cluster
    cand$dist <- as.numeric(st_distance(cand, src))
    cand <- cand[order(!cand$same, cand$dist), ]
    message("Spilling ", targets$need[k], " for ", h, " (cluster ", src$cluster, ")")
    for (c_huc in cand$huc12) {
      if (targets$need[k] <= 0) {
        break
      }
      if (c_huc %in% saturated) {
        next
      }
      targets$need[k] <- targets$need[k] - place(c_huc, targets$need[k], h)
    }
    if (targets$need[k] > 0) {
      message("UNMET: ", targets$need[k], " patches for ", h)
    }
  }

  for (h in names(placed)) {
    write_boxes(placed[[h]], nwi_cache[[h]], out_path(h))
  }
  man <- bind_rows(manifest)
  write.csv(man, paste0(wetlandSavePath, filePrefix, "_spill_manifest.csv"), row.names = FALSE)
  message(
    "SPILL DONE: ", sum(man$placed), " of ", sum(targets$target), " patches in ",
    length(placed), " HUC files (", sum(man$placed[man$huc12 == man$source_huc12]),
    " in source HUCs, ", sum(man$placed[man$huc12 != man$source_huc12]), " spilled); unmet ",
    sum(pmax(targets$need, 0))
  )
}

#### count patches
# l <- list.files(wetlandSavePath, full.names = TRUE)

# lapply(l, \(x) {
#   st_read(x, quiet = TRUE) |> group_by(PatchGroup) |> reframe(n = n()) |> nrow()
# }) |>
#   unlist() |>
#   sum()
