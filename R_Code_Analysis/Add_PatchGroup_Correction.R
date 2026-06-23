# Add_PatchGroup_Correction.R
#
# One-off correction: add an integer `PatchGroup` identifier to existing vector
# patch files that pre-date the PatchGroup change in Vector_ChipsPatches_DL.R.
#
# Each HUC12 .gpkg holds many polygons belonging to non-overlapping 256 m square
# patches. We recover the individual patches by dissolving all polygons and
# splitting into connected components (each component == one 256 m square), then
# stamp every polygon with the PatchGroup of the square it falls inside (matched
# via point-on-surface, which is robust to shared boundaries).
#
# Files where the 256 m squares OVERLAP/TOUCH (squares merge into one oversized
# blob) cannot be split by proximity alone, so they are SKIPPED and logged.
#
# Each processed file is backed up once before being overwritten.
#
# Usage:
#   module load R/4.4.3
#   Rscript R_Code_Analysis/Add_PatchGroup_Correction.R [dir1] [dir2] ...

suppressMessages({
    library(sf)
    library(dplyr)
})

## positional args (interactive defaults, then overwritten by commandArgs) ----
args <- c("Data/Training_Data/R_Patches_Vector_Reviewed",
          "Data/Training_Data/R_Patches_Vector_NWI")
cmd <- commandArgs(trailingOnly = TRUE)
if (length(cmd) > 0) args <- cmd

dirs       <- args
backup_dir <- "Data/Training_Data/_PatchGroup_backup"

PATCH_SIDE <- 256                 # metres
OVERSIZE   <- PATCH_SIDE * 1.15   # bbox dim above this => merged squares -> skip

## helper: process one file ---------------------------------------------------
add_patchgroup <- function(f) {
    x <- st_read(f, quiet = TRUE)
    gcol <- attr(x, "sf_column")
    g <- st_geometry(x)

    # dissolve -> connected components; each component is one 256 m square
    comp <- st_cast(st_union(g), "POLYGON")
    comp_sfc <- st_sfc(comp, crs = st_crs(x))

    # detect merged (overlapping/touching) squares via oversized bbox
    bb_dim <- vapply(comp, function(p) {
        bb <- st_bbox(st_sfc(p, crs = st_crs(x)))
        max(bb["xmax"] - bb["xmin"], bb["ymax"] - bb["ymin"])
    }, numeric(1))
    if (any(bb_dim > OVERSIZE)) {
        return(list(status = "skip",
                    reason = sprintf("merged squares (max bbox dim %.0f m, %d component(s))",
                                     max(bb_dim), length(comp))))
    }

    # order patches top->bottom, left->right for stable, spatial numbering
    ctr <- st_coordinates(st_centroid(comp_sfc))
    ord <- order(-round(ctr[, "Y"]), round(ctr[, "X"]))
    patches <- st_sf(PatchGroup = seq_along(comp_sfc),
                     geometry = comp_sfc[ord])

    # assign each polygon to the patch its interior point falls in
    reps <- suppressWarnings(st_point_on_surface(g))
    idx  <- as.integer(st_within(reps, st_geometry(patches)))
    if (anyNA(idx)) {                       # fallback for edge precision
        miss <- which(is.na(idx))
        idx[miss] <- as.integer(st_nearest_feature(reps[miss], st_geometry(patches)))
    }
    if (anyNA(idx)) {
        return(list(status = "skip", reason = "unassignable polygons"))
    }

    x$PatchGroup <- patches$PatchGroup[idx]

    list(status = "ok", data = x, gcol = gcol, npatch = nrow(patches))
}

## run ------------------------------------------------------------------------
files <- unlist(lapply(dirs, list.files, pattern = "\\.gpkg$", full.names = TRUE))
message("Files found: ", length(files))

log_rows <- list()
for (f in files) {
    res <- tryCatch(add_patchgroup(f), error = function(e) list(status = "error",
                                                                reason = conditionMessage(e)))
    if (res$status != "ok") {
        message(sprintf("SKIP  %-60s [%s] %s", basename(f), res$status, res$reason))
        log_rows[[length(log_rows) + 1]] <- data.frame(file = f, status = res$status,
                                                        detail = res$reason)
        next
    }

    # back up original once, then overwrite preserving layer + geom column name
    rel  <- sub("^Data/Training_Data/", "", f)
    bdst <- file.path(backup_dir, rel)
    dir.create(dirname(bdst), recursive = TRUE, showWarnings = FALSE)
    if (!file.exists(bdst)) file.copy(f, bdst)

    lyr <- st_layers(f)$name[1]
    st_write(res$data, dsn = f, layer = lyr, append = FALSE,
             delete_dsn = TRUE, quiet = TRUE)

    message(sprintf("OK    %-60s patches=%d", basename(f), res$npatch))
    log_rows[[length(log_rows) + 1]] <- data.frame(file = f, status = "ok",
                                                   detail = paste0("patches=", res$npatch))
}

log_df <- do.call(rbind, log_rows)
message("\nProcessed: ", sum(log_df$status == "ok"),
        "  Skipped: ", sum(log_df$status != "ok"))
readr_ok <- requireNamespace("readr", quietly = TRUE)
out_log <- "Data/Training_Data/_PatchGroup_correction_log.csv"
if (readr_ok) readr::write_csv(log_df, out_log) else write.csv(log_df, out_log, row.names = FALSE)
message("Log written: ", out_log)
