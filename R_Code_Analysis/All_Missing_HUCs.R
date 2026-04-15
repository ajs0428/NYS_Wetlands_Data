library(readr)
library(dplyr)
library(stringr)

###############

system("bash Shell_Scripts/precheck_missing_hucs.sh")

missing_huc_files <- list.files("Data/MissingProcessing/", full.names = TRUE)
missing_huc_df <- readr::read_csv(missing_huc_files) |> 
  filter(!is.na(huc))
print(missing_huc_df, n = nrow(missing_huc_df))

missing_clust <- unique(missing_huc_df$cluster)
missing_source <- unique(missing_huc_df$source)
summ_missing_huc_df <- missing_huc_df |> group_by(cluster, source) |> reframe()

for(i in 1:nrow(summ_missing_huc_df)){
  cls <- summ_missing_huc_df[i,1][[1]]
  src <- summ_missing_huc_df[i,2][[1]]
  
  if(src == "NAIP"){
    Rs <- "R_Code_Analysis/NAIP_GEE_Processing_CMD.r"
  }
  if(src == "Satellite"){
    Rs <- "R_Code_Analysis/Sentinel_FromGEE_Processing.R"
    "Data/TerrainProcessed/HUC_DEMs/", 
    "Data/Satellite/GEE_Download_NY_HUC_Sentinel_Indices/",
    "Data/Satellite/HUC_Processed_NY_Sentinel_Indices/"
    "$number"
  }
  if(src == "TerrainCurv"){
    Rs <- "R_Code_Analysis/terrain_metrics_noparallel_filter_singleVect_CMD.r"
  }
  if(src == "TerrainDMV"){
    Rs <- "R_Code_Analysis/terrain_metrics_filter_singleVect_CMD.r"
  }
  if(src == "TerrainSlp"){
    Rs <- "R_Code_Analysis/terrain_metrics_filter_singleVect_CMD.r"
  }
  if(src == "CHM"){
    Rs <- "R_Code_Analysis/CHM_extraction.R"
  }
  if(src == "Lidar"){
    Rs <- "R_Code_Analysis/Lidar_HUC_Processing.R"
  }
  if(src == "Hydro"){
    Rs <- "R_Code_Analysis/hydro_metrics_singleVect_CMD.r"
  }
  
  paste0("bash Rscript ", Rs, "")
}

paste0("bash Rscript ", "R_Code_Analysis/")