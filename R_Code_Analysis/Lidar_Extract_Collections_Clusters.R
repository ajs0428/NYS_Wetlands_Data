library(sf)
library(terra)
library(tidyverse)
library(stringdist)


colls <- st_read("Data/Lidar/NYS_Lidar_All_Indexes.gpkg") |> 
  dplyr::mutate(COLLECTION = case_when(is.na(COLLECTION) ~ COLLECTION_NAME,
                                       .default = COLLECTION)) |> 
  dplyr::select(-COLLECTION_NAME) |> 
  st_buffer(0)

# clusters <- c(11,12,22,46,50,51,53,56,60,64,67,84,86,90,92,102,105,116,120,123,126,136,138,152,176,183,187,189,192,193,198,203,208,218,225,240,250)
clusters <- c(11, 22, 46, 50, 64, 67, 82, 95, 123, 168, 208, 218, 225, 250)

lidar_cluster <- function(cluster_num) {
  q <- paste0("SELECT * FROM \"NY_Cluster_Zones_250_NAomit_6347\" WHERE cluster = ", cluster_num)
  cluster <- st_read("Data/NY_HUCS/NY_Cluster_Zones_250_NAomit_6347.gpkg", query = q, quiet = TRUE)
  
  int <- st_intersects(colls, cluster, sparse = FALSE) |> rowSums()
  
  colls_in_cluster <- colls[int > 0, ]
  coll_names <- colls_in_cluster |> 
    dplyr::select(starts_with("COLL")) |> 
    pull(1)
  coll_names_format <- str_replace_all(coll_names, " |/", "_") |> 
    str_replace_all("_-_", "_") |> 
    str_replace_all("USDA_USGS_ClinEsxFrk_2015", "USGS_Clinton_Essex_Franklin_2014")
  cluster_coll <- paste0(cluster_num, "|", coll_names_format, ".gpkg")  |> unique()                    
  return(cluster_coll)
}

all_colls_in_cluster <- purrr::map(clusters, \(x){lidar_cluster(x)}) |> 
  unlist()
# 
# writeLines(all_colls_in_cluster, "Data/Lidar/NYS_Lidar_Collections_Clusters.txt")

# Split the concatenated list into cluster number + candidate filename
candidates <- tibble(raw = all_colls_in_cluster) |>
  separate(raw, into = c("cluster", "candidate"), sep = "\\|", extra = "merge") |>
  mutate(cluster = as.integer(cluster))

# For each candidate, find the best match in the real file list
candidates <- candidates |>
  mutate(
    best_match = map_chr(candidate, \(x) {
      dists <- stringdist(x, list.files("Data/Lidar/Indexes/"), method = "jw")  # Jaro-Winkler
      list.files("Data/Lidar/Indexes/")[which.min(dists)]
    }),
    distance = map2_dbl(candidate, best_match, \(x, y) stringdist(x, y, method = "jw")),
    exact = candidate == best_match
  )

lidar_colls_clusters <- candidates |>
  #filter(!exact) |>
  select(cluster, candidate, best_match, distance) |>
  arrange(desc(distance)) |> 
  mutate(fixed = case_when(distance > 0 & str_detect(candidate, "East_of_Hudson_NYCDEP_2009.gpkg") ~ paste0(cluster, "|", "NYCDEP_East_Of_Hudson_2009.gpkg"),
                           # distance > 0 & !str_detect(candidate, "East_of_Hudson_NYCDEP_2009.gpkg")~ paste0(cluster, "|", best_match),
                           .default = paste0(cluster, "|", best_match)
                           )
  )
# write_csv(lidar_colls_clusters, "Data/Lidar/NYS_Lidar_Collections_Clusters.csv")

lines <- lidar_colls_clusters |>
  arrange(desc(cluster)) |> 
  mutate(entry = paste0('    "', fixed, '"')) |>
  pull(entry)
# Write to a text file
writeLines(
  c("entries=(", lines, ")"),
  "Data/Lidar/NYS_Lidar_Collections_Clusters_Batch1.txt"
)
