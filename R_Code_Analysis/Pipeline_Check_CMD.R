#!/usr/bin/env Rscript
# =============================================================================
# Pipeline output check -- report missing per-HUC outputs.
#
#   Usage:  Rscript R_Code_Analysis/Pipeline_Check_CMD.R <gpkg> <clusters_csv>
#   Example: Rscript R_Code_Analysis/Pipeline_Check_CMD.R \
#              "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg" "208,225"
#
# For every HUC12 in the given clusters, checks that each of the seven source
# datasets consumed by huc_stack.R (dem, terr-slp, hydro, chm, naip, ortho,
# lidar) has at least one file in its canonical directory. The check reuses
# huc_source_paths() from huc_stack.R, so what is checked here is BY
# CONSTRUCTION what the DL stacking will look for.
#
# The terrain file is additionally opened and its band names compared against
# terr_expected_bands(); a stale terrain raster (e.g. one written before
# meanc/dmv were folded in, 2026-07) exists on disk and so would otherwise pass
# a presence-only check while silently narrowing the stack. Such HUCs are
# reported as missing "terr-bands". Set CHECK_TERR_BANDS=0 to skip that read.
#
# Exits non-zero when anything is missing, so a SLURM job running this fails
# visibly (mail-type=FAIL / sacct state) instead of burying the gap in a log.
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
    stop("Usage: Rscript Pipeline_Check_CMD.R <gpkg> <clusters_csv>")
}
gpkg_path    <- args[1]
clusters_csv <- args[2]

suppressPackageStartupMessages({
    library(sf)
    library(dplyr)
})
source("R_Code_Analysis/huc_stack.R")   # huc_source_paths(), huc_source_dirs()

clusters <- strsplit(clusters_csv, ",")[[1]] |> trimws()
# distinct(): a huc12 can occupy several gpkg rows (split MULTIPOLYGONs), which
# would otherwise report the same HUC two/three times.
hucs_all <- st_read(gpkg_path, quiet = TRUE) |>
    st_drop_geometry() |>
    filter(cluster %in% clusters) |>
    distinct(cluster, huc12)

message("=== Pipeline output check ===")
message("Clusters: ", paste(clusters, collapse = ", "),
        "  (", nrow(hucs_all), " HUC12s)")
message("Source dirs checked: ",
        paste(names(huc_source_dirs()), collapse = ", "))

check_terr_bands <- !Sys.getenv("CHECK_TERR_BANDS", "1") %in% c("0", "false", "FALSE")
if (check_terr_bands) {
    message("Terrain band contract: ",
            paste(terr_expected_bands(), collapse = ", "))
}

missing_rows <- list()
for (i in seq_len(nrow(hucs_all))) {
    cl  <- hucs_all$cluster[i]
    huc <- hucs_all$huc12[i]
    paths   <- huc_source_paths(huc, cl)
    missing <- names(paths)[lengths(paths) == 0]
    # Terrain present but stale (wrong band set) is as unusable as terrain absent.
    if (check_terr_bands && length(paths$terr) > 0 && !terr_bands_ok(paths$terr[1])) {
        missing <- c(missing, "terr-bands")
    }
    if (length(missing) > 0) {
        missing_rows[[length(missing_rows) + 1]] <- data.frame(
            cluster = cl, huc12 = huc,
            missing = paste(missing, collapse = ","))
    }
}

n_bad <- length(missing_rows)
message("\nComplete HUCs: ", nrow(hucs_all) - n_bad, " / ", nrow(hucs_all))

if (n_bad > 0) {
    report <- do.call(rbind, missing_rows)
    message("\nHUCs with missing sources:")
    for (j in seq_len(nrow(report))) {
        message("  cluster ", report$cluster[j], "  huc ", report$huc12[j],
                "  missing: ", report$missing[j])
    }
    out_csv <- file.path("Shell_Scripts/logs",
                         paste0("pipeline_check_missing_",
                                format(Sys.time(), "%Y%m%d_%H%M%S"), ".csv"))
    write.csv(report, out_csv, row.names = FALSE)
    message("\nReport written to: ", out_csv)
    quit(status = 1)
}

message("All sources present for all HUCs.")
