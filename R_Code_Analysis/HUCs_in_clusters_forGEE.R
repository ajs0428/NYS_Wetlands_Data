### This script finds the cluster groups of HUCs to write to an external file for GEE to loop over
library(terra)
library(sf)

cls <- st_read("Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.shp")

cls_nums <- c(11, 22, 46, 50, 64, 67, 82, 95, 123, 168, 208, 218, 225, 250)

df <- cls |> filter(cluster %in% cls_nums) |> 
    as.data.frame() |> 
    select(huc12) 

writeLines(df$huc12, "Data/Dataframes/HUCs_in_site_clusters.txt")

cls_filter <- cls |> filter(cluster %in% cls_nums)

cls_filter[cls_filter$huc12 == "020200030406", ] |> na.omit() |> st_geometry() |> vect() |> plet()

cls |> na.omit() |> st_write("Data/NY_HUCS/NY_Cluster_Zones_250_NAomit.gpkg")

dfna <- cls |> na.omit() |> filter(cluster %in% cls_nums) |> 
    as.data.frame() |> 
    select(huc12) 
writeLines(dfna$huc12, "Data/Dataframes/HUCs_in_site_clusters_NAomit.txt")
