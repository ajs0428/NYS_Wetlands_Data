#!/usr/bin/env Rscript

### Extract Preliminary Wetland Maps with NYPAD for Field Work
###   

##########################################################################################

library(terra)
library(sf)
library(dplyr)
library(stringr)
library(future)
library(future.apply)


##########################################################################################

# args <- c(
#   "Data/HUC_DL_Predictions/", 
#   "TRUE", 
#   "Data/HUC_DL_Predictions/HUC_DL_Predictions_Clean/" 
# )
# 
# args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here
# 
# inputPath <- args[1]
# onlyClass <- as.logical(args[2])
# outputPath <- args[3]
# 
# message("these are the arguments: \n", 
#         "1) path for DL prediction rasters: ", inputPath, " \n",
#         "2) Class only not probabilities: ", onlyClass, " \n",
#         "3) output path for saving: ", outputPath, " \n"
# )
# 
# 
# setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
##########################################################################################

list_of_predicted_clean <- list.files("Data/HUC_DL_Predictions/HUC_DL_Predictions_Clean/", full.names = TRUE, pattern = ".tif")

cls <- st_read("Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.shp")
# Batch 1
cls_nums <- c(11, 22, 46, 50, 64, 67, 82, 95, 123, 168, 208, 218, 225, 250)
cls_filter <- cls |> filter(cluster %in% cls_nums)

nypad <- st_read("Data/NYPAD/NYPAD.gdb/", layer = "NYPAD", quiet = TRUE) |> 
  st_transform(st_crs(cls))
nypad_in_cls_mat <- st_intersects(nypad, cls_filter, sparse = FALSE)
nypad_inter_cls <- nypad[rowSums(nypad_in_cls_mat) > 0, ]

crop_nypad <- function(dl_pred_fn){
  huc_num <- str_extract(dl_pred_fn, "(?<=huc_)\\d+")
  cluster_num <- str_extract(dl_pred_fn, "(?<=cluster_)\\d+")
  if(str_detect(dl_pred_fn, "binary")){
    bin_or_multi <- "binary"
  } else {
    bin_or_multi <- "multiclass"
  }
  
  output_fn <- paste0("Data/NYPAD/NYPAD_Preliminary_Rasters/DLpred_NYPAD_cluster_", 
                      cluster_num, "_huc_", huc_num, "_", bin_or_multi, ".tif")
  
  r_dl <- rast(dl_pred_fn)
  # nypad_crs <- st_crs(st_read("Data/NYPAD/NYPAD.gdb/", quiet = TRUE, layer = "NYPAD", query = "SELECT * FROM NYPAD LIMIT 0"))
  # e_dl <- ext(r_dl) |> vect(crs = crs(r_dl)) |> st_as_sf() |> st_transform(nypad_crs)
  # wkt <- st_as_text(st_as_sfc(st_bbox(e_dl)))
  # nypad <- st_read("Data/NYPAD/NYPAD.gdb/", layer = "NYPAD", wkt_filter = wkt, quiet = TRUE) |> 
    # st_transform("EPSG:6347") |> 
  nypad_inter_cls_vect <- nypad_inter_cls |> 
    vect() 
  crop(r_dl, nypad_inter_cls_vect, mask = TRUE, filename = output_fn, overwrite = TRUE)
}

lapply(list_of_predicted_clean, crop_nypad)


