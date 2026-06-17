### Extract NWI from existing patches

library(sf)
library(dplyr)
library(tidyr)
library(stringr)

nwi <- st_read("Data/NWI/NY_NWI_6347.gpkg", layer = "NY_Wetlands")

p <- st_read(
  "Data/Training_Data/R_Patches_Vector_Reviewed/ADK_WCT_AJS_cluster_11_huc_042900030103_256m.gpkg"
)
p_ext <- st_bbox(p) |> st_as_sfc()
p_cmb <- st_union(p, by_feature = FALSE)

p_ext_nwi <- st_intersection(nwi, p_ext)
plot(p_ext_nwi["WETLAND_TYPE"])

p_nwi <- st_intersection(p_ext_nwi, p_cmb) |>
  st_sf() |>
  dplyr::select(ATTRIBUTE, WETLAND_TYPE) |>
  sf::st_set_geometry("geom")
plot(p_nwi)

p_out_nwi <- st_difference(p_cmb, st_union(p_ext_nwi)) |>
  st_sf() |>
  st_set_geometry("geom") |>
  mutate(ATTRIBUTE = "UPL", WETLAND_TYPE = "UPL") |>
  select(ATTRIBUTE, WETLAND_TYPE, everything())

plot(p_out_nwi)

p_nwi_p <- bind_rows(p_nwi, p_out_nwi)
plot(p_nwi_p)

p_nwi_p |>
  filter(!str_detect(ATTRIBUTE, "R1|R3|R2|R4|R5")) |> # remove big rivers and small streams (unreliable)
  filter(!(str_detect(ATTRIBUTE, "L1") & as.numeric(st_area(geom)) < 2E5)) |> # remove big lakes
  filter(!str_detect(WETLAND_TYPE, "Marine|Estuarine|Other")) |> # remove marine/estuarine
  mutate(
    WetClass = case_when(
      str_detect(ATTRIBUTE, "L1|L2|PUB|PUS|PAB|R2|R3") &
        !str_detect(ATTRIBUTE, "PFO|PEM|PSS") ~ "OpenWater",
      str_detect(ATTRIBUTE, "PSS") &
        !str_detect(ATTRIBUTE, "PFO|PEM") ~ "ScrubShrub",
      str_detect(ATTRIBUTE, "PEM") &
        !str_detect(ATTRIBUTE, "PFO|PSS") ~ "Emergent",
      str_detect(ATTRIBUTE, "PFO") &
        !str_detect(ATTRIBUTE, "PSS|PEM") ~ "Forested",
      str_detect(ATTRIBUTE, "PSS") & str_detect(ATTRIBUTE, "PFO") ~ "Forested",
      str_detect(ATTRIBUTE, "PSS") & str_detect(ATTRIBUTE, "PEM") ~ "Emergent",
      .default = ATTRIBUTE
    )
  ) |>
  dplyr::mutate(
    MOD_CLASS = case_when(
      WetClass == "Emergent" ~ "EMW", #MOD_CLASS is for modeling
      WetClass == "Forested" ~ "FSW",
      WetClass == "ScrubShrub" ~ "SSW",
      WetClass == "OpenWater" ~ "OWW",
      WetClass == "UPL" ~ "UPL",
      .default = "Other"
    ),
  ) |>
  dplyr::select(MOD_CLASS)
