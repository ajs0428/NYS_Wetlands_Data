### Status report for the DL patch vector gpkgs.
###
### Reads a patch vector folder, applies the SAME cleaning and filtering that
### Raster_ChipsPatches_DL.R applies (both source patch_groups.R), and writes a
### plain-text report of every file that will lose patches -- plus a
### reconciliation against the patch rasters already on disk.
###
### Nothing is modified: this is read-only.
###
### Usage (normally via Shell_Scripts/check_patch_vectors.sh):
###   Rscript R_Code_Analysis/Check_Patch_Vectors.R <vectorDir> <clusters> <reportPath> [checkRasters]
###
###   vectorDir    e.g. Data/Training_Data/R_Patches_Vector_Reviewed/
###   clusters     comma-separated cluster numbers, or "all"
###   reportPath   .txt file to write
###   checkRasters 1/0 -- also open every output raster to verify 256x256 and
###                band count (slower). Default 1.

suppressPackageStartupMessages({
    library(sf)
    library(stringr)
})

source("R_Code_Analysis/patch_groups.R")

args <- c(
    "Data/Training_Data/R_Patches_Vector_Reviewed/",
    "all",
    "Shell_Scripts/logs/patch_vector_check.txt",
    "1"
)
args <- commandArgs(trailingOnly = TRUE)

vectorDir <- args[1]
clusterArg <- if (length(args) >= 2 && nzchar(args[2])) args[2] else "all"
reportPath <- if (length(args) >= 3 && nzchar(args[3])) {
    args[3]
} else {
    file.path(
        "Shell_Scripts/logs",
        paste0(
            "patch_vector_check_", basename(sub("/$", "", vectorDir)), "_",
            format(Sys.Date(), "%Y%m%d"), ".txt"
        )
    )
}
checkRasters <- !(length(args) >= 4 && args[4] %in% c("0", "false", "FALSE", "no"))

PATCH_SIZE_HALF <- 128 # matches the rasterizer's default patchSize arg
side <- PATCH_SIZE_HALF * 2

if (!dir.exists(vectorDir)) {
    stop("vector directory does not exist: ", vectorDir)
}
outDir <- patch_out_dir(vectorDir)

## ---------------------------------------------------------------------------
## Select files
## ---------------------------------------------------------------------------
all_files <- list.files(vectorDir, pattern = "\\.gpkg$", full.names = TRUE)
if (identical(tolower(clusterArg), "all")) {
    files <- all_files
    cluster_label <- "all"
} else {
    want <- trimws(strsplit(clusterArg, ",")[[1]])
    want <- want[nzchar(want)]
    file_cl <- vapply(
        basename(all_files),
        function(b) {
            v <- parse_patch_filename(b)$cluster
            if (is.na(v)) NA_character_ else v
        },
        character(1)
    )
    files <- all_files[!is.na(file_cl) & file_cl %in% want]
    # A file whose name has no parsable cluster can't be assigned to a batch, but
    # it is still a real problem -- keep it so the report can flag it.
    files <- c(files, all_files[is.na(file_cl)])
    cluster_label <- paste(want, collapse = ",")
}
files <- sort(unique(files))

