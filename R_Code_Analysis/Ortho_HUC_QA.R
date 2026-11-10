#!/usr/bin/env Rscript

###################
# QA for the per-HUC12 leaf-off ortho rasters (Ortho_HUC_Processing.R output).
#
# Bounding-box NA counts are meaningless here (the raster is the HUC bbox, the
# HUC is not), so every metric is computed only over cells whose centre falls
# INSIDE the HUC12 polygon (unioned across gpkg rows). Per HUC it reports:
#   expected_cells  polygon area / cell area
#   inside_cells    polygon cells that land on the raster grid
#   frac_outside    1 - inside/expected  (polygon not covered by raster extent,
#                   e.g. a DEM that is cut short of the HUC)
#   frac_na         any band NA                 (missing imagery)
#   frac_zero       all 4 bands == 0            (leftover tile collar / nodata)
#   frac_dark       max band <= 5, not zero     (near-black: shadow, deep water, or bad tile)
#   frac_sat        min band >= 250             (saturated / white)
#   frac_bad        na + zero + outside         (definitely no usable imagery)
#   max_block_bad   worst 100 m block's bad fraction (localized holes)
#   n_blocks_bad50  # of 100 m blocks inside the HUC that are >50 % bad
#   band means/sds  within the polygon
#   years           ortho_years metadata tag
# Also writes a 100 m "bad fraction" raster per HUC to <qaDir>/blocks/ so
# problem areas can be viewed in GIS (gdalbuildvrt them for a statewide view).
#
# Usage: Rscript Ortho_HUC_QA.R <gpkg> <orthoDir> <qaDir> <taskIndex> <nTasks>
#   Files are split round-robin across nTasks; each task writes
#   <qaDir>/parts/ortho_qa_<taskIndex>.csv. Combine afterwards.
###################

args <- c(
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
    "Data/Ortho/HUC_Ortho",
    "Data/Ortho/QA",
    1, 1
)
args <- commandArgs(trailingOnly = TRUE)

gpkg     <- args[1]
orthoDir <- args[2]
qaDir    <- args[3]
taskIdx  <- as.integer(args[4])
nTasks   <- as.integer(args[5])

suppressPackageStartupMessages({
    library(terra)
    library(sf)
})
setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
.task_mem_gb <- as.numeric(Sys.getenv("TASK_MEM_MB", "0")) / 1024
# Private temp dir per task: with a shared dir, tmpFiles(remove=TRUE) in one task
# deleted the in-flight temp rasters of the other 31 ("file does not exist").
.tmp_dir <- file.path("/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp",
                      sprintf("ortho_qa_task%03d_%s", taskIdx, Sys.getenv("SLURM_ARRAY_JOB_ID", Sys.getenv("SLURM_JOB_ID", "local"))))
dir.create(.tmp_dir, recursive = TRUE, showWarnings = FALSE)
terraOptions(tempdir = .tmp_dir,
             memmax = if (.task_mem_gb > 0) max(2, floor(.task_mem_gb * 0.4)) else 8,
             progress = 0)

dir.create(file.path(qaDir, "parts"),  recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(qaDir, "blocks"), recursive = TRUE, showWarnings = FALSE)

hucs <- st_read(gpkg, quiet = TRUE) |> st_transform(6347)

# Only the preferred-year outputs (a stale _ortho_2023 test file exists).
files <- sort(list.files(orthoDir, pattern = "_huc_\\d+_ortho_2024\\.tif$", full.names = TRUE))
files <- files[seq_along(files) %% nTasks == (taskIdx - 1) %% nTasks]

out_csv <- file.path(qaDir, "parts", sprintf("ortho_qa_n%02d_%03d.csv", nTasks, taskIdx))
# Resume across ALL part CSVs (not just this task's) so nTasks can change between runs.
done <- unlist(lapply(list.files(file.path(qaDir, "parts"), "^ortho_qa_.*\\d\\.csv$", full.names = TRUE),
                      function(p) read.csv(p)$file))
message("Task ", taskIdx, "/", nTasks, ": ", length(files), " files (", sum(basename(files) %in% done), " already done)")

