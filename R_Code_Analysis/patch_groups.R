### Shared PatchGroup contract for the DL patch pipeline.
###
### `huc_stack.R` is the single source of truth for the BAND recipe; this file is
### the single source of truth for the PATCH recipe -- how a reviewed/NWI/NWIextra
### vector gpkg is cleaned, split into per-patch groups, and which groups are
### fit to rasterize.
###
### Sourced by:
###   - Raster_ChipsPatches_DL.R  (rasterizes the kept groups)
###   - Check_Patch_Vectors.R     (reports on them without writing anything)
###
### Both therefore agree by construction: the report predicts exactly what the
### rasterizer will do. Change the rules HERE and nowhere else.

suppressPackageStartupMessages({
    library(sf)
})

## --------------------------------------------------------------------------
## Tunables
## --------------------------------------------------------------------------

# Summed polygon area of a group must be >= PATCH_AREA_FRAC * side^2.
# The wetland + upland polygons partition each square, so their summed area
# equals the box area. 0.998 (65,404.9 m2 at side = 256) tolerates reviewed
# polygons that come out ~255.98 m on a side from sliver/precision loss -- still
# close enough to rasterize to a full 256x256 window. Below that the square is
# a HUC-edge box clipped by the watershed boundary, and is dropped.
PATCH_AREA_FRAC <- 0.998

# A group's bounding box must be side x side, within this many metres. Reviewed
# squares measure ~255.98-256.5 m a side; a group whose id was reused across
# separated squares is off by tens to thousands of metres, so 1 m separates them
# cleanly. Without this check such a group PASSES the area filter (its summed
# area exceeds one box) and gets cropped to its whole bbox, writing
# multi-thousand-pixel "patches" -- 4919 x 16907 was seen in the wild.
PATCH_BBOX_TOL_M <- 1

## --------------------------------------------------------------------------
## Cleaning
## --------------------------------------------------------------------------

#' Clean a patch vector layer into exploded, valid single POLYGONs.
#'
#' Returns a list(sf = <sf or NULL>, n_empty = <int>, note = <chr>). `sf` is NULL
#' when nothing usable survives; `note` then says why. Never throws -- geometry
#' errors are captured into `note` so one bad file cannot abort a batch.
clean_patch_vector <- function(x) {
    # Drop EMPTY geometries before anything else. A single empty feature poisons
    # the whole file downstream, in two different ways depending on what
    # st_make_valid() makes of it:
    #   - it can become a degenerate LINESTRING among the polygons, so the
    #     st_cast() below dies with "use smaller steps for st_cast" -- a hard
    #     error that used to cancel every remaining gpkg in the cluster
    #     (gps_jc cluster_225 huc_043001060104, one empty UPL of 32);
    #   - it can leave an sfc_GEOMETRY element with st_dimension() == NA, which
    #     makes st_collection_extract() return ZERO rows with no error and no
    #     message, so the HUC silently produced 0 patches
    #     (NWI_SMfix cluster_95 huc_020401040203, 5 empties of 84).
    n_empty <- sum(st_is_empty(x))
    if (n_empty > 0) {
        x <- x[!st_is_empty(x), ]
    }
    if (nrow(x) == 0) {
        return(list(sf = NULL, n_empty = n_empty, note = "0 features after dropping empties"))
    }
    v <- tryCatch(
        {
            # Repair invalid geometry rather than dropping it. Dropping (the old
            # x[st_is_valid(x), ]) silently lost whole patches -- e.g. cluster_11
            # PG19 (both polys invalid -> patch vanished) and cluster_22 PG14
            # (invalid UPL fill removed -> remaining slivers fell below the area
            # filter). make_valid can emit GEOMETRYCOLLECTIONs (polygon + sliver
            # line), so keep only the polygonal parts.
            v <- st_make_valid(x)
            v <- suppressWarnings(st_collection_extract(v, "POLYGON"))
            # Explode multi-part features to single polygons. NWI's UPL
            # "background" is one MULTIPOLYGON whose parts are scattered across
            # the whole HUC; grouping is by PatchGroup so this no longer inflates
            # crop windows, but exploding keeps the rasterize/area math
            # per-polygon and matches prior behaviour.
            suppressWarnings(st_cast(st_cast(v, "MULTIPOLYGON"), "POLYGON"))
        },
        error = function(e) {
            structure(list(), class = "patch_clean_error", msg = conditionMessage(e))
        }
    )
    if (inherits(v, "patch_clean_error")) {
        return(list(
            sf = NULL, n_empty = n_empty,
            note = paste0("cleaning error: ", attr(v, "msg"))
        ))
    }
    if (nrow(v) == 0) {
        return(list(sf = NULL, n_empty = n_empty, note = "0 polygons after cleaning"))
    }
    list(sf = v, n_empty = n_empty, note = "")
}

