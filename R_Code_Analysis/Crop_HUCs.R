library(sf)

eco <- st_read("Data/NY_HUCS/Ecological_Regions_4058521648144261328.gpkg") |> 
  st_transform("EPSG:6347")
eco_diss <- st_union(eco) |> 
  st_buffer(100) |> 
  st_sf()
plot(eco_diss)
clusters <- sf::st_read("Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg", quiet = TRUE)

clusters_cut <- st_intersection(eco_diss, clusters)
plot(st_geometry(clusters_cut))

# clusters_cut_join <- st_join(clusters_cut |> st_sf(), clusters)

st_write(clusters_cut, dsn = "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg", append = FALSE)
