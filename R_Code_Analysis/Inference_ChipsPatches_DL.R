### Vector chips/patches from DL INFERENCE rasters
# Raster counterpart of Vector_ChipsPatches_DL.R: instead of placing 256 m
# squares over wetland POLYGONS (NWI / Info / ADK ...), it places them over the
# wetland CELLS of a multiclass DL prediction raster
#   (NYS_Wetlands_DL/Data/HUC_DL_Predictions_v3_masked/DLpred_multiclass_*.tif,
#    Byte, 0 = EMW, 1 = FSW, 2 = SSW, 3 = UPL, 255 = outside the HUC12)
# and polygonizes the predicted classes inside each square. The output gpkg has
# exactly the attribute schema of R_Patches_Vector_Prod/ (ReviewerName,
# Confidence, BoundariesAltered, Comments, MOD_CLASS, PatchGroup) so it can be
# GIS-reviewed in QGIS and then go through Raster_ChipsPatches_DL.R unchanged.
#
# Contract with patch_groups.R (what the rasterizer will accept):
#   - every PatchGroup is ONE 256 x 256 m square, aligned to the 1 m DEM grid
#     (the prediction raster IS on the DEM grid), entirely inside the HUC;
#   - the wetland + UPL polygons of a group partition the square exactly
#     (UPL = square minus wetlands), so summed area == side^2.
#
# Sampling (per HUC raster):
#   1. one streamed pass: per-class cell counts on a 32 m grid;
#   2. an 8x8 focal sum turns that into the class composition of every
#      256 m square whose corner sits on the 32 m grid;
#   3. squares not 100% inside the HUC are dropped; a square is a candidate
#      for class k when k covers >= minClassFrac of it;
#   4. classes take turns (rarest first) picking a candidate -- weighted random
#      by that class's cover -- that doesn't overlap any square already kept,
#      until maxPatches squares are kept. This balances EMW/FSW/SSW instead of
#      letting the abundant class fill the quota.
#
# Usage:
#   Rscript R_Code_Analysis/Inference_ChipsPatches_DL.R \
#       <predDir> <patchRadius> <maxPatches> <clusters> [overwrite] [outDir] [polyRes]
#   clusters: "all" or comma-separated cluster numbers (e.g. "11,102")

suppressPackageStartupMessages({
    library(terra)
    library(sf)
    library(dplyr)
    library(stringr)
    library(future)
    library(future.apply)
})

########################################################################################
args <- c(
    "../NYS_Wetlands_DL/Data/HUC_DL_Predictions_v3_masked/", # prediction rasters
    128, # patch size radius (m) -> 256 m squares
    25, # max patches per HUC
    "11", # clusters: "all" or comma list
    "FALSE", # overwrite existing gpkg
    "Data/Training_Data/R_Patches_Vector_Inference/" # output folder
)

args <- commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

predDir <- args[1]
patchSize <- as.numeric(args[2])
maxPatches <- as.integer(args[3])
clusterSubset <- if (length(args) >= 4 && nzchar(args[4])) args[4] else "all"
overwrite <- length(args) >= 5 && toupper(args[5]) %in% c("1", "TRUE", "YES")
outDir <- if (length(args) >= 6 && nzchar(args[6])) {
    args[6]
} else {
    "Data/Training_Data/R_Patches_Vector_Inference/"
}

## Tunables
coarseRes <- 32 # m; 256 / 32 = 8 coarse cells per square side
minClassFrac <- 0.05 # class must cover >= 5% (3,277 m2) of a square to seed it
minMappingUnit <- 25 # m2; predicted clumps smaller than this join their neighbour
# polygonizing resolution in pixels (1 = native 1 m). 2 = 2 m modal: half the
# boundary vertices, coarser edges. Optional 7th arg.
polyRes <- if (length(args) >= 7 && nzchar(args[7])) as.integer(args[7]) else 1L
sourceTag <- "DLv3" # filename prefix -> Raster_ChipsPatches_DL.R source tag

fct_df <- data.frame(ID = 0:3, MOD_CLASS = c("EMW", "FSW", "SSW", "UPL"))
wet_ids <- 0:2

cat(
    "these are the arguments:\n",
    "1) prediction folder:", predDir, "\n",
    "2) patch radius:", patchSize, "\n",
    "3) max patches per HUC:", maxPatches, "\n",
    "4) clusters:", clusterSubset, "\n",
    "5) overwrite:", overwrite, "\n",
    "6) output folder:", outDir, "\n",
    "7) polygonizing resolution (pixels):", polyRes, "\n"
)
stopifnot(polyRes >= 1, (patchSize * 2) %% polyRes == 0)

boxSide <- patchSize * 2
stopifnot(boxSide %% coarseRes == 0)
nCoarse <- boxSide / coarseRes

setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
dir.create(outDir, showWarnings = FALSE, recursive = TRUE)

########################################################################################
l_pred <- list.files(
    predDir,
    pattern = "^DLpred_multiclass_cluster_\\d+_huc_\\d+\\.tif$",
    full.names = TRUE
)
if (clusterSubset != "all") {
    cl <- trimws(strsplit(clusterSubset, ",")[[1]])
    l_pred <- l_pred[
        str_extract(basename(l_pred), "(?<=cluster_)\\d+") %in% cl
    ]
}
message(length(l_pred), " multiclass prediction raster(s) to process")
if (length(l_pred) == 0) quit(save = "no")

