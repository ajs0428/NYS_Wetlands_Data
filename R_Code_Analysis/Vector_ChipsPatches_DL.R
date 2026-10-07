### Vector chips/patches for DL
# Creates and extracts square patches in vector format (polygons) from
# another data source (e.g. NWI)
# Processes by HUC12 cluster

library(terra)
library(sf)
library(dplyr)
library(tidyr)
library(stringr)
library(tidyterra)
library(readr)
library(future)
library(future.apply)
library(purrr)

set.seed(11)

########################################################################################

args <- c(
    200, # Cluster
    "Data/Training_Data/HUC_Laba_Processed/", #Path to wetland polygons
    128, # Patch size radius
    "MULTICLASS" # Class scheme: "MULTICLASS" (EMW/FSW/SSW/UPL) or "BINARY" (WET/UPL)
)

args <- commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

clusterTarget <- args[1]
wetlandPath <- args[2]
patchSize <- as.numeric(args[3])
# optional 4th arg; anything other than "BINARY" keeps the multiclass labels
classScheme <- if (isTRUE(toupper(args[4]) == "BINARY")) {
    "BINARY"
} else {
    "MULTICLASS"
}

cat(
    "these are the arguments: \n",
    "1) Cluster number for HUC groups:",
    clusterTarget,
    "\n",
    "2) path the reviewed training data :",
    wetlandPath,
    "\n",
    "3) patch size :",
    patchSize,
    "\n",
    "4) class scheme :",
    classScheme,
    "\n"
)

########################################################################################
## Patch-center sampling
# Candidate centers come from three sources, in priority order:
#   1. one point on the surface of every wetland polygon (small wetlands get a shot)
#   2. points every `boundarySpacing` m along every polygon ring (incl. holes)
#   3. a regular grid every `interiorSpacing` m inside the polygons (large wetlands)
# Candidates whose box would cross the HUC edge are dropped, then a greedy pass
# keeps a candidate only if its box does not overlap any box already kept.
boxSide <- patchSize * 2
boundarySpacing <- boxSide # m between candidate points along polygon edges
interiorSpacing <- boxSide # m between candidate grid points inside polygons

setGDALconfig("GDAL_PAM_ENABLED", "FALSE") # does not create aux.xml files but maybe needed
########################################################################################
l_wet <- list.files(wetlandPath, pattern = ".gpkg$", full.names = TRUE) ## |> keep(\(x) str_detect(x, "ADK_WCT"))
l_wet_cluster <- l_wet[str_detect(
    l_wet,
    paste0("cluster_", clusterTarget, "_")
)]

print(l_wet_cluster)

logpath <- "Data/Training_Data/R_Patches_Vector/Vector_Patch_Checklist.csv"
########################################################################################
# fct_df <- data.frame(ID = 0:4, MOD_CLASS = c("EMW", "FSW", "OWW", "SSW", "UPL"))
fct_df <- data.frame(ID = 0:3, MOD_CLASS = c("EMW", "FSW", "SSW", "UPL"))
########################################################################################
# Greedy non-overlap thinning of square boxes: two boxes of side `side` centered at
# p and q do not overlap when max(|dx|, |dy|) >= side. Earlier rows win.
thin_boxes <- function(xy, side) {
    keep <- logical(nrow(xy))
    kx <- numeric(0)
    ky <- numeric(0)
    for (i in seq_len(nrow(xy))) {
        if (
            length(kx) == 0 ||
                all(pmax(abs(kx - xy[i, 1]), abs(ky - xy[i, 2])) >= side)
        ) {
            keep[i] <- TRUE
            kx <- c(kx, xy[i, 1])
            ky <- c(ky, xy[i, 2])
        }
    }
    keep
}
########################################################################################
set.seed(420)

