#!/usr/bin/env Rscript

### Clean up DL predicted rasters
###   Rasters have classified pixels outside of the HUC12 watershed area
###   Could also implement modal filter to remove artifacts

##########################################################################################

library(terra)
library(sf)
library(dplyr)
library(stringr)
library(future)
library(future.apply)

##########################################################################################

args <- c(
  "Data/HUC_DL_Predictions/", 
  "TRUE", 
  "Data/HUC_DL_Predictions/HUC_DL_Predictions_Clean/" 
)

args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

inputPath <- args[1]
onlyClass <- as.logical(args[2])
outputPath <- args[3]

message("these are the arguments: \n", 
        "1) path for DL prediction rasters: ", inputPath, " \n",
        "2) Class only not probabilities: ", onlyClass, " \n",
        "3) output path for saving: ", outputPath, " \n"
)


setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
##########################################################################################

list_of_predicted <- list.files(inputPath, full.names = TRUE, pattern = ".tif")

if(onlyClass){
  message("Filter for class rasters")
  list_of_predicted <- list_of_predicted[!grepl(x = list_of_predicted, pattern = "probs")]
}


crop_export_smooth <- function(rast_fn){
  terraOptions(memfrac = 0.8, memmax = 36, tempdir = "Data/tmp")
  message("Processing file: ", rast_fn)
  
  output_fn <- basename(rast_fn) |> str_remove(".tif") |> str_replace("\\.", "_") |> paste0("_huc_crop.tif")
  
  huc_num <- str_extract(rast_fn, "(?<=huc_)\\d+(?=_)")
  
  huc_poly <- sf::st_read("Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg", quiet = TRUE,
                                query = paste0("SELECT * FROM NY_Cluster_Zones_250_CROP_NAomit_6347 WHERE huc12 = '", huc_num, "'"))
  
  pred_rast <- rast(rast_fn)
  pred_rast_crop <- terra::crop(pred_rast, huc_poly, mask = TRUE, touches = TRUE)
  # pred_rast_crop_mode <- terra::focal(pred_rast_crop, w = 5, fun="modal", na.rm = TRUE, na.policy = "omit")
  # pred_rast_crop_mode_crop <- terra::crop(pred_rast_crop_mode, huc_poly, mask = TRUE, touches = TRUE)
  
  system.time({
    writeRaster(pred_rast_crop,
                filename = paste0(outputPath, output_fn),
                overwrite = TRUE)
  })
  
  gc()
}

### Parallel 

slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
  corenum <- as.integer(slurm_cpus)
} else {
  corenum <- min(future::availableCores(), 3)
}

print(corenum)
options(future.globals.maxSize= 36.0 * 1e9)
# plan(multisession, workers = corenum)
plan(future.callr::callr, workers = corenum)

future_lapply(list_of_predicted, crop_export_smooth,
              future.seed = TRUE,
              future.packages = c("terra", "sf", "dplyr", "stringr"),
              future.globals = TRUE
)

gc()

### Sequential

# lapply(list_of_predicted[1:3], crop_export_smooth)
# 
# gc()
