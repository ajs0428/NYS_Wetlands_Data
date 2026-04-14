#!/usr/bin/env Rscript

###################
# This script creates a "hydro-conditioned" DTM for hydrologic modeling
    # The new DTMs are named with 'wbt' for hydro processing
# It also creates the hydrologic metrics for Topographic Wetness Index
###################

args = c("Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
         50,
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
library(future)
library(future.apply)
library(stringr)
# library(flowdem)
library(whitebox)
suppressPackageStartupMessages(library(tidyterra))

terraOptions(tempdir = "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp")
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
    hc_fn <- paste0("Data/TerrainProcessed/HUC_DEM_Hydro/cluster_", clusterNumber, "_huc_", huc_num, "_wbt.tif")
    
    if(!file.exists(hc_fn)){
        message("Hydro-Conditioning for ", hc_fn)
        wbt_fill_depressions(
            dem = dem_fn, 
            output = hc_fn, 
            # dist = 500,
            # min_dist = 100,
            # max_cost = 500, 
            # flat_increment = 0.5
        )
        # r <- rast(dem)
        # rb <- flowdem::breach(r)
        # rbf <- flowdem::fill(rb, epsilon = TRUE)
        # writeRaster(rbf, filename = hc_fn, datatype = "FLT8S", overwrite = TRUE)
        # rm(r)
        # rm(rb)
        # rm(rbf)
        # gc()
    } else {
        message("File exists for ", hc_fn)
    }
    
    fa_twi_name <- paste0(hydroFolder, tools::file_path_sans_ext(basename(hc_fn)), "_TWI_Facc.tif")

    if(!file.exists(fa_twi_name)){
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

### Parallel

slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
  corenum <- as.integer(slurm_cpus)
} else {
  corenum <- min(future::availableCores(), 2)
}

options(future.globals.maxSize= 96 * 1e9)
# plan(multisession, workers = corenum)
plan(future.callr::callr, workers = corenum)

future_lapply(dem_hucs,
              hydro_func,
              future.seed = TRUE,
              future.packages = c("terra", "sf", "dplyr", "tidyr", "stringr", "flowdem"),
              future.globals = TRUE)

# terra::tmpFiles(remove = TRUE)

################################################################################################
# non-parallel
# lapply(dem_hucs, hydro_func)

# r <- rast(list_of_huc_hydro_dems[[1]])
# s <- terra::terrain(r, v = "slope")
# w <- terra::unwrap(cluster_target) |> 
#     tidyterra::filter(huc12 == str_extract(list_of_huc_hydro_dems[[1]], "(?<=huc_)\\d+")) |> 
#     terra::crop(x = vect("Data/Hydrography/NHD_NYS_wb_area.gpkg")) |> 
#     terra::mask(x = s, inverse = TRUE, updatevalue = -999)
# 
# cd <- costDist(w, target = -999, maxiter = 1)
