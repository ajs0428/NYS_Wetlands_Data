### NWI Reclassification based on CHM 

library(terra)
library(sf) 
library(tidyverse)
library(stringr)
library(tidyterra)
library(future)
library(future.apply)


set.seed(11)

########################################################################################

args <- c(
    123, #Target Cluster
    "Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg", #Clusters and HUCs
    "Data/ADK/RegWetlandAreasParkPromulgated_UTM83.shp", # Wetlands
    "ATTRIBUTE" # Field for filtering and matching
    )

args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

targetCluster <- args[1]
clusterHUCs <- args[2]
wetlandsSource <- args[3]
reclassField <- args[4]


cat("these are the arguments: \n", 
    "1) Cluster number for HUC groups:", targetCluster, "\n", 
    "2) path to the overall zones or study areas :", clusterHUCs, "\n",
    "3) Path to the wetlands:", wetlandsSource, "\n",
    "4) Field in polygons for filtering and extracting wetland type: ", reclassField, "\n"
    )

########################################################################################
l_chm <- list.files("Data/CHMs/HUC_CHMs/", pattern = ".tif", full.names = TRUE) 
l_chm_cluster <- l_chm[str_detect(l_chm, paste0("cluster_", targetCluster))] # CHMs for targetCluster cluster of HUCs 
l_chm_cluster_nums <- str_extract(l_chm, "(?<=cluster_)\\d+(?=_)") |> unique() # each cluster of HUCs present in the CHMs 

########################################################################################
# all the HUCs in the entire CHM dataset
ny_hucs <- sf::st_read(clusterHUCs, quiet = TRUE,
                       query = paste0("SELECT * FROM NY_Cluster_Zones_250_NAomit_6347 WHERE cluster IN (", 
                                      paste(l_chm_cluster_nums, collapse = ","), ")")) 
# The HUCs in the cluster from targetCluster
huc_cluster <- sf::st_read(clusterHUCs, quiet = TRUE,
                       query = paste0("SELECT * FROM NY_Cluster_Zones_250_NAomit_6347 WHERE cluster IN (", targetCluster, ")"))
huc_nums_cluster <- huc_cluster$huc12
hucs_bbox_wkt <- st_as_text(st_as_sfc(st_bbox(huc_cluster)))

print(huc_nums_cluster)
print(huc_cluster)
########################################################################################

# All wetlands from NWI and other sources??
wetlands <- st_read(wetlandsSource, quiet = F, wkt_filter = hucs_bbox_wkt)

if(st_crs(wetlands) != st_crs("EPSG:6347")){
    wetlands <- st_transform(wetlands, "EPSG:6347")
    st_write(wetlands, paste0(str_remove(wetlandsSource, "\\..*"), "_6347", ".gpkg"), delete_layer = TRUE)
} else {
    print("No reprojection to EPSG:6347")
}

wetlands_filter <- wetlands |>
    filter(!str_detect(.data[[reclassField]], "^R|^L|^E1|^E2|^E3|^M1|^M2|^M3|^Other|^PUB|^PAB|^PUS|^Pf$"))# remove and small streams (unreliable) # remove marine/estuarine

# This gives it the "huc" and "cluster" fields, conveniently 
wetlands_cluster <- wetlands_filter |> st_filter(huc_cluster) |> st_intersection(huc_cluster)

########################################################################################

#For each HUC watershed
    # mask and extract CHM using the NWI wetlands
    # Zonal stats appended to NWI wetlands
    # Reclassify based on Mahoney et al., 2022 (Colin Beier) 1m ≤ Shrubland ≤5m

