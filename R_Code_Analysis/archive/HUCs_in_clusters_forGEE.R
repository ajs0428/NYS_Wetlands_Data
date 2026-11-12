### This script finds the cluster groups of HUCs to write to an external file for GEE to loop over
library(terra)
library(sf)

cls <- st_read("Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.shp")

batch <- "Batch1"
cls_nums <- c(11, 22, 46, 50, 64, 67, 82, 95, 123, 168, 208, 218, 225, 250)
batch <- "Batch2"
cls_nums <- c(1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
              12 ,13 ,14, 15, 16, 17, 18, 19,
              20, 21, 23, 24, 25, 26, 27, 28, 
              29, 30, 31, 32)

df <- cls |> filter(cluster %in% cls_nums) |> 
    as.data.frame() |> 
    select(huc12) 

# writeLines(df$huc12, "Data/Dataframes/HUCs_in_site_clusters.txt")

cls_filter <- cls |> filter(cluster %in% cls_nums)

cls_filter[cls_filter$huc12 == "020200030406", ] |> na.omit() |> st_geometry() |> vect() |> plet()

# cls |> na.omit() |> st_write("Data/NY_HUCS/NY_Cluster_Zones_250_NAomit.gpkg")

dfna <- cls |> na.omit() |> filter(cluster %in% cls_nums) |> 
    as.data.frame() |> 
    select(huc12) 
writeLines(dfna$huc12, paste0("Data/Dataframes/HUCs_in_", batch, "_clusters_NAomit.txt"))
