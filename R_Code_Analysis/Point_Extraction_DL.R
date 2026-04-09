### Generate points within vector patches and extract predictor data from raster stacks

library(terra)
library(sf)
library(dplyr)
library(tidyr)
library(stringr)
library(readr)
library(future)
library(future.apply)

set.seed(11)

########################################################################################

args <- c(
    "Data/Training_Data/R_Patches_Vector/", # Path to vector patches
    10, # point spacing in meters (grid cell size for regular sampling)
    208 # cluster subset: number or NULL for all
)

args = commandArgs(trailingOnly = TRUE)

patchPath <- args[1]
pointSpacing <- as.numeric(args[2])
clusterSubset <- args[3]

message("these are the arguments: \n",
    "1) path to vector patches: ", patchPath, "\n",
    "2) point spacing (m): ", pointSpacing, "\n",
    "3) cluster number: ", clusterSubset, "\n"
)

setGDALconfig("GDAL_PAM_ENABLED", "FALSE")

########################################################################################
## List and filter patch files by cluster
l_patches <- list.files(patchPath, pattern = "\\.gpkg$", full.names = TRUE)
l_patches_cluster <- l_patches[grepl(paste0("cluster_", clusterSubset, "_"), l_patches)]
print(l_patches_cluster)

## List raster stacks
l_stacks <- list.files("Data/HUC_Raster_Stacks/HUC_DL_Stacks/",
                        pattern = "\\.tif$", full.names = TRUE)
l_stacks_cluster <- l_stacks[grepl(paste0("cluster_", clusterSubset, "_"), l_stacks)]

## Output directory
outDir <- "Data/Training_Data/Point_Extractions/"
if (!dir.exists(outDir)) dir.create(outDir, recursive = TRUE)

########################################################################################

point_extract_fun <- function(patch_file) {
    setGDALconfig("GDAL_PAM_ENABLED", "FALSE")

    ## Parse identifiers from filename
    huc_num <- str_extract(patch_file, "(?<=huc_)\\d+")
    cluster_num <- str_extract(patch_file, "(?<=cluster_)\\d+")
    source_name <- sub("_cluster_.*", "", basename(patch_file))

    message("Processing: cluster ", cluster_num, " | HUC ", huc_num, " | source ", source_name)

    ## Read polygon patches
    polys <- tryCatch(
        st_read(patch_file, quiet = TRUE),
        error = function(e) {
            message("Error reading ", patch_file, ": ", conditionMessage(e))
            return(NULL)
        }
    )
    if (is.null(polys) || nrow(polys) == 0) {
        message("No features in ", basename(patch_file), ", skipping.")
        return(NULL)
    }

    ## Ensure valid geometries
    polys <- polys[st_is_valid(polys), ]
    if (nrow(polys) == 0) {
        message("No valid geometries in ", basename(patch_file), ", skipping.")
        return(NULL)
    }

    ## Find matching raster stack
    stack_match <- l_stacks_cluster[grepl(huc_num, l_stacks_cluster) &
                                     grepl(paste0("cluster_", cluster_num), l_stacks_cluster)]

    if (length(stack_match) == 0) {
        message("No matching raster stack for cluster ", cluster_num, " HUC ", huc_num, ", skipping.")
        return(NULL)
    }
    if (length(stack_match) > 1) {
        message("Multiple stack matches found, using first: ", stack_match[1])
        stack_match <- stack_match[1]
    }

    stack_rast <- tryCatch(
        rast(stack_match),
        error = function(e) {
            message("Error loading raster stack: ", conditionMessage(e))
            return(NULL)
        }
    )
    if (is.null(stack_rast)) return(NULL)

    ## Generate regular grid points within each polygon
    ## st_sample with type = "regular" creates a grid; points outside polygons are excluded
    pts <- tryCatch({
        pts_sf <- st_sample(polys, size = ceiling(as.numeric(st_area(st_union(polys))) / (pointSpacing^2)),
                            type = "regular")
        pts_sf <- st_as_sf(pts_sf)
        st_geometry(pts_sf) <- "geometry"
        pts_sf
    }, error = function(e) {
        message("Error generating points: ", conditionMessage(e))
        return(NULL)
    })

    if (is.null(pts) || nrow(pts) == 0) {
        message("No points generated for ", basename(patch_file), ", skipping.")
        return(NULL)
    }

    message("Generated ", nrow(pts), " points within patches")

    ## Ensure points are within polygons (safety intersection)
    pts <- st_intersection(pts, st_union(polys))
    pts <- st_as_sf(pts)
    if (nrow(pts) == 0) {
        message("No points after intersection, skipping.")
        return(NULL)
    }

    ## Extract raster values at point locations
    pts_vect <- vect(pts)
    extracted_vals <- tryCatch(
        terra::extract(stack_rast, pts_vect),
        error = function(e) {
            message("Error extracting raster values: ", conditionMessage(e))
            return(NULL)
        }
    )

    if (is.null(extracted_vals)) return(NULL)

    ## Spatial join to get polygon attributes (e.g., MOD_CLASS) at each point
    pts_with_class <- st_join(pts, polys, join = st_intersects, left = FALSE)

    ## Combine coordinates, polygon attributes, and extracted raster values
    coords <- st_coordinates(pts_with_class)
    result_df <- bind_cols(
        pts_with_class |> st_drop_geometry(),
        as.data.frame(coords),
        extracted_vals |> dplyr::select(-ID)
    )
    result_df$huc <- huc_num
    result_df$cluster <- cluster_num
    result_df$source <- source_name

    ## Remove rows with all NA predictor values
    predictor_cols <- names(extracted_vals)[names(extracted_vals) != "ID"]
    result_df <- result_df |> filter(!if_all(all_of(predictor_cols), is.na))

    ## Write output
    out_fn <- paste0(outDir, source_name, "_cluster_", cluster_num,
                     "_huc_", huc_num, "_points.csv")
    write_csv(result_df, out_fn)

    ## Also save as geopackage for spatial reference
    out_gpkg <- paste0(outDir, source_name, "_cluster_", cluster_num,
                       "_huc_", huc_num, "_points.gpkg")
    pts_result <- st_as_sf(pts_with_class)
    pts_result <- bind_cols(pts_result, extracted_vals |> dplyr::select(-ID))
    pts_result$huc <- huc_num
    pts_result$cluster <- cluster_num
    pts_result$source <- source_name
    ## Filter NA rows from spatial output as well
    pts_result <- pts_result |> filter(!if_all(all_of(predictor_cols), is.na))
    st_write(pts_result, out_gpkg, delete_dsn = TRUE, quiet = TRUE)

    message("Wrote ", nrow(result_df), " points to ", basename(out_fn))

    return(out_fn)
}

########################################################################################
### Parallel execution

slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
  corenum <- as.integer(slurm_cpus)
} else {
  corenum <- min(future::availableCores(), 4)
}

print(corenum)
options(future.globals.maxSize = 32.0 * 1e9)
plan(future.callr::callr)

results <- future_lapply(l_patches_cluster, point_extract_fun,
              future.seed = TRUE,
              future.packages = c("terra", "sf", "dplyr", "tidyr", "stringr", "readr"),
              future.globals = TRUE
              )

message("Completed point extraction for cluster ", clusterSubset)
message("Output files: ", paste(unlist(results[!sapply(results, is.null)]), collapse = "\n"))