## ---------------------------------------------------------------------------
## Inspect each file
## ---------------------------------------------------------------------------
rows <- list()
for (f in files) {
    bn <- basename(f)
    flags <- character()
    parsed <- parse_patch_filename(bn)
    prefix <- patch_file_prefix(bn)

    if (is.na(parsed$cluster) || is.na(parsed$huc)) {
        flags <- c(flags, paste0(
            "FILENAME has no _cluster_/_huc_ separator -> the rasterizer skips ",
            "this file entirely (expected <tag>_cluster_<N>_huc_<HUCID>_...)"
        ))
    }
    if (grepl("[[:space:]]", bn)) {
        flags <- c(flags, "FILENAME contains whitespace")
    }

    x <- tryCatch(st_read(f, quiet = TRUE), error = function(e) NULL)
    if (is.null(x)) {
        rows[[length(rows) + 1]] <- list(
            file = bn, cluster = parsed$cluster, huc = parsed$huc,
            prefix = prefix, nfeat = NA_integer_, expected = 0L,
            flags = c(flags, "UNREADABLE (st_read failed)")
        )
        next
    }
    nfeat <- nrow(x)

    cleaned <- clean_patch_vector(x)
    if (cleaned$n_empty > 0) {
        flags <- c(flags, paste0(
            cleaned$n_empty, " empty geometry/geometries dropped"
        ))
    }
    if (is.null(cleaned$sf)) {
        rows[[length(rows) + 1]] <- list(
            file = bn, cluster = parsed$cluster, huc = parsed$huc,
            prefix = prefix, nfeat = nfeat, expected = 0L,
            flags = c(flags, paste0("NO PATCHES: ", cleaned$note))
        )
        next
    }
    v <- cleaned$sf

    if (!"PatchGroup" %in% names(v)) {
        rows[[length(rows) + 1]] <- list(
            file = bn, cluster = parsed$cluster, huc = parsed$huc,
            prefix = prefix, nfeat = nfeat, expected = 0L,
            flags = c(flags, "NO PATCHES: no PatchGroup column")
        )
        next
    }
    na_drop <- drop_na_patch_groups(v)
    v <- na_drop$sf
    if (na_drop$n_na > 0) {
        flags <- c(flags, paste0(
            na_drop$n_na, " polygon(s) with NA PatchGroup dropped"
        ))
    }
    if (nrow(v) == 0) {
        rows[[length(rows) + 1]] <- list(
            file = bn, cluster = parsed$cluster, huc = parsed$huc,
            prefix = prefix, nfeat = nfeat, expected = 0L,
            flags = c(flags, "NO PATCHES: no usable PatchGroup")
        )
        next
    }

    summ <- patch_group_summary(v)
    cls <- classify_patch_groups(summ, side)
    if (nrow(cls$small) > 0) {
        flags <- c(flags, paste0(
            nrow(cls$small), " PatchGroup(s) below the ",
            round(PATCH_AREA_FRAC * side^2), " m2 area threshold: ",
            paste0(
                cls$small$PatchGroup, " (", round(cls$small$area), " m2)",
                collapse = ", "
            )
        ))
    }
    if (nrow(cls$oversize) > 0) {
        flags <- c(flags, paste0(
            nrow(cls$oversize), " PatchGroup(s) whose bbox is NOT one ", side,
            " m square (id reused across separated patches?): ",
            paste0(
                cls$oversize$PatchGroup, " (", round(cls$oversize$w), " x ",
                round(cls$oversize$h), " m)",
                collapse = ", "
            )
        ))
    }

    rows[[length(rows) + 1]] <- list(
        file = bn, cluster = parsed$cluster, huc = parsed$huc,
        prefix = prefix, nfeat = nfeat, expected = length(cls$keep),
        keep = cls$keep, flags = flags
    )
}

## ---------------------------------------------------------------------------
## Reconcile against rasters on disk
## ---------------------------------------------------------------------------
on_disk <- if (dir.exists(outDir)) list.files(outDir, pattern = "\\.tif$") else character()

for (i in seq_along(rows)) {
    r <- rows[[i]]
    if (is.na(r$prefix)) {
        rows[[i]]$actual <- 0L
        rows[[i]]$missing <- character()
        rows[[i]]$orphan <- character()
        next
    }
    mine <- on_disk[startsWith(on_disk, r$prefix)]
    ids <- sub(paste0("^", r$prefix), "", mine)
    ids <- sub(paste0("_", side, "m\\.tif$"), "", ids)
    keep <- if (is.null(r$keep)) character() else r$keep
    rows[[i]]$actual <- length(mine)
    rows[[i]]$missing <- setdiff(keep, ids)
    rows[[i]]$orphan <- setdiff(ids, keep)
    rows[[i]]$files_on_disk <- mine
}

# Optional: verify the geometry of each raster that should exist.
bad_dims <- character()
if (checkRasters && length(on_disk) > 0) {
    ok_terra <- requireNamespace("terra", quietly = TRUE)
    if (!ok_terra) {
        bad_dims <- "terra unavailable - raster dimension check skipped"
    } else {
        want_files <- unlist(lapply(rows, function(r) {
            if (is.null(r$files_on_disk)) character() else r$files_on_disk
        }))
        for (b in want_files) {
            p <- file.path(outDir, b)
            d <- tryCatch(
                {
                    rr <- terra::rast(p)
                    c(terra::nrow(rr), terra::ncol(rr), terra::nlyr(rr))
                },
                error = function(e) NULL
            )
            if (is.null(d)) {
                bad_dims <- c(bad_dims, paste0(b, " : UNREADABLE"))
            } else if (d[1] != side || d[2] != side) {
                bad_dims <- c(bad_dims, sprintf(
                    "%s : %d x %d px (expected %d x %d)", b, d[1], d[2], side, side
                ))
            }
        }
    }
}

