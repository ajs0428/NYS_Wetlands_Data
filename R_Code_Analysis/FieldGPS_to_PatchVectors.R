library(sf)
library(dplyr)
library(stringr)
library(tidyr)

gps_survey_data <- read.csv("Data/FieldData/2026_Wetland_Validation/ADK_FieldVisit/survey_0.csv")
names(gps_survey_data)

gps_survey_sf <- st_as_sf(gps_survey_data, coords = c("x", "y"), crs = "EPSG:4326") |> 
  st_transform("EPSG:6347")
plot(gps_survey_sf["Site.and.Transect"])

gps_survey_sf_cent <- gps_survey_sf |> group_by(Site.and.Transect) |>
  summarise(geometry = st_union(geometry)) |> 
  st_centroid()

gps_survey_patches <- gps_survey_sf_cent |> 
  st_buffer(dist = 128, endCapStyle = "SQUARE")

plot(gps_survey_patches[1:8, "Site.and.Transect"])


# Find which polygons overlap with others
overlaps <- st_intersects(gps_survey_patches)

# Keep only the first polygon in each overlapping group
keep <- !duplicated(
  sapply(overlaps, function(x) paste(sort(x), collapse = "-"))
)

gps_survey_patches_clean <- gps_survey_patches[keep, ]

gps_survey_patches_format <- gps_survey_patches_clean |> 
  mutate(ReviewerName = "", 
         Confidence = -999,
         BoundariesAltered = TRUE,
         Comments = "", 
         MOD_CLASS = "UPL"
         ) |> 
  select(-Site.and.Transect)


st_write(gps_survey_patches_format, "Data/Training_Data/R_Patches_Vector_Field/ADK_05_21_2026.gpkg", append = FALSE)


cls <- st_read("Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg", quiet = TRUE) |> 
  st_transform("EPSG:6347")
pts <- st_read("/Users/Anthony/Data and Analysis Local/NYS_Wetlands_GHG/FieldData/NYS_DEC_Wetland_GHG_48_Field_Sites.gpkg",
               quiet = TRUE) |> st_transform("EPSG:6347")

pts_cls <- st_intersection(pts, cls)
pts_cls$cluster |> unique()


cls_unique <- c(240, 208, 11, 12, 51, 123, 90, 225, 192, 22, 183, 198, 250, 176,
193, 50, 218, 187, 60, 64, 153, 138, 152, 136, 67, 105, 120, 116,
86, 56, 189, 92, 84, 102, 53)

already <- c(11, 22, 46, 50, 64, 67, 82, 95, 123, 168, 208, 218, 225, 250)
not_yet <- cls_unique[!cls_unique %in% already] |> sort()
not_yet
s <- seq(1, 250)
s[!s %in% cls_unique]