########################################################################################
# Greedy round-robin pick of non-overlapping squares, rarest class first.
# cand: data.frame(x, y, f0, f1, f2) of square centers + class fractions.
pick_boxes <- function(cand, side, n_max) {
    fcols <- paste0("f", wet_ids)
    # Weighted random order per class (Efraimidis-Spirakis keys u^(1/w)).
    queues <- lapply(fcols, function(fc) {
        idx <- which(cand[[fc]] >= minClassFrac)
        if (length(idx) == 0) return(integer(0))
        key <- runif(length(idx))^(1 / cand[[fc]][idx])
        idx[order(key, decreasing = TRUE)]
    })
    names(queues) <- fcols
    queues <- queues[order(lengths(queues))] # rarest class first
    ptr <- setNames(rep(1L, length(queues)), names(queues))
    kx <- numeric(0)
    ky <- numeric(0)
    kept <- integer(0)
    seed_class <- character(0)
    repeat {
        progressed <- FALSE
        for (q in names(queues)) {
            if (length(kept) >= n_max) break
            qq <- queues[[q]]
            while (ptr[q] <= length(qq)) {
                i <- qq[ptr[q]]
                ptr[q] <- ptr[q] + 1L
                if (
                    length(kx) == 0 ||
                        all(pmax(abs(kx - cand$x[i]), abs(ky - cand$y[i])) >= side)
                ) {
                    kept <- c(kept, i)
                    seed_class <- c(seed_class, q)
                    kx <- c(kx, cand$x[i])
                    ky <- c(ky, cand$y[i])
                    progressed <- TRUE
                    break
                }
            }
        }
        if (length(kept) >= n_max || !progressed) break
    }
    data.frame(idx = kept, seed = seed_class)
}