# Per-cell class, vectorised over a chunk: NA outside polygon,
# 0 ok, 1 NA, 2 all-zero, 3 near-black, 4 saturated.
classify <- function(r, g, b, n, p) {
    out <- integer(length(r))
    mx <- pmax(r, g, b, n); mn <- pmin(r, g, b, n)
    out[!is.na(mx) & mx <= 5]   <- 3L
    out[!is.na(mx) & mx == 0]   <- 2L
    out[!is.na(mn) & mn >= 250] <- 4L
    out[is.na(mx)]              <- 1L
    out[is.na(p)]               <- NA_integer_
    out
}

qa_one <- function(f) {
    t0 <- Sys.time()
    cl  <- as.integer(sub(".*cluster_(\\d+)_huc_.*", "\\1", basename(f)))
    huc <- sub(".*_huc_(\\d+)_ortho.*", "\\1", basename(f))
    poly <- hucs[hucs$huc12 == huc, ]
    if (nrow(poly) == 0) return(data.frame(file = basename(f), cluster = cl, huc12 = huc,
                                           note = "HUC not in gpkg"))
    poly <- st_union(st_make_valid(poly))
    v <- vect(poly)

    r <- rast(f)
    cell_area <- prod(res(r))
    expected  <- as.numeric(st_area(poly)) / cell_area
    pm <- rasterize(v, r[[1]], field = 1, touches = FALSE)

    cls <- lapp(c(r, pm), fun = classify)
    fr  <- freq(cls)
    cnt <- setNames(rep(0, 5), 0:4)
    cnt[as.character(fr$value)] <- fr$count
    inside <- sum(cnt)

    # 100 m bad-fraction blocks (NA / zero only; dark & sat are informational)
    bad  <- cls == 1 | cls == 2
    blk  <- aggregate(bad, fact = 100, fun = "mean", na.rm = TRUE)
    blkf <- file.path(qaDir, "blocks", sub("\\.tif$", "_badfrac100m.tif", basename(f)))
    writeRaster(blk, blkf, overwrite = TRUE, datatype = "FLT4S")
    bv <- values(blk, mat = FALSE); bv <- bv[!is.na(bv)]

    st <- global(mask(r, pm), c("mean", "sd"), na.rm = TRUE)
    yrs <- metags(r); yrs <- yrs$value[yrs$name == "ortho_years"]

    data.frame(
        file = basename(f), cluster = cl, huc12 = huc,
        years = if (length(yrs)) yrs else NA,
        expected_cells = round(expected), inside_cells = inside,
        frac_outside = max(0, 1 - inside / expected),
        frac_na   = cnt[["1"]] / inside,
        frac_zero = cnt[["2"]] / inside,
        frac_dark = cnt[["3"]] / inside,
        frac_sat  = cnt[["4"]] / inside,
        frac_bad  = (cnt[["1"]] + cnt[["2"]]) / expected + max(0, 1 - inside / expected),
        max_block_bad  = if (length(bv)) max(bv) else NA,
        n_blocks_bad50 = sum(bv > 0.5),
        mean_r = st$mean[1], mean_g = st$mean[2], mean_b = st$mean[3], mean_nir = st$mean[4],
        sd_r = st$sd[1], sd_g = st$sd[2], sd_b = st$sd[3], sd_nir = st$sd[4],
        secs = round(as.numeric(difftime(Sys.time(), t0, units = "secs"))),
        note = ""
    )
}

for (f in setdiff(files, file.path(orthoDir, done))) {
    res <- tryCatch(qa_one(f), error = function(e)
        data.frame(file = basename(f), note = paste("ERROR:", conditionMessage(e))))
    message(basename(f), "  ", if (!is.null(res$frac_bad)) sprintf("bad=%.4f  %ss", res$frac_bad, res$secs) else res$note)
    if (is.null(res$frac_bad)) {   # error / not-in-gpkg rows go to a side log
        cat(basename(f), res$note, "\n", file = sub("\\.csv$", "_errors.txt", out_csv), append = TRUE)
    } else {
        write.table(res, out_csv, sep = ",", row.names = FALSE,
                    col.names = !file.exists(out_csv), append = file.exists(out_csv))
    }
    unlink(list.files(.tmp_dir, full.names = TRUE, recursive = TRUE))
    gc(verbose = FALSE)
}
unlink(.tmp_dir, recursive = TRUE)
message("Task ", taskIdx, " done")
