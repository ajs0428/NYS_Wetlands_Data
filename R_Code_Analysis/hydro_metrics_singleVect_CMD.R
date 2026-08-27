#!/usr/bin/env Rscript

###################
# This script creates a "hydro-conditioned" DTM for hydrologic modeling
# The new DTMs are named with 'wbt' for hydro processing
# It also creates the hydrologic metrics for Topographic Wetness Index
###################

args <- c(
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
    12,
    "Data/TerrainProcessed/HUC_DEMs/",
    "Data/TerrainProcessed/HUC_Hydro/"
)

args <- commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here


clusterFile <- args[1]
clusterNumber <- args[2]
demFolder <- args[3]
hydroFolder <- args[4]

cat(
    "these are the arguments: \n",
    "- Path to a file vector study area",
    clusterFile,
    "\n",
    "- Cluster number (integer 1-200ish):",
    clusterNumber,
    "\n",
    "- Path to the DEMs in TerrainProcessed folder",
    demFolder,
    "\n",
    "- Path to save folder:",
    hydroFolder,
    "\n"
)

###############################################################################################

library(terra)
library(sf)
library(dplyr)
library(tidyr)
library(stringr)
# library(flowdem)
library(whitebox)
suppressPackageStartupMessages(library(tidyterra))

# terra cap derived from the SLURM per-task cgroup so it tracks the SBATCH
# directives, not node RAM. step_hydro.sh unsets SLURM_MEM_PER_CPU before srun,
# so it re-exports the budget as TASK_MEM_MB. This step is single-process (no
# callr workers), so the whole task budget goes to terra, less ~15% headroom.
# NOTE: WhiteboxTools fill/breach runs as an external process that ignores this
# cap entirely — it loads the full DEM itself, so this only governs terra ops
# (flowdir/terrain/flowAccumulation). Falls back to 56 GB off-SLURM.
.task_mem_gb <- as.numeric(Sys.getenv("TASK_MEM_MB", "0")) / 1024
memmax_gb <- if (.task_mem_gb > 0) {
    max(4L, as.integer(floor(.task_mem_gb * 0.85)))
} else {
    56L
}
terraOptions(
    tempdir = "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp",
    memmax = memmax_gb
)
print(tempdir())

###############################################################################################
# All the DEMs in a cluster
list_of_huc_dems <- list.files(
    demFolder,
    paste0("cluster_", clusterNumber, "_huc"),
    full.names = TRUE
)
print(list_of_huc_dems)
list_of_huc_hydro_dems <- list.files(
    "Data/TerrainProcessed/HUC_DEM_Hydro/",
    full.names = TRUE,
    paste0("cluster_", clusterNumber, "_huc")
)
print(list_of_huc_hydro_dems)
dem_hucs <- str_extract(list_of_huc_dems, "(?<=huc_)\\d+")
wbt_dem_hucs <- str_extract(list_of_huc_hydro_dems, "(?<=huc_)\\d+")

# All the non-hydro-conditioned DEMs
non_wbt_list <- list_of_huc_dems[!dem_hucs %in% wbt_dem_hucs]

#HUCs that haven't been hydroconditioned
print(non_wbt_list)


###############################################################################################