########################################################################################
inference_patch_create <- function(pred_file) {
    huc_num <- str_extract(basename(pred_file), "(?<=huc_)\\d+")
    cluster_num <- str_extract(basename(pred_file), "(?<=cluster_)\\d+")
    fn_out <- file.path(
        outDir,
        paste0(sourceTag, "_cluster_", cluster_num, "_huc_", huc_num, "_", boxSide, "m.gpkg")
    )
    if (file.exists(fn_out) && !overwrite) {
        message("Already file ", fn_out)
        return(invisible(fn_out))
    }

    huc_poly <- sf::st_read(
        "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
        quiet = TRUE,
        query = paste0(
            "SELECT * FROM NY_Cluster_Zones_250_CROP_NAomit_6347 WHERE huc12 = '",
            huc_num, "'"
        )
    )
    if (nrow(huc_poly) == 0) {
        message("HUC ", huc_num, " not in cluster gpkg, skipping")
        return(invisible(NULL))
    }
    huc_geom <- st_union(huc_poly)
    # per-HUC seed: a HUC gets the same squares whichever clusters share the run
    set.seed(as.numeric(huc_num) %% .Machine$integer.max)

    r <- rast(pred_file)
    if (abs(res(r)[1] - 1) > 1e-6) stop("expected a 1 m raster: ", pred_file)
    fact <- round(coarseRes / res(r)[1])

    ## 1. per-class cell counts on the coarse grid (one streamed pass)
    cnt <- aggregate(
        segregate(r, classes = 0:3, other = 0),
        fact = fact,
        fun = "sum",
        na.rm = TRUE
    )
    cnt <- subst(cnt, NA, 0)

    ## 2. composition of every 8x8 coarse-cell square. A 9x9 window with the
    ## last row/col zeroed sums cells (i-4..i+3, j-4..j+3): the square whose
    ## centre is the top-left corner of coarse cell (i, j). Squares that run off
    ## the raster get NA (fillvalue) and are dropped.
    w <- matrix(0, nCoarse + 1, nCoarse + 1)
    w[1:nCoarse, 1:nCoarse] <- 1
    box_cnt <- focal(cnt, w = w, fun = "sum", na.rm = FALSE, fillvalue = NA)
    df <- as.data.frame(box_cnt, xy = TRUE, na.rm = TRUE)
    names(df) <- c("x", "y", paste0("f", 0:3))
    ncell_box <- (boxSide / res(r)[1])^2
    valid <- rowSums(df[, paste0("f", 0:3)]) / ncell_box
    df <- df[valid >= 1 - 1e-9, ] # fully inside the HUC mask
    df[, paste0("f", 0:3)] <- df[, paste0("f", 0:3)] / ncell_box
    # cell centre -> top-left corner of that coarse cell = square centre
    df$x <- df$x - coarseRes / 2
    df$y <- df$y + coarseRes / 2

    ## 3-4. balanced non-overlapping pick
    picks <- pick_boxes(df, boxSide, maxPatches)
    if (nrow(picks) == 0) {
        message(basename(pred_file), ": no square with >= ", minClassFrac,
                " wetland cover fully inside the HUC")
        return(invisible(NULL))
    }
    sel <- df[picks$idx, ]
    boxes <- st_as_sf(sel, coords = c("x", "y"), crs = crs(r)) |>
        st_buffer(dist = patchSize, endCapStyle = "SQUARE")
    # guard: polygon containment (the cell mask is ~0.5 m coarser than the polygon)
    inside <- lengths(st_within(boxes, huc_geom)) > 0
    boxes <- boxes[inside, ]
    sel <- sel[inside, ]
    picks <- picks[inside, ]
    boxes$PatchGroup <- seq_len(nrow(boxes))

    ## 5. polygonize each square -- in RASTER space only, so the classes tile
    ## the square exactly along pixel edges. (An earlier version simplified
    ## the wetland polygons and built UPL as square minus wetlands; the
    ## simplification opened gaps/overlaps between neighbouring classes and
    ## left ~40k sub-25 m2 slivers, mostly 0.1-1 m2 UPL, across 749 squares.)
    ## The box sits on the 1 m pixel grid (see step 2), so the crop is exactly
    ## boxSide x boxSide pixels and no vector clipping is needed.
    patch_list <- lapply(seq_len(nrow(boxes)), function(i) {
        box <- boxes[i, ]
        rc <- crop(r, ext(vect(box)), snap = "near")
        if (polyRes > 1) {
            rc <- aggregate(rc, fact = polyRes, fun = "modal", na.rm = TRUE)
        }
        # 4-connected, matching GDAL polygonize: every resulting polygon part is
        # then >= minMappingUnit (an 8-connected clump can split into smaller
        # diagonal-only parts once polygonized)
        rc <- sieve(rc, threshold = ceiling(minMappingUnit / polyRes^2),
                    directions = 4)
        pv <- as.polygons(rc, dissolve = TRUE)
        names(pv) <- "ID"
        out <- st_as_sf(pv) |>
            left_join(fct_df, by = "ID") |>
            dplyr::select(MOD_CLASS)
        st_geometry(out) <- "geom"
        out$PatchGroup <- box$PatchGroup
        out
    })

    cmb <- bind_rows(patch_list) |>
        mutate(
            ReviewerName = "TBD",
            Confidence = -999,
            BoundariesAltered = NA,
            Comments = "NoComment"
        ) |>
        st_cast("MULTIPOLYGON") |> # dissolve=TRUE: already one row per class
        dplyr::select(ReviewerName, Confidence, BoundariesAltered, Comments,
                      MOD_CLASS, PatchGroup) |>
        arrange(PatchGroup, MOD_CLASS)
    st_geometry(cmb) <- "geom"
    cmb$PatchGroup <- as.integer(cmb$PatchGroup)

    ## sanity: each group partitions its square
    ga <- tapply(as.numeric(st_area(cmb)), cmb$PatchGroup, sum)
    bad <- names(ga)[abs(ga - boxSide^2) > 0.002 * boxSide^2]
    if (length(bad) > 0) {
        warning(basename(pred_file), ": PatchGroup(s) not partitioning the square: ",
                paste(bad, collapse = ","))
    }

    st_write(cmb, dsn = fn_out, append = FALSE, quiet = TRUE)

    seed_tab <- table(factor(picks$seed, levels = paste0("f", wet_ids),
                             labels = fct_df$MOD_CLASS[wet_ids + 1]))
    message(
        basename(pred_file), ": candidate squares inside HUC = ", nrow(df),
        "; kept = ", nrow(boxes),
        " (seeded by ", paste(names(seed_tab), seed_tab, sep = "=", collapse = " "),
        "); mean cover EMW/FSW/SSW/UPL = ",
        paste(sprintf("%.2f", colMeans(sel[, paste0("f", 0:3)])), collapse = "/"),
        " -> ", basename(fn_out)
    )
    invisible(fn_out)
}

########################################################################################
### Parallel over HUC rasters
slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")
corenum <- if (nzchar(slurm_cpus)) {
    as.integer(slurm_cpus)
} else {
    min(future::availableCores(), 4)
}
corenum <- max(1L, min(corenum, length(l_pred)))
task_mem_mb <- as.numeric(Sys.getenv("TASK_MEM_MB", unset = "16000"))
worker_mem_gb <- task_mem_mb / 1024 / corenum
message("workers = ", corenum, "; terra memmax per worker = ",
        round(worker_mem_gb * 0.6, 1), " GB")

options(future.globals.maxSize = 4e9)
if (corenum > 1) plan(future.callr::callr, workers = corenum) else plan(sequential)

set.seed(420)
res_files <- future_lapply(
    l_pred,
    function(f) {
        terra::terraOptions(memmax = worker_mem_gb * 0.6, progress = 0)
        tryCatch(
            inference_patch_create(f),
            error = function(e) {
                message("FAILED ", basename(f), ": ", conditionMessage(e))
                NULL
            }
        )
    },
    future.seed = TRUE,
    future.packages = c("terra", "sf", "dplyr", "stringr")
)
message("Done: ", sum(!vapply(res_files, is.null, logical(1))), "/", length(l_pred),
        " HUC(s) written to ", outDir)
