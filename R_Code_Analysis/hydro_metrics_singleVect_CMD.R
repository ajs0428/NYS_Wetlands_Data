#!/usr/bin/env Rscript

###################
# This script creates a "hydro-conditioned" DTM for hydrologic modeling
    # The new DTMs are named with 'wbt' for hydro processing
# It also creates the hydrologic metrics for Topographic Wetness Index
###################

args = c("Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
         22,
         "Data/TerrainProcessed/HUC_DEMs/",
         "Data/TerrainProcessed/HUC_Hydro/"
         )

args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here


clusterFile <- args[1]
clusterNumber <- args[2]
demFolder <- args[3]
hydroFolder <- args[4]

cat("these are the arguments: \n", 
    "- Path to a file vector study area", clusterFile, "\n",
    "- Cluster number (integer 1-200ish):", clusterNumber, "\n",
    "- Path to the DEMs in TerrainProcessed folder", demFolder, "\n",
    "- Path to save folder:", hydroFolder, "\n"
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

# SLURM allocates 64 GB / 1 core per task — no in-script parallelism.
terraOptions(tempdir = "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp",
             memmax = 56)
print(tempdir())

###############################################################################################
# All the DEMs in a cluster
list_of_huc_dems <- list.files(demFolder, 
                               paste0("cluster_", clusterNumber, "_huc"),
                               full.names = TRUE
                               )
print(list_of_huc_dems)
list_of_huc_hydro_dems <- list.files("Data/TerrainProcessed/HUC_DEM_Hydro/", 
                               full.names = TRUE, 
                               paste0("cluster_", clusterNumber, "_huc"))
print(list_of_huc_hydro_dems)
dem_hucs <- str_extract(list_of_huc_dems, "(?<=huc_)\\d+")
wbt_dem_hucs <- str_extract(list_of_huc_hydro_dems, "(?<=huc_)\\d+")

# All the non-hydro-conditioned DEMs
non_wbt_list <- list_of_huc_dems[!dem_hucs %in% wbt_dem_hucs]

#HUCs that haven't been hydroconditioned
print(non_wbt_list) 


###############################################################################################

hydro_func <- function(huc_num){
    
    dem_fn <- list_of_huc_dems[grepl(huc_num, list_of_huc_dems)]
    dem_fn_abs <- paste0("/ibstorage/anthony/NYS_Wetlands_Data/", dem_fn)
    hc_fn <- paste0("Data/TerrainProcessed/HUC_DEM_Hydro/cluster_", clusterNumber, "_huc_", huc_num, "_wbt.tif")
    hc_fn_abs <- paste0("/ibstorage/anthony/NYS_Wetlands_Data/", hc_fn)
    
    if(!file.exists(hc_fn_abs)){
        message("Hydro-Conditioning for ", hc_fn_abs)
        wbt_fill_depressions(
            dem = dem_fn_abs, 
            output = hc_fn_abs, 
            # dist = 500,
            # min_dist = 100,
            # max_cost = 500, 
            # flat_increment = 0.5
        )
    } 
    
    fa_twi_name <- paste0(hydroFolder, tools::file_path_sans_ext(basename(hc_fn)), "_TWI_Facc.tif")

    if(!file.exists(fa_twi_name) & file.exists(hc_fn)){
        message("New TWI and Flow Acc for ", fa_twi_name)
        dem_rast <- rast(hc_fn)
        fs <- dem_rast |>
            # terra::project("EPSG:6347", res = 1) |>
            terra::terrain(v = c("flowdir", "slope"), unit = "radians")
        fa <- terra::flowAccumulation(fs["flowdir"])

        twi <- log(fa/tan(fs["slope"]))
        twi[is.infinite(twi)] <- NA
        writeRaster(c(fa, twi), fa_twi_name,
                    overwrite = TRUE, names = c("flowacc", "twi"))
    } else {
        message("TWI and Flow Accum. already made: ", fa_twi_name)
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
