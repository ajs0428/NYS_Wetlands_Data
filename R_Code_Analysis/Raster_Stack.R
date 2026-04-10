### Stacking Rasters for Prediction/Inference

library(terra)
library(sf) 
library(dplyr)
library(tidyr)
library(stringr)
library(tidyterra)
library(future)
library(future.apply)

set.seed(11)

########################################################################################

args <- c(
  22, # cluster subset options include number or NULL for any
  "Data/HUC_Raster_Stacks/HUC_DL_Stacks/" #Save path for HUC Raster Stacks
)

args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

clusterSubset <- args[1]
savePath <- args[2]

message("these are the arguments: \n", 
        "1) cluster number: ", clusterSubset, "\n",
        "2) save output path: ", savePath, "\n"
)

setGDALconfig("GDAL_PAM_ENABLED", "FALSE") # does not create aux.xml files but maybe needed
########################################################################################

huc_poly <- sf::st_read("Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg", quiet = TRUE,
                        query = paste0("SELECT * FROM NY_Cluster_Zones_250_NAomit_6347 WHERE cluster = '", clusterSubset, "'"))
huc_numbers <- huc_poly$huc12

clust_extract_fun <- function(l){
  # extracted_clusters <- sub(".*cluster_(\\d+)_.*", "\\1", l)
  if(str_detect(deparse(substitute(l)), "dem")){
    message("DEM")
    l_clust <- l[grepl(paste0("cluster_", clusterSubset, "_"), l) & 
                   !str_detect(l, "wbt")]
  } else if(str_detect(deparse(substitute(l)), "terr")){
    message("Terrain")
    l_clust <- l[grepl(paste0("cluster_", clusterSubset, "_"), l) & 
                   str_detect(l, "local") & 
                   !str_detect(l, "10m|1000m")]
  } else {
    message(str_remove(deparse(substitute(l)), "l_"))
    l_clust <- l[grepl(paste0("cluster_", clusterSubset, "_"), l)]
  }
  return(l_clust)
}
l_dem <- list.files("Data/TerrainProcessed/HUC_DEMs/", pattern = ".tif", full.names = TRUE) 
l_dem_cluster <- clust_extract_fun(l_dem)
l_dem_cluster_nums <- str_extract(l_dem, "(?<=cluster_)\\d+(?=_)") |> unique() # All the DEM clusters

l_chm <- list.files("Data/CHMs/HUC_CHMs/", pattern = ".tif", full.names = TRUE) 
l_chm_cluster <- clust_extract_fun(l_chm)

l_naip <- list.files("Data/NAIP/HUC_NAIP_Processed/", pattern = ".tif", full.names = TRUE) 
l_naip_cluster <- clust_extract_fun(l_naip)

l_terr <- list.files("Data/TerrainProcessed/HUC_TerrainMetrics/", 
                     full.names = TRUE)
l_terr_cluster <- clust_extract_fun(l_terr)
l_hydro <- list.files("Data/TerrainProcessed/HUC_Hydro/", 
                      pattern = ".tif",
                      full.names = TRUE)
l_hydro_cluster <- clust_extract_fun(l_hydro)
l_sat <- list.files("Data/Satellite/HUC_Processed_NY_Sentinel_Indices/", 
                    full.names = TRUE)
l_sat_cluster <- clust_extract_fun(l_sat)


l_lidar <- list.files("Data/Lidar/HUC_Lidar_Metrics/", 
                      full.names = TRUE)
l_lidar_cluster <- clust_extract_fun(l_lidar)

length(huc_numbers) == length(l_dem_cluster) & 
  length(l_naip_cluster) == length(l_dem_cluster) & 
  length(l_dem_cluster) == length(l_sat_cluster) & 
  length(l_dem_cluster) == length(l_hydro_cluster) & 
  length(l_dem_cluster) == length(l_lidar_cluster)

#################################################################################################

rast_stack_export <- function(huc_number) {
  
  terraOptions(memfrac = 0.2, memmax = 48, tempdir = "Data/tmp")
  
  stack_fn <- paste0(savePath, "cluster_", clusterSubset, "_huc_", huc_number, "_stack.tif")
  
  if (file.exists(stack_fn)) {
    message("Stack already exists: ", stack_fn)
    return(invisible(stack_fn))
  }
  message("Creating new file for: ", stack_fn)
  tryCatch({
    cluster_id <- paste0("cluster_", clusterSubset)
    
    # --- Helper to match and validate files ---
    get_rast_file <- function(file_list, label) {
      matched <- file_list[grepl(huc_number, file_list) & grepl(cluster_id, file_list)]
      if (length(matched) == 0) stop("No ", label, " file found for HUC ", huc_number)
      if (length(matched) > 1) warning("Multiple ", label, " files for HUC ", huc_number, "; using first")
      matched[1]
    }
    
    # --- Read and prep each layer ---
    dem_rast <- rast(get_rast_file(l_dem_cluster, "DEM"))
    set.names(dem_rast, "DEM")
    
    chm_rast <- rast(get_rast_file(l_chm_cluster, "CHM"))
    
    sat_rast <- rast(get_rast_file(l_sat_cluster, "SAT")) |>
      tidyterra::select(-dplyr::contains("NDVI"), -dplyr::contains("MNDWI"), 
                        -dplyr::contains("PSRI"), -dplyr::contains("DPSVI"), 
                        -dplyr::contains("RVI"), -dplyr::contains("VH_VV_ratio")
                        )
    
    terr_rast <- rast(get_rast_file(l_terr_cluster, "terrain")) |>
      tidyterra::select(-starts_with("TPI_"), -starts_with("dmv"))
    
    hydro_rast <- rast(get_rast_file(l_hydro_cluster, "hydro"))
    hydro_rast$flowacc <- log(hydro_rast$flowacc)
    
    naip_rast <- rast(get_rast_file(l_naip_cluster, "NAIP"))
    set.names(naip_rast, c("r", "g", "b", "nir", "n_ndvi", "n_ndwi"))
    
    lidar_rast <- rast(get_rast_file(l_lidar_cluster, "LiDAR"))
    
    # --- Align and stack ---
    rast_list <- list(dem_rast, terr_rast, hydro_rast, chm_rast, sat_rast, naip_rast, lidar_rast)
    ref <- rast_list[[1]]
    
    aligned <- lapply(rast_list, \(r) {
      if (!compareGeom(r, ref, stopOnError = FALSE)) {
        message("Resampling ", paste(names(r), collapse = ", "), " to match DEM extent/resolution")
        resample(r, ref, method = "bilinear")
      } else {
        r
      }
    })
    
    
    stack <- rast(aligned)
    writeRaster(stack, filename = stack_fn, overwrite = TRUE)
    message("Wrote stack: ", stack_fn)
    terra::tmpFiles(remove = TRUE)
    return(invisible(stack_fn))
    
  }, error = \(e) {
    warning("Failed for HUC ", huc_number, ": ", conditionMessage(e))
    return(invisible(NULL))
  })
}

#################################################################################################

### Parallel 

slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
  corenum <- as.integer(slurm_cpus)
} else {
  corenum <- min(future::availableCores(), 2)
}

print(corenum)
options(future.globals.maxSize= 48.0 * 1e9)
# plan(multisession, workers = corenum)
plan(future.callr::callr)

future_lapply(huc_numbers, rast_stack_export,
              future.seed = TRUE,
              future.packages = c("terra", "sf", "dplyr", "tidyr", "stringr", "tidyterra"),
              future.globals = TRUE
)


### Non-parallel/Sequential
# lapply(huc_numbers, rast_stack_export)