wetland_chm_extract_classify <- function(huc_num){
    if(grepl("NWI", basename(wetlandsSource))){
      suffix <- "NWI"
      saveFolder <- "Data/Training_Data/HUC_NWI_Processed/"
    } else if(grepl("NHP", basename(wetlandsSource))){
      suffix <- "NHP"
      saveFolder <- "Data/Training_Data/HUC_NHP_Processed/"
    } else if(grepl("Laba", basename(wetlandsSource))){
      suffix <- "Laba"
      saveFolder <- "Data/Training_Data/HUC_Laba_Processed/"
    } else if(grepl("ADK_WCT", basename(wetlandsSource))){
      suffix <- "ADK_WCT"
      saveFolder <- "Data/Training_Data/HUC_ADK_Processed/"
    } else if(grepl("ADK_regulated", basename(wetlandsSource))){
      suffix <- "ADK_regulated"
      saveFolder <- "Data/Training_Data/HUC_ADK_Processed/"
    } else {
      suffix <- sub("_.*", "", tools::file_path_sans_ext(basename(wetlandsSource)))
      saveFolder <- "Data/Training_Data/HUC_OtherWetland_Processed/"
    }
    tryCatch({
        r_chm <- rast(l_chm_cluster[str_detect(l_chm_cluster , huc_num)])
        sf_wet <- wetlands_cluster |> 
          dplyr::filter(huc12 == huc_num) |> 
          dplyr::mutate(ID = paste0(ATTRIBUTE, "_", row_number())) 
        v_wet <- sf_wet |> 
          vect() |> 
          terra::buffer(-10) #negative buffer to remove edge effects

        filename <- paste0(saveFolder, suffix, "_cluster_", targetCluster, "_huc_", huc_num, ".gpkg")
        
        if(!file.exists(filename)){
            message(paste0("Creating New Wetlands Reclass File: ", filename))
            wet_chm <- terra::extract(r_chm, v_wet, "mean", bind = TRUE) |> 
                tidyterra::mutate(
                    MOD_CLASS = dplyr::case_when(
                        str_detect(.data[[reclassField]], "L1|L2|PUB|PUS|PAB|R2|R3") & !str_detect(.data[[reclassField]], "PFO|PEM|PSS") & CHM <= 1.0 ~ "OWW",
                        # str_detect(.data[[reclassField]], "L1|L2|PUB|PUS|PAB|R2|R3") & !str_detect(.data[[reclassField]], "PFO|PEM|PSS") & CHM > 1.0 & CHM <= 3.5 ~ "EMW",
                        str_detect(.data[[reclassField]], "PSS") & !str_detect(.data[[reclassField]], "FO|EM") & CHM >= 1.0 & CHM <= 5.0 ~ "SSW",
                        str_detect(.data[[reclassField]], "PSS") & !str_detect(.data[[reclassField]], "FO|EM") & CHM > 5.0 ~ "FSW",
                        str_detect(.data[[reclassField]], "PEM") & !str_detect(.data[[reclassField]], "FO|SS") & CHM <= 3.5 ~ "EMW",
                        str_detect(.data[[reclassField]], "PEM") & !str_detect(.data[[reclassField]], "FO|SS") & CHM >= 1.0 & CHM <= 5.0 ~ "SSW",
                        str_detect(.data[[reclassField]], "PEM") & !str_detect(.data[[reclassField]], "FO|SS") & CHM > 5.0 ~ "FSW",
                        str_detect(.data[[reclassField]], "PFO") & !str_detect(.data[[reclassField]], "SS|EM") & CHM >= 1.0 & CHM <= 5.0 ~ "SSW",
                        str_detect(.data[[reclassField]], "PFO") & !str_detect(.data[[reclassField]], "SS|EM") & CHM > 5.0 ~ "FSW",
                        str_detect(.data[[reclassField]], "PFO") & str_detect(.data[[reclassField]], "SS|EM") & CHM <= 3.5 ~ "EMW",
                        str_detect(.data[[reclassField]], "PFO") & str_detect(.data[[reclassField]], "SS|EM") & CHM >= 1.0 & CHM <= 5.0 ~ "SSW",
                        str_detect(.data[[reclassField]], "PFO") & str_detect(.data[[reclassField]], "SS|EM") & CHM > 5.0 ~ "FSW",
                        str_detect(.data[[reclassField]], "PSS") & str_detect(.data[[reclassField]], "FO") & CHM >= 1.0 & CHM <= 5.0 ~ "SSW",
                        str_detect(.data[[reclassField]], "PSS") & str_detect(.data[[reclassField]], "FO") & CHM > 5.0 ~ "FSW",
                        str_detect(.data[[reclassField]], "PSS") & str_detect(.data[[reclassField]], "EM") & CHM <= 3.5 ~ "EMW",
                        str_detect(.data[[reclassField]], "PSS") & str_detect(.data[[reclassField]], "EM") & CHM > 3.5 & CHM <= 5.0 ~ "SSW",
                        str_detect(.data[[reclassField]], "PEM") & str_detect(.data[[reclassField]], "SS") & CHM <= 3.5 ~ "EMW",
                        str_detect(.data[[reclassField]], "PEM") & str_detect(.data[[reclassField]], "SS") & CHM > 3.5 & CHM <= 5.0 ~ "SSW",
                        .default = "REVIEW"
                    ))
            print(unique(wet_chm$MOD_CLASS))
            
            wet_chm_sf <- wet_chm |> 
              st_as_sf() |> 
              st_drop_geometry() |>   # drop buffered geometry entirely
              dplyr::select(ID, MOD_CLASS)
            
            sf_wet_reclass <- sf_wet |> 
              dplyr::left_join(wet_chm_sf, by = "ID") |> 
              dplyr::select(MOD_CLASS) 
            
            st_write(sf_wet_reclass, dsn = filename, append = FALSE)
            # writeVector(sf_wet_reclass, filename = filename, overwrite = TRUE)
            # rm(r_chm)
            # rm(v_wet)
            # rm(wet_chm)
            return(sf_wet_reclass)
        } else {
            message(paste0("NWI Reclass File Aleady Exists: ", filename))
        }
    }, error = function(e){
        message(e$message)
        return(NA)
    })
    # return(invisible(NULL))
    # gc()
}



###############################################################################################
slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")
if (nzchar(slurm_cpus)) {
  corenum <- as.integer(slurm_cpus)
} else {
  corenum <- min(future::availableCores(), 4)
}
options(future.globals.maxSize= 16 * 1e9)

plan(future.callr::callr, workers = corenum)

system.time({future_lapply(huc_nums_cluster, 
                           wetland_chm_extract_classify, 
                           future.seed=TRUE,
                           future.packages = c("terra", "sf", "tidyverse", "future", "future.lapply"),
                           future.globals = TRUE)})

# t <- lapply(huc_nums_cluster[1], wetland_chm_extract_classify)
