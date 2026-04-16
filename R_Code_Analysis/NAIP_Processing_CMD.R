#!/usr/bin/env Rscript

args = c(
    "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
    95,
    "Data/NAIP/HUC_NAIP_Processed/"
)
args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

clusterPath <- args[1]
clusterSubset <- args[2]
outputPath <- args[3]

message("these are the arguments: \n", 
     "- Path to cluster:", clusterPath, "\n",
     "- Cluster:", clusterSubset, "\n",
     "- Path to NAIP Processed:", outputPath, "\n"
)

###############################################################################################

library(terra)
library(sf)
suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(tidyterra))
library(future)
library(future.apply)

terraOptions(tempdir = "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp")
print(tempdir())
setGDALconfig("GDAL_PAM_ENABLED", "FALSE") # does not create aux.xml files
###############################################################################################

#Index of all NAIP tiles
naip_index <- st_read("Data/NAIP/noaa_digital_coast_2017/tileindex_NY_NAIP_2017.shp", quiet = TRUE) |> 
    st_transform(st_crs("EPSG:6347"))

#Cluster of HUCs
cluster_target <- sf::st_read(clusterPath, quiet = TRUE) |> 
    dplyr::filter(cluster == clusterSubset) 
cluster_crs <- st_crs(cluster_target)
cluster_hucs <- cluster_target[["huc12"]]

#Filter for NAIP tiles in Cluster
naip_int_cluster <- st_filter(naip_index, cluster_target, .predicate = st_intersects)
# plot(naip_int_cluster)


###############################################################################################

# This should take a list of all the NAIP rasters, merge them together in a HUC,
# crop to HUC boundaris, calculate indices, export and write to file

vi2 <- function(r, g, nir) {
    return(
        c(((nir - r) / (nir + r)), ((g-nir)/(g+nir)))
    )
}

process_huc <- function(huc_num) {
    setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
    target_file <- paste0(outputPath, "cluster_", clusterSubset, "_huc_", huc_num, "_NAIP_metrics.tif")
    dem_filename <- paste0("Data/TerrainProcessed/HUC_DEMs", "/cluster_", clusterSubset, "_huc_", huc_num, ".tif")
    huc <- cluster_target[cluster_target$huc12 == huc_num, ]
    # uncomment the if statement with file.exists to ignore files already created
    if(!file.exists(target_file)){
        message("no NAIP processed yet for: ", target_file)
        naip_tiles_huc <- st_filter(naip_int_cluster, huc)
        huc_vect <- vect(huc)
        #re-paste the file path to rasters
        naip_int_cluster_rast_locs <- paste0("Data/NAIP/noaa_digital_coast_2017/", naip_tiles_huc$location)
        
        n <- terra::sprc(naip_int_cluster_rast_locs) |>
            terra::mosaic(fun = "max") |>
            terra::project("EPSG:6347", res = 1) |>
            terra::crop(huc_vect, mask = TRUE) |>
            terra::resample(y = rast(dem_filename))
        np <- vi2(n[[1]], n[[2]], n[[4]])
        nall <- c(n, np)
        set.names(nall, c("r", "g", "b", "nir", "ndvi", "ndwi"))
        
        writeRaster(nall,
                    filename = target_file,
                    overwrite = TRUE)
        rm(n)
        rm(np)
        rm(nall)
        gc()
    } else {
        message("NAIP already processed for: ", target_file)
    }
    
    return(NULL)  
}

slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
  corenum <- as.integer(slurm_cpus)
} else {
  corenum <- min(future::availableCores(), 4)
}
options(future.globals.maxSize= 64 * 1e9)
# plan(multisession, workers = corenum)
plan(future.callr::callr, workers = corenum)

# Run with future_lapply
future_lapply(
    cluster_hucs,
    FUN = process_huc,
    future.packages = c("terra", "sf", "dplyr"),
    future.seed = TRUE, 
    future.globals = TRUE
    # future.globals = list(
    #     args = args,
    #     cluster_target = cluster_target,
    #     cluster_crs = cluster_crs,
    #     naip_int_cluster = naip_int_cluster,
    #     vi2 = vi2
    # )
)

gc()

# lapply(cluster_hucs, FUN = process_huc)