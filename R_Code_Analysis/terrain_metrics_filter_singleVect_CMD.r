#!/usr/bin/env Rscript

args = c(22,
         "Data/TerrainProcessed/HUC_DEMs/",
         "curv",
         "Data/TerrainProcessed/HUC_TerrainMetrics/"
)
args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

CLUSTER <- args[1]
HUC_DEMs <- args[2]
METRIC <- args[3]
OUTPUT <- args[4]

cat("these are the arguments: \n", 
    "- Cluster number (integer 1-200ish):", CLUSTER, "\n",
    "- Path to the DEMs in TerrainProcessed folder", HUC_DEMs, "\n",
    "- Metric (slp, dmv, curv):", METRIC, "\n", 
    "- Path to the Save folder", OUTPUT, "\n"
)

###############################################################################################
library(terra)
library(sf)
library(MultiscaleDTM)
library(stringr)


setGDALconfig("GDAL_PAM_ENABLED", "FALSE") # does not create aux.xml files

# SLURM allocates 96 GB / 1 core per task — no in-script parallelism needed.
terraOptions(memmax = 80, tempdir = "Data/tmp")
###############################################################################################

process_scale <- function(dem_path, scale_factor, output_file, metric, scale_label) {
    setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
    if (file.exists(output_file)) {
        message(paste0(metric, " ", scale_label, " already exists, skipping"))
        return(invisible(NULL))
    }
    
    message(paste0("Creating ", metric, " ", scale_label, " for: ", output_file))
    dem_rast <- rast(dem_path)
    # Aggregate and resample - store intermediate to avoid re-computation
   if(scale_factor == 0){
       smoothed = dem_rast
   } else {
       smoothed <- dem_rast |>
           terra::aggregate(scale_factor, fun = "mean", na.rm = TRUE) |>
           terra::resample(y = dem_rast, method = "cubicspline")
   }
    
    # Compute metric and write directly to file
    result <- switch(metric,
                     "slp" = {
                         slp <- terra::terrain(smoothed,
                                               v = c("slope", "TPI"))
                         system.time({
                         sg <- rgeomorphon::geomorphons(elevation = smoothed, 
                                                        search = 100, 
                                                        use_meters = TRUE,
                                                        skip = 10, 
                                                        flat_angle_deg = 1.5)
                         })
                         slp_sg <- c(slp, sg)
                         writeRaster(slp_sg,
                                     filename = output_file,
                                     overwrite = TRUE, 
                                     names = c(paste0("slope_", scale_label),
                                               #paste0("aspect_", scale_label), #doesn't seem effective
                                               paste0("TPI_", scale_label) ,
                                               paste0("Geomorph_", scale_label)
                                               #paste0("TRI_", scale_label) # very similar to slope
                                     ))
                         rm(slp)
                         rm(sg)
                         rm(slp_sg)
                     },
                     "dmv" = {
                         dmv_result <- MultiscaleDTM::DMV(smoothed, w = c(3, 3), 
                                                          stand = "none", include_scale = FALSE)
                         writeRaster(dmv_result, output_file, overwrite = TRUE,
                                     names = c(paste0("dmv_", scale_label)))
                     },
                     "curv" = {
                         curv_result <- MultiscaleDTM::Qfit(smoothed, w = c(3, 3), include_scale = TRUE,
                                                            metrics = c("meanc", "planc", "profc"))
                         writeRaster(curv_result, output_file, overwrite = TRUE,
                                     names = c(paste0("meanc_", scale_label),
                                               paste0("planc_", scale_label),
                                               paste0("profc_", scale_label)))
                     },
                     stop("Unknown Metric")
    )
    
    # Explicit cleanup of intermediate
    rm(smoothed, result)
    gc(verbose = FALSE)
    
    return(invisible(NULL))
}


###############################################################################################

terrain_function <- function(dem_path, metric) {
    setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
    cluster_huc_name <- str_remove(basename(dem_path), "\\.tif$")
    message(paste0("\n=== Processing: ", cluster_huc_name, " ==="))
    
    # Define output paths
    base_path <- paste0(OUTPUT, cluster_huc_name, "_terrain_", metric)
    output_files <- list(
        "local" = paste0(base_path, "_local.tif"),
        "5m"   = paste0(base_path, "_5m.tif"),
        "100m" = paste0(base_path, "_100m.tif"),
        "500m" = paste0(base_path, "_500m.tif")
    )
    
    tryCatch({
        # Process each scale - DEM loaded only once
        process_scale(dem_path, 0, output_files[["local"]],   metric, "local")
        # process_scale(dem_path, 100, output_files[["100m"]], metric, "100m")
        # process_scale(dem_path, 500, output_files[["500m"]], metric, "500m")
        
    }, error = function(e) {
        message(paste0("ERROR at: ", cluster_huc_name, " - ", e$message))
        return(NA)
    })
    
    # Cleanup
    gc(verbose = FALSE)
    tmpFiles(remove = TRUE)
    
    return(invisible(NULL))
}
###############################################################################################

list_of_huc_dems <- list.files(
    HUC_DEMs,
    pattern = paste0("^cluster_", CLUSTER, "_.*\\.tif$"),  
    full.names = TRUE
) |> str_subset(pattern = "wbt", negate = TRUE) 

message(paste0("Found ", length(list_of_huc_dems), " DEMs to process"))

###############################################################################################

lapply(list_of_huc_dems, terrain_function, metric = METRIC)