hydro_func <- function(huc_num) {
    dem_fn <- list_of_huc_dems[grepl(huc_num, list_of_huc_dems)]
    dem_fn_abs <- paste0("/ibstorage/anthony/NYS_Wetlands_Data/", dem_fn)
    hc_fn <- paste0(
        "Data/TerrainProcessed/HUC_DEM_Hydro/cluster_",
        clusterNumber,
        "_huc_",
        huc_num,
        "_wbt.tif"
    )
    hc_fn_abs <- paste0("/ibstorage/anthony/NYS_Wetlands_Data/", hc_fn)

    if (!file.exists(hc_fn_abs)) {
        # WhiteboxTools' fill/breach panic with "Error unwrapping 'output'" on
        # DEMs whose NoData is NaN -- DEM_Extract writes NaN-nodata GeoTIFFs, and
        # WBT can't condition them (confirmed: the same DEM fills cleanly once the
        # NoData is numeric). Feed WBT a -9999-nodata copy: terra reads NaN as NA
        # and writes it back as -9999. Lazy NAflag check, so DEMs that already
        # have a numeric NoData skip the rewrite. Temp copy lands in TMPDIR (terra
        # tempdir) and is removed when hydro_func returns.
        wbt_in <- dem_fn_abs
        if (is.nan(terra::NAflag(terra::rast(dem_fn_abs)))) {
            wbt_in <- tempfile(fileext = ".tif")
            terra::writeRaster(
                terra::rast(dem_fn_abs),
                wbt_in,
                NAflag = -9999,
                overwrite = TRUE
            )
            on.exit(unlink(wbt_in), add = TRUE)
        }

        message("Hydro-Conditioning (fill) for ", hc_fn_abs)
        # Wang & Liu, NOT wbt_fill_depressions(). WBT's FillDepressions
        # degenerates catastrophically on DEMs containing a very large flat
        # (a lake/river surface at one constant elevation): cluster 12 HUC
        # 043001081402 has 7.6M cells at exactly 28.42 m (7.5% of its valid
        # cells; every other HUC in the cluster is under 0.5%) and
        # FillDepressions ran >16 h at 100% CPU on one core without writing a
        # byte -- with or without fix_flats. FillDepressionsWangAndLiu produced
        # a verified-identical-grid, monotonic (nothing lowered) depressionless
        # DEM for the same file in 106 s, and is multithreaded. Both tools are
        # priority-flood fills and both honour fix_flats, so this is a
        # like-for-like swap; FillDepressions' only extra feature is max_depth,
        # which this pipeline does not use.
        wbt_fill_depressions_wang_and_liu(
            dem = wbt_in,
            output = hc_fn_abs
        )
        # wbt_* returns a status code instead of an R error, so a fill
        # crash (a Rust panic) leaves no output. Fall back to least-cost
        # breaching, which is far more robust on tough DEMs. fill = TRUE still
        # fills any depressions breaching can't carve out, so the result is
        # depressionless either way. dist (max breach channel length, in 1 m
        # cells) is tunable if a HUC needs longer carves.
        if (!file.exists(hc_fn_abs)) {
            warning(
                "FillDepressionsWangAndLiu produced no output for HUC ",
                huc_num,
                " — retrying with BreachDepressionsLeastCost"
            )
            wbt_breach_depressions_least_cost(
                dem = wbt_in,
                output = hc_fn_abs,
                dist = 100,
                fill = TRUE
            )
        }
    }

    fa_twi_name <- paste0(
        hydroFolder,
        tools::file_path_sans_ext(basename(hc_fn)),
        "_TWI_Facc.tif"
    )

    if (!file.exists(fa_twi_name) & file.exists(hc_fn)) {
        message("New TWI and Flow Acc for ", fa_twi_name)
        dem_rast <- rast(hc_fn)
        fs <- dem_rast |>
            # terra::project("EPSG:6347", res = 1) |>
            terra::terrain(v = c("flowdir", "slope"), unit = "radians")
        fa <- terra::flowAccumulation(fs["flowdir"])

        twi <- log(fa / tan(fs["slope"]))
        twi[is.infinite(twi)] <- NA
        writeRaster(
            c(fa, twi),
            fa_twi_name,
            overwrite = TRUE,
            names = c("flowacc", "twi")
        )
    } else if (file.exists(fa_twi_name)) {
        message("TWI and Flow Accum. already made: ", fa_twi_name)
    } else {
        # No conditioned DEM despite trying both fill and breach above. wbt_*
        # returns a status code rather than an R error, so this is the only
        # place the double failure surfaces (otherwise it falls through as a
        # silent skip). Likely a degenerate / near-all-NoData (water) DEM that
        # needs inspection (gdalinfo -stats) rather than another conditioner.
        warning(
            "No hydro-conditioned DEM for HUC ",
            huc_num,
            " (fill AND breach both failed) — TWI/Facc NOT written: ",
            hc_fn
        )
    }
}

lapply(dem_hucs, hydro_func)

gc()
# terra::tmpFiles(remove = TRUE)

# r <- rast(list_of_huc_hydro_dems[[1]])
# s <- terra::terrain(r, v = "slope")
# w <- terra::unwrap(cluster_target) |>
#     tidyterra::filter(huc12 == str_extract(list_of_huc_hydro_dems[[1]], "(?<=huc_)\\d+")) |>
#     terra::crop(x = vect("Data/Hydrography/NHD_NYS_wb_area.gpkg")) |>
#     terra::mask(x = s, inverse = TRUE, updatevalue = -999)
#
# cd <- costDist(w, target = -999, maxiter = 1)
