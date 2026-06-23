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

  # PatchGroup is the per-patch id we propagate into the NWI patches so they line
  # up 1:1 with the field-verified patches. Source patches without it (e.g. the
  # skipped overlapping gps_jc HUCs) can't be split per-patch, so skip them.
  if (!"PatchGroup" %in% names(p)) {
    message("No PatchGroup column in ", basename(fieldVerifiedpatch), " - skipping")
    return(invisible(NULL))
  }
  p <- sf::st_set_geometry(p, "geom")

  # One square box per patch. summarise() unions the polygons within each
  # PatchGroup back into its 256 m box. The metadata columns are reset to the
  # original-creation defaults rather than copied from the source patch -- these
  # are NWI-derived delineations and must not inherit the field-review provenance.
  p_boxes <- p |>
    dplyr::group_by(PatchGroup) |>
    dplyr::summarise(.groups = "drop") |>
    sf::st_set_geometry("geom") |>
    dplyr::mutate(
      ReviewerName      = "TBD",
      Confidence        = -999,
      BoundariesAltered = NA,
      Comments          = "NoComment"
    )

  p_text <- st_bbox(p) |> st_as_sfc() |> st_as_text()

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

  # Clip NWI to each patch box; PatchGroup + metadata come from p_boxes.
  if (nrow(nwi) > 0) {
    p_nwi <- st_intersection(p_boxes, nwi) |>
      st_collection_extract("POLYGON") |>
      sf::st_set_geometry("geom") |>
      dplyr::select(
        PatchGroup, ReviewerName, Confidence, BoundariesAltered,
        Comments, ATTRIBUTE, WETLAND_TYPE
      )
    p_out_nwi <- st_difference(p_boxes, st_union(st_geometry(nwi)))
  } else {
    p_nwi <- NULL
    p_out_nwi <- p_boxes
  }

  # Upland = each box minus the wetlands; metadata + PatchGroup carried from boxes.
  p_out_nwi <- p_out_nwi |>
    st_collection_extract("POLYGON") |>
    sf::st_set_geometry("geom") |>
    mutate(ATTRIBUTE = "UPL", WETLAND_TYPE = "UPL")

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
    st_cast(to = "MULTIPOLYGON") |>
    dplyr::select(
      ReviewerName, Confidence, BoundariesAltered, Comments, MOD_CLASS, PatchGroup
    )

  st_write(p_nwi_p, dsn = p_path)

  message("Done writing file at: ", p_path)
}

####################################################################################

lapply(
  list_of_field_verified,
  extractNWI
)