vect_chip_patch_create <- function(wetland_file) {
    ## Setup vars
    if (grepl("NWI", basename(wetland_file))) {
        sourceWetlands <- "NWI"
    } else if (grepl("NHP", basename(wetland_file))) {
        sourceWetlands <- "NHP"
    } else if (grepl("Laba", basename(wetland_file))) {
        sourceWetlands <- "Info"
    } else if (grepl("ADK_WCT", basename(wetland_file))) {
        sourceWetlands <- "ADK_WCT"
    } else if (grepl("ADK_regulated", basename(wetland_file))) {
        sourceWetlands <- "ADK_regulated"
    } else {
        sourceWetlands <- sub(
            "_.*",
            "",
            tools::file_path_sans_ext(basename(wetland_file))
        )
    }
    message(sourceWetlands)
    huc_num <- str_extract(wetland_file, "(?<=huc_)\\d+")
    huc_poly <- sf::st_read(
        "Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg",
        quiet = TRUE,
        query = paste0(
            "SELECT * FROM NY_Cluster_Zones_250_CROP_NAomit_6347 WHERE huc12 = '",
            huc_num,
            "'"
        )
    )
    if (nrow(huc_poly) == 0) {
        message("HUC ", huc_num, " not in cluster gpkg, skipping")
        return(invisible(NULL))
    }
    huc_geom <- st_union(huc_poly)
    target_wetlands <- st_read(wetland_file, quiet = TRUE) |> # target wetlands
        filter(MOD_CLASS != "OWW")
    if (classScheme == "BINARY") {
        target_wetlands <- target_wetlands |>
            mutate(MOD_CLASS = if_else(MOD_CLASS == "UPL", "UPL", "WET"))
    }
    tw_geom <- st_geometry(target_wetlands)

    ## 1. one guaranteed-interior point per polygon (centroids can fall outside)
    pt_surface <- st_point_on_surface(tw_geom)

    ## 2. points along every ring; rings shorter than the spacing are covered by 1.
    tw_rings <- st_boundary(tw_geom) |>
        st_cast("MULTILINESTRING") |>
        st_cast("LINESTRING")
    tw_rings <- tw_rings[as.numeric(st_length(tw_rings)) >= boundarySpacing]
    pt_boundary <- st_line_sample(tw_rings, density = 1 / boundarySpacing) |>
        st_cast("POINT")

    ## 3. regular grid inside polygons, offset randomly so it isn't HUC-aligned
    grid_offset <- st_bbox(huc_geom)[c("xmin", "ymin")] -
        runif(2, 0, interiorSpacing)
    pt_grid <- st_make_grid(
        huc_geom,
        cellsize = interiorSpacing,
        offset = grid_offset,
        what = "centers"
    )
    pt_grid <- pt_grid[lengths(st_intersects(pt_grid, tw_geom)) > 0]

    shuffle <- function(x) x[sample(length(x))]
    cand <- c(shuffle(pt_surface), shuffle(pt_boundary), shuffle(pt_grid))
    cand_box <- st_buffer(cand, dist = patchSize, endCapStyle = "SQUARE")
    in_huc <- lengths(st_within(cand_box, huc_geom)) > 0
    cand <- cand[in_huc]
    keep <- thin_boxes(st_coordinates(cand), boxSide)

    message(
        basename(wetland_file),
        ": candidates surface/boundary/grid = ",
        length(pt_surface),
        "/",
        length(pt_boundary),
        "/",
        length(pt_grid),
        "; inside HUC = ",
        length(cand),
        "; kept patches = ",
        sum(keep)
    )

    target_wetlands_uplands <- target_wetlands
    # Stamp an integer patch identifier onto each 256 m box (one row = one patch)
    # so every polygon split out of the box below inherits the same PatchGroup.
    tw_bl_c_cmbbuff_o <- st_sf(
        geom = st_buffer(cand[keep], dist = patchSize, endCapStyle = "SQUARE")
    ) |>
        dplyr::mutate(MOD_CLASS = "UPL", PatchGroup = dplyr::row_number())
    tw_intersection <- st_intersection(
        target_wetlands_uplands,
        tw_bl_c_cmbbuff_o
    ) |>
        dplyr::select(MOD_CLASS, PatchGroup, geom)
    tu_intersection <- st_difference(
        tw_bl_c_cmbbuff_o,
        st_union(target_wetlands_uplands)
    ) |>
        dplyr::select(MOD_CLASS, PatchGroup, geom)
    cmb_tutw <- bind_rows(tw_intersection, tu_intersection) |>
        mutate(
            ReviewerName = "TBD",
            Confidence = -999,
            BoundariesAltered = NA,
            Comments = "NoComment"
        ) |>
        st_cast(to = "MULTIPOLYGON") |>
        dplyr::select(
            ReviewerName,
            Confidence,
            BoundariesAltered,
            Comments,
            MOD_CLASS,
            PatchGroup
        )

    fn_full_patch <- paste0(
        "Data/Training_Data/R_Patches_Vector/",
        sourceWetlands,
        "_cluster_",
        clusterTarget,
        "_huc_",
        huc_num,
        "_",
        patchSize * 2,
        "m",
        if (classScheme == "BINARY") "_BINARY" else "",
        ".gpkg"
    )
    if (!file.exists(fn_full_patch)) {
        st_write(cmb_tutw, dsn = fn_full_patch, append = FALSE)
    } else {
        message("Already file ", fn_full_patch)
    }
    return(cmb_tutw)
    # #### Vector polygon patches
    #
    # for(i in seq_len(nrow(tw_bl_c_cmbbuff_o))){
    #     fn_vector <- paste0("Data/Training_Data/R_Patches_Vector/individual_patches/", sourceWetlands,"_cluster_", clusterTarget, "_huc_", huc_num, "_patch_", i, "_", patchSize*2, "m.gpkg" )
    #     if(!file.exists(fn_vector)){
    #         wet_patch <-  st_intersection(target_wetlands_uplands, tw_bl_c_cmbbuff_o[i,])
    #         st_geometry(wet_patch) <- "geom"
    #         upl_patch <- st_difference(tw_bl_c_cmbbuff_o[i,] |>
    #                                    mutate(MOD_CLASS = "UPL"),
    #                                st_union(target_wetlands_uplands))
    #         st_geometry(upl_patch) <- "geom"
    #         wetupl_patch <- bind_rows(wet_patch, upl_patch) |>
    #         mutate(ReviewerName = "TBD",
    #                Confidence = -999,
    #                BoundariesAltered = NA,
    #                Comments = "NoComment") |>
    #             st_cast(to = "POLYGON") |>
    #         dplyr::select(ReviewerName, Confidence, BoundariesAltered, Comments, MOD_CLASS)
    #
    #         st_write(wetupl_patch, dsn = fn_vector, append = FALSE)
    #
    #         # if(!file.exists(logpath)){
    #         #     logfile <- read_csv(logpath, show_col_types = FALSE)
    #         #     fn_to_add <- logfile |> filter(patch_file_name == basename(fn_vector))
    #         #     if(nrow(fn_to_add) == 0){
    #         #         fn_to_add_row <- data.frame(patch_file_name = basename(fn_vector),
    #         #                                 reviewer = "NAME",
    #         #                                 boundaries_altered = "TBD",
    #         #                                 confidence = "TBD")
    #         #         # update_logfile <- bind_rows(fn_to_add_row, logfile)
    #         #         write_csv(fn_to_add_row, logpath, append = TRUE)
    #         #         } else {
    #         #             message("Filename in log file")
    #         #         }
    #         #     }
    #
    #     } else {
    #     message("Already file ", fn_vector)
    #         }
    #    }
    #
    # fn_full_patch <- paste0("Data/Training_Data/R_Patches_Vector/", sourceWetlands,"_cluster_", clusterTarget, "_huc_", huc_num, "_", patchSize*2, "m.gpkg" )
    # if(!file.exists(fn_full_patch)){
    #     full_patch_file <- list.files("Data/Training_Data/R_Patches_Vector/individual_patches/",
    #                                   full.names = TRUE,
    #                                   pattern = paste0("_cluster_", clusterTarget, "_huc_", huc_num, "_", "patch.*\\.gpkg$")) |>
    #         purrr::map(st_read, quiet = TRUE) |>
    #         bind_rows()
    #     st_write(full_patch_file,
    #              dsn =  paste0("Data/Training_Data/R_Patches_Vector/", sourceWetlands,"_cluster_", clusterTarget, "_huc_", huc_num, "_", patchSize*2, "m.gpkg" ),
    #              append = FALSE)
    # } else {
    #     # full_patch_file <- list.files("Data/Training_Data/R_Patches_Vector/",
    #     #                               full.names = TRUE,
    #     #                               pattern = paste0("_cluster_", clusterTarget, "_huc_", huc_num, "_", "patch.*\\.gpkg$")) |>
    #     #     purrr::map(st_read, quiet = TRUE) |>
    #     #     bind_rows()
    #     # st_write(full_patch_file,
    #     #          dsn =  paste0("Data/Training_Data/R_Patches_Vector/", sourceWetlands,"_cluster_", clusterTarget, "_huc_", huc_num, "_", patchSize*2, "m.gpkg" ),
    #     #          append = FALSE)
    #     message("Already file")
    # }
    #
    # return(NULL)
}


