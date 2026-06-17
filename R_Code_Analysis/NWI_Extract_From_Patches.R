#!/usr/bin/env Rscript

args <- c(
  "Data/NWI/NY_NWI_6347.gpkg",
  "Data/Training_Data/R_Patches_Vector_NWI/", #
  "Data/Training_Data/R_Patches_Vector_Reviewed/"
)

args = commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

message(
  "these are the arguments: \n",
  "1) The NWI wetland dataset:",
  args[1],
  "\n",
  "2) path to place to save vector NWI patches:",
  args[2],
  "\n",
  "3) path to the field-verified vector patches: ",
  args[3],
  "\n"
)

NY_NWI <- args[1]
wetlandSavePath <- args[2]
fieldVerified <- args[3]

### Extract NWI from existing patches

library(sf)
library(dplyr)
library(tidyr)
library(stringr)

list_of_field_verified <- list.files(
  fieldVerified,
  pattern = ".gpkg",
  full.names = TRUE
)
########################################################################################

extractNWI <- function(
  fieldVerifiedpatch
) {
  # p_name <- str_remove(fieldVerifiedpatch, "^(.*?)cluster")

  p_path <- paste0(wetlandSavePath, "NWI_", basename(fieldVerifiedpatch))
  message("New file being created for: ", p_path)
  if (file.exists(p_path)) {
    message("File already exists")
    return(invisible(NULL))
  }

  p <- st_read(
    fieldVerifiedpatch,
    quiet = TRUE
  )

  p_ext <- st_bbox(p) |> st_as_sfc()
  p_text <- st_as_text(p_ext)
  p_cmb <- st_union(p, by_feature = FALSE) # makes whole patch boxes no delineations

  nwi <- st_read(
    NY_NWI,
    layer = "NY_Wetlands",
    wkt_filter = p_text,
    quiet = TRUE
  ) |>
    st_set_geometry("geom") |>
    filter(!str_detect(ATTRIBUTE, "R1|R3|R2|R4|R5")) |> # remove big rivers and small streams (unreliable)
    filter(!(str_detect(ATTRIBUTE, "L1") & as.numeric(st_area(geom)) > 2E5)) |> # remove big lakes
    filter(!str_detect(WETLAND_TYPE, "Marine|Estuarine|Other")) # remove marine/estuarine

  p_ext_nwi <- st_intersection(nwi, p_ext)

  p_nwi <- st_intersection(p_ext_nwi, p_cmb) |>
    st_sf() |>
    dplyr::select(ATTRIBUTE, WETLAND_TYPE) |>
    sf::st_set_geometry("geom")

  p_out_nwi <- st_difference(p_cmb, st_union(p_ext_nwi)) |>
    st_sf() |>
    st_set_geometry("geom") |>
    mutate(ATTRIBUTE = "UPL", WETLAND_TYPE = "UPL") |>
    select(ATTRIBUTE, WETLAND_TYPE, everything())

  p_nwi_p <- bind_rows(p_nwi, p_out_nwi) |>
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
        str_detect(ATTRIBUTE, "PSS") &
          str_detect(ATTRIBUTE, "PFO") ~ "Forested",
        str_detect(ATTRIBUTE, "PSS") &
          str_detect(ATTRIBUTE, "PEM") ~ "Emergent",
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

  st_write(p_nwi_p, dsn = p_path)

  message("Done writing file at: ", p_path)
}

####################################################################################

lapply(
  list_of_field_verified,
  extractNWI
)