## ---------------------------------------------------------------------------
## Write the report
## ---------------------------------------------------------------------------
dir.create(dirname(reportPath), showWarnings = FALSE, recursive = TRUE)
con <- file(reportPath, open = "wt")
w <- function(...) cat(..., "\n", sep = "", file = con)

rule <- strrep("=", 78)
w(rule)
w("PATCH VECTOR STATUS REPORT")
w(rule)
w("generated     : ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
w("vector folder : ", vectorDir)
w("raster folder : ", outDir)
w("clusters      : ", cluster_label)
w("patch size    : ", side, " m (", side, " x ", side, " px)")
w("area threshold: ", round(PATCH_AREA_FRAC * side^2), " m2 (",
    PATCH_AREA_FRAC, " x full square)")
w("bbox tolerance: +/- ", PATCH_BBOX_TOL_M, " m")
w("")

tot_files <- length(rows)
tot_expected <- sum(vapply(rows, function(r) as.integer(r$expected), integer(1)))
tot_actual <- sum(vapply(rows, function(r) as.integer(r$actual), integer(1)))
tot_missing <- sum(vapply(rows, function(r) length(r$missing), integer(1)))
tot_orphan <- sum(vapply(rows, function(r) length(r$orphan), integer(1)))
flagged <- Filter(function(r) length(r$flags) > 0, rows)
mismatched <- Filter(
    function(r) length(r$missing) > 0 || length(r$orphan) > 0, rows
)

w(rule)
w("SUMMARY")
w(rule)
w(sprintf("%-34s %6d", "gpkg files checked", tot_files))
w(sprintf("%-34s %6d", "patches expected from vectors", tot_expected))
w(sprintf("%-34s %6d", "patch rasters on disk", tot_actual))
w(sprintf("%-34s %6d", "expected but MISSING on disk", tot_missing))
w(sprintf("%-34s %6d", "on disk but NOT expected (stale)", tot_orphan))
w(sprintf("%-34s %6d", "files with flags", length(flagged)))
if (checkRasters) {
    w(sprintf("%-34s %6d", "rasters with wrong dimensions", length(bad_dims)))
}
w("")
if (tot_missing == 0 && tot_orphan == 0 && length(flagged) == 0 &&
    length(bad_dims) == 0) {
    w("STATUS: OK - vectors are clean and rasters match.")
} else {
    w("STATUS: ACTION NEEDED - see sections below.")
}
w("")

if (length(flagged) > 0) {
    w(rule)
    w("FLAGGED VECTOR FILES (", length(flagged), ")")
    w(rule)
    for (r in flagged) {
        w("")
        w(r$file)
        w(sprintf(
            "    cluster %s | HUC %s | %s features | %d patch(es) expected",
            ifelse(is.na(r$cluster), "?", r$cluster),
            ifelse(is.na(r$huc), "?", r$huc),
            ifelse(is.na(r$nfeat), "?", r$nfeat), r$expected
        ))
        for (fl in r$flags) {
            w("    - ", fl)
        }
    }
    w("")
}

if (length(mismatched) > 0) {
    w(rule)
    w("RASTER MISMATCHES (", length(mismatched), " file(s))")
    w(rule)
    w("MISSING = vector says this patch should exist but no .tif is on disk")
    w("STALE   = .tif on disk with no corresponding kept PatchGroup")
    for (r in mismatched) {
        w("")
        w(r$file)
        w(sprintf("    expected %d | on disk %d", r$expected, r$actual))
        if (length(r$missing) > 0) {
            w("    MISSING (", length(r$missing), "): patch ",
                paste(r$missing, collapse = ", "))
        }
        if (length(r$orphan) > 0) {
            w("    STALE   (", length(r$orphan), "): patch ",
                paste(r$orphan, collapse = ", "))
        }
    }
    w("")
}

if (checkRasters && length(bad_dims) > 0) {
    w(rule)
    w("RASTERS WITH WRONG DIMENSIONS (", length(bad_dims), ")")
    w(rule)
    for (b in bad_dims) w("    ", b)
    w("")
}

w(rule)
w("PER-FILE DETAIL (all ", tot_files, " files)")
w(rule)
w(sprintf("%-62s %8s %8s", "file", "expected", "on_disk"))
for (r in rows[order(vapply(rows, function(z) z$file, character(1)))]) {
    w(sprintf("%-62s %8d %8d", substr(r$file, 1, 62), r$expected, r$actual))
}
close(con)

cat(readLines(reportPath), sep = "\n")
cat("\n\nReport written to: ", reportPath, "\n", sep = "")