### Parallel
slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
    corenum <- as.integer(slurm_cpus)
} else {
    corenum <- min(future::availableCores(), 4)
}

print(corenum)
options(future.globals.maxSize = 32.0 * 1e9)
# plan(multisession, workers = corenum)
plan(future.callr::callr)

future_lapply(
    l_wet_cluster,
    vect_chip_patch_create,
    future.seed = TRUE,
    future.packages = c("terra", "sf", "dplyr", "tidyr", "stringr", "purrr"),
    future.globals = TRUE
)

### Non-parallel
# system.time({t <- lapply(l_wet_cluster, vect_chip_patch_create)})

#### Checks
# l_patches <- list.files("Data/Training_Data/R_Patches_Vector")
#
# check_df <- data.frame(patch_file_name = l_patches,
#                        reviewer = rep("NAME", length(l_patches)),
#                        boundaries_altered = rep("TBD", length(l_patches)),
#                        confidence = rep("TBD", length(l_patches)))
#
# readr::write_csv(check_df, "Data/Training_Data/R_Patches_Vector/Vector_Patch_Checklist.csv")
#
# list_patches <- list.files("Data/Training_Data/R_Patches_Labels/", full.names = T)
# lapply(list_patches, \(x) rast(x))
# lp <- lapply(list_patches, FUN = \(x) {rast(x) |> nlyr()}) |> unlist()
# # lapply(list_patches, FUN = \(x) {rast(x) |> nlyr()}) |> unlist() |> table()
#
# le <- lapply(list_patches, FUN = \(x) {rast(x, lyrs = "MOD_CLASS") |> values() |> unique() |> nrow()}) |> unlist()
#
# list_patches[le == 1]
# list_patches[lp < 27]