## --------------------------------------------------------------------------
## Grouping + classification
## --------------------------------------------------------------------------

#' Per-PatchGroup summed area and bounding-box dimensions.
#' `v` must be the cleaned sf from clean_patch_vector(), with NA PatchGroups
#' already removed (see drop_na_patch_groups()).
patch_group_summary <- function(v) {
    parea <- as.numeric(st_area(v))
    grp_idx <- split(seq_len(nrow(v)), as.character(v$PatchGroup))
    do.call(rbind, lapply(names(grp_idx), function(g) {
        i <- grp_idx[[g]]
        bb <- st_bbox(v[i, ])
        data.frame(
            PatchGroup = g,
            area = sum(parea[i]),
            w = as.numeric(bb["xmax"] - bb["xmin"]),
            h = as.numeric(bb["ymax"] - bb["ymin"]),
            stringsAsFactors = FALSE
        )
    }))
}

#' Remove polygons with an NA PatchGroup.
#'
#' An NA PatchGroup cannot name an output raster, and `NA %in% NA` is TRUE in R
#' -- so NA groups used to slip through BOTH the area filter and its drop
#' message, then get written as "..._patch_NA_256m.tif" or die with
#' "[crop] extents do not overlap".
drop_na_patch_groups <- function(v) {
    n_na <- sum(is.na(v$PatchGroup))
    if (n_na > 0) {
        v <- v[!is.na(v$PatchGroup), ]
    }
    list(sf = v, n_na = n_na)
}

#' Split a patch_group_summary() into keep / too-small / wrong-shape.
#' Returns list(keep = <chr ids>, small = <df>, oversize = <df>).
classify_patch_groups <- function(summary, side) {
    ok_area <- summary$area >= PATCH_AREA_FRAC * (side^2)
    ok_box <- abs(summary$w - side) <= PATCH_BBOX_TOL_M &
        abs(summary$h - side) <= PATCH_BBOX_TOL_M
    list(
        keep = summary$PatchGroup[ok_area & ok_box],
        small = summary[!ok_area, , drop = FALSE],
        oversize = summary[ok_area & !ok_box, , drop = FALSE]
    )
}

## --------------------------------------------------------------------------
## Naming
## --------------------------------------------------------------------------

#' Parse cluster + HUC from a patch vector filename.
#' A filename missing the literal _huc_ / _cluster_ separator yields NA, which
#' the rasterizer treats as "skip this file" -- it used to travel into
#' huc_source_paths() and abort the whole cluster.
parse_patch_filename <- function(bn) {
    list(
        cluster = regmatches(bn, regexpr("(?<=cluster_)\\d+", bn, perl = TRUE))[1],
        huc = regmatches(bn, regexpr("(?<=huc_)\\d+", bn, perl = TRUE))[1]
    )
}

#' Output filename prefix for a patch vector file, matching the rasterizer:
#' "<tag>_cluster_<N>_huc_<HUCID>_patch_". The literal _huc_ separator keeps
#' cluster 12 from matching cluster 120; the full tag keeps a HUC's multiple
#' gpkgs from colliding.
patch_file_prefix <- function(bn) {
    p <- parse_patch_filename(bn)
    if (is.na(p$cluster) || is.na(p$huc)) {
        return(NA_character_)
    }
    tag <- sub("_cluster_.*$", "", tools::file_path_sans_ext(bn))
    paste0(tag, "_cluster_", p$cluster, "_huc_", p$huc, "_patch_")
}

#' Raster output folder for a given patch vector folder, matching the rasterizer.
patch_out_dir <- function(patch_path) {
    if (grepl("R_Patches_Vector_NWIextra/?$", patch_path)) {
        "Data/Training_Data/R_Patches_NWIextra/"
    } else if (grepl("R_Patches_Vector_NWI/?$", patch_path)) {
        "Data/Training_Data/R_Patches_NWI/"
    } else {
        "Data/Training_Data/R_Patches/"
    }
}
