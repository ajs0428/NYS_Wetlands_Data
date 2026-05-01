### Pre Check for Stacking Rasters for Prediction/Inference

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
  225, # cluster subset options include number or NULL for any
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
                        query = paste0("SELECT * FROM NY_Cluster_Zones_250_CROP_NAomit_6347 WHERE cluster = '", clusterSubset, "'"))
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
l_terr_cluster_slp <- l_terr_cluster[grepl("slp", l_terr_cluster)]
l_terr_cluster_curv <- l_terr_cluster[grepl("curv", l_terr_cluster)]
l_terr_cluster_dmv <- l_terr_cluster[grepl("dmv", l_terr_cluster)]
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


if(length(huc_numbers) != length(l_dem_cluster)){
  missingD <- huc_numbers[!huc_numbers %in% str_extract(l_dem_cluster, "\\d{12}")]
  message("HUC numbers not equal to DEM, missing: \n", paste(missingD, collapse = "\n"))
} 
if(length(l_naip_cluster) != length(l_dem_cluster)){
  missingN <- huc_numbers[!huc_numbers %in% str_extract(l_naip_cluster, "\\d{12}")]
  message("HUC numbers not equal to NAIP, missing: \n", paste(missingN, collapse = "\n"))
} 
if(length(l_sat_cluster) != length(l_dem_cluster)){
  missingS <- huc_numbers[!huc_numbers %in% str_extract(l_sat_cluster, "\\d{12}")]
  message("HUC numbers not equal to Satellite, missing: \n", paste(missingS, collapse = "\n"))
} 
if(length(l_hydro_cluster) != length(l_dem_cluster)){
  missingH <- huc_numbers[!huc_numbers %in% str_extract(l_hydro_cluster, "\\d{12}")]
  message("HUC numbers not equal to Hydro, missing: \n", paste(missingH, collapse = "\n"))
} 
if(length(l_lidar_cluster) != length(l_dem_cluster)){
  missingL <- huc_numbers[!huc_numbers %in% str_extract(l_lidar_cluster, "\\d{12}")]
  message("HUC numbers not equal to Lidar, missing: \n", paste(missingL, collapse = "\n"))
}
if(length(l_chm_cluster) != length(l_dem_cluster)){
  missingC <- huc_numbers[!huc_numbers %in% str_extract(l_chm_cluster, "\\d{12}")]
  message("HUC numbers not equal to CHM, missing: \n", paste(missingC, collapse = "\n"))
}
if(length(l_terr_cluster_slp) != length(l_dem_cluster)){
  missingTs <- huc_numbers[!huc_numbers %in% str_extract(l_terr_cluster_slp, "\\d{12}")]
  message("HUC numbers not equal to Terrain slp, missing: \n", paste(missingTs, collapse = "\n"))
}
if(length(l_terr_cluster_curv) != length(l_dem_cluster)){
  missingTc <- huc_numbers[!huc_numbers %in% str_extract(l_terr_cluster_curv, "\\d{12}")]
  message("HUC numbers not equal to Terrain curv, missing: \n", paste(missingTc, collapse = "\n"))
}
if(length(l_terr_cluster_dmv) != length(l_dem_cluster)){
  missingTd <- huc_numbers[!huc_numbers %in% str_extract(l_terr_cluster_dmv, "\\d{12}")]
  message("HUC numbers not equal to Terrain curv, missing: \n", paste(missingTd, collapse = "\n"))
}

all_missing <- unique(c(
  if (exists("missingD")) missingD,
  if (exists("missingN")) missingN,
  if (exists("missingS")) missingS,
  if (exists("missingH")) missingH,
  if (exists("missingL")) missingL,
  if (exists("missingC")) missingC,
  if (exists("missingTs")) missingTs,
  if (exists("missingTc")) missingTc,
  if (exists("missingTd")) missingTd
))

all_missing_hucs_df <- list(
  missingD = if (exists("missingD")) missingD,
  missingN = if (exists("missingN")) missingN,
  missingS = if (exists("missingS")) missingS,
  missingH = if (exists("missingH")) missingH,
  missingL = if (exists("missingL")) missingL,
  missingC = if (exists("missingC")) missingC,
  missingTs = if (exists("missingTs")) missingTs,
  missingTc = if (exists("missingTc")) missingTc,
  missingTd = if (exists("missingTd")) missingTd
)  |>
  purrr::imap(\(vals, nm) tibble(source = nm, huc = vals)) |>
  bind_rows() |> 
  dplyr::mutate(
    cluster = clusterSubset,
    source = case_when(source == "missingD" ~ "DEM",
                       source == "missingN" ~ "NAIP",
                       source == "missingS" ~ "Satellite",
                       source == "missingH" ~ "Hydro",
                       source == "missingL" ~ "Lidar",
                       source == "missingC" ~ "CHM",
                       source == "missingTs" ~ "TerrainSlp",
                       source == "missingTc" ~ "TerrainCurv",
                       source == "missingTd" ~ "TerrainDMV",
                       .default = source)
  )

if (!"huc" %in% names(all_missing_hucs_df)) {
  all_missing_hucs_df <- all_missing_hucs_df |> 
    mutate(huc = NA_character_) |> 
    select(source, huc, cluster)
} else {
  all_missing_hucs_df <- all_missing_hucs_df |> 
    select(source, huc, cluster)
}

readr::write_csv(all_missing_hucs_df, paste0("Data/MissingProcessing/cluster_", clusterSubset, "_missingHUCprocessing.csv"))


### Run code below to summarise all .csv
# list.files("Data/MissingProcessing/", full.names = TRUE) |> lapply(read.csv) |> bind_rows() |> na.omit() |> dplyr::arrange(source)