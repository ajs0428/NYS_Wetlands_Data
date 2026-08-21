### Image chips/patches for DL

library(terra)
library(sf)
library(dplyr)
library(tidyr)
library(stringr)
library(tidyterra)
library(readr)
library(future)
library(future.apply)

source("R_Code_Analysis/huc_stack.R") # shared in-memory stack recipe
source("R_Code_Analysis/patch_groups.R") # shared PatchGroup cleaning/filter contract

set.seed(11)

########################################################################################

args <- c(
    "Data/Training_Data/R_Patches_Vector_NWIextra/", #Path to wetland vector patches
    128, # patch size 1/2
    11 # cluster subset options include number or NULL for any
)

args <- commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

patchPath <- args[1]
patchSize <- args[2]
clusterSubset <- args[3]

# Force a rebuild of already-written patches. Set via the REMOVE_EXISTING env
# var (the .sh exports it) or as a 4th positional arg, which wins if given.
# Needed when the source vector data changed: without it every existing .tif is
# skipped by the file.exists() guard below, so edits never reach the rasters.
parse_flag <- function(x) {
    tolower(trimws(x)) %in% c("1", "true", "t", "yes", "y")
}
removeExisting <- if (length(args) >= 4 && nzchar(args[4])) {
    parse_flag(args[4])
} else {
    parse_flag(Sys.getenv("REMOVE_EXISTING", ""))
}

message(
    "these are the arguments: \n",
    "1) path the reviewed training data :",
    patchPath,
    "\n",
    "2) patch size :",
    patchSize,
    "\n",
    "3) cluster number :",
    clusterSubset,
    "\n",
    "4) remove existing patches :",
    removeExisting,
    "\n"
)


setGDALconfig("GDAL_PAM_ENABLED", "FALSE") # does not create aux.xml files but maybe needed
########################################################################################
l_wet <- list.files(patchPath, pattern = ".gpkg$", full.names = TRUE)
l_wet_cluster_nums <- sub(".*cluster_(\\d+).*", "\\1", l_wet) |> unique()
l_wet_extracted_clusters <- sub(".*cluster_(\\d+)_.*", "\\1", l_wet)
l_wet_cluster <- l_wet[grepl(paste0("cluster_", clusterSubset, "_"), l_wet)]
print(l_wet_cluster)

########################################################################################
# fct_df <- data.frame(ID = 0:4, MOD_CLASS = c("EMW", "FSW", "OWW", "SSW", "UPL"))
fct_df <- data.frame(ID = 0:3, MOD_CLASS = c("EMW", "FSW", "SSW", "UPL"))
patchsize <- as.numeric(patchSize)
########################################################################################
set.seed(420)

rast_chip_patch_create_one <- function(wetland_file) {
    setGDALconfig("GDAL_PAM_ENABLED", "FALSE")
    source("R_Code_Analysis/huc_stack.R") # ensure recipe is available in callr workers
    source("R_Code_Analysis/patch_groups.R") # ditto for the PatchGroup contract
    # Cap terra + GDAL memory well below the per-task cgroup (TASK_MEM_MB =
    # mem-per-cpu * cpus-per-task, exported by the .sh, shared across callr
    # workers). terra and the GDAL block cache otherwise size off total node RAM
    # (~251G), not the SLURM allocation, and the worker gets OOM-killed against
    # the cgroup. GDAL_CACHEMAX is in MB; terra memmax is in GB.
    task_mem_mb <- suppressWarnings(as.numeric(Sys.getenv("TASK_MEM_MB", "0")))
    if (is.na(task_mem_mb) || task_mem_mb <= 0) {
        task_mem_mb <- 20000
    } # interactive fallback
    Sys.setenv(GDAL_CACHEMAX = as.character(round(task_mem_mb * 0.10))) # ~10% of budget
    terraOptions(
        memmax = max(2, (task_mem_mb / 1024) * 0.4),
        memfrac = 0.3,
        tempdir = "Data/tmp"
    )
    ## Setup vars
    if (grepl("NWI", basename(wetland_file))) {
        sourceWetlands <- "NWI"
    } else if (grepl("NHP", basename(wetland_file))) {
        sourceWetlands <- "NHP"
    } else if (grepl("Laba", basename(wetland_file))) {
        sourceWetlands <- "Info"
    } else {
        sourceWetlands <- sub(
            "_.*",
            "",
            tools::file_path_sans_ext(basename(wetland_file))
        )
    }
    patchsize <- as.numeric(patchSize)
    huc_num <- str_extract(wetland_file, "(?<=huc_)\\d+")
    cluster_num <- str_extract(wetland_file, "(?<=cluster_)\\d+")
    message("HUC num: ", huc_num)
    # A filename missing the literal _huc_ (or _cluster_) separator leaves these
    # NA, which used to travel all the way into huc_source_paths() and blow up
    # with "missing value where TRUE/FALSE needed" -- taking the whole cluster's
    # future_lapply down with it. Name the offending file and skip it instead.
    if (is.na(huc_num) || is.na(cluster_num)) {
        message(
            "Cannot parse cluster/HUC from ", basename(wetland_file),
            " (expected <tag>_cluster_<N>_huc_<HUCID>_...) - skipping"
        )
        return(invisible(NULL))
    }
    if (cluster_num != clusterSubset & !is.null(clusterSubset)) {
        message("skip this cluster and huc, selecting cluster: ", clusterSubset)
        return(invisible(NULL))
    } else if (cluster_num != clusterSubset & is.null(clusterSubset)) {
        message("Processing for all clusters in folder")
    }

    ## Resolve the per-HUC source rasters (lazy pointers). The stack is built
    ## in memory per patch below via build_huc_stack_patch() -- no *_stack.tif
    ## is read or written, so source rasters are never duplicated on disk.
    paths <- huc_source_paths(huc_num, cluster_num)
    if (!huc_sources_ready(paths, huc_num)) {
        message(
            "Skipping HUC ",
            huc_num,
            ": one or more source datasets missing"
        )
        return(invisible(NULL))
    }

    ### Split the polygons into per-patch groups using the PatchGroup id that
    ### Vector_ChipsPatches_DL.R stamps onto each 256 m square (and that
    ### NWI_Extract_From_Patches.R propagates into the NWI patches). Grouping
    ### by PatchGroup -- rather than re-deriving patches via st_union() ->
    ### connected components -- keeps a given PatchGroup mapped to the SAME
    ### geographic square in both the field-annotated and NWI runs, so the two
    ### sets get shared _patch_<PatchGroup>_ filenames.
    # Read exactly the file this iteration was handed. Re-globbing by huc_num +
    # sourceWetlands returned >1 path when a HUC has multiple reviewed gpkgs
    # (e.g. cluster_225 huc_042900050201), which st_read cannot take -> crash.
    tw <- st_read(wetland_file, quiet = TRUE)
    # Drop empties, repair invalid geometry, keep polygonal parts, explode
    # multi-part features. See patch_groups.R for why each step is there --
    # Check_Patch_Vectors.R runs the identical code, so its report predicts
    # exactly what this loop will write.
    cleaned <- clean_patch_vector(tw)
    if (cleaned$n_empty > 0) {
        message(
            "Dropping ", cleaned$n_empty, " empty geometry/geometries in ",
            basename(wetland_file)
        )
    }
    if (is.null(cleaned$sf)) {
        message(
            "Skipping ", basename(wetland_file), ": ", cleaned$note
        )
        return(invisible(NULL))
    }
    tw_valid <- cleaned$sf
    tw_valid$MOD_CLASS[tw_valid$MOD_CLASS == "OWW"] <- "UPL"
    if (any(grepl(pattern = "OWW", unique(tw_valid$MOD_CLASS)))) {
        message("OWW Detected, exiting")
        return(invisible(NULL))
    }
    # Patches without PatchGroup (e.g. the skipped overlapping gps_jc HUCs) can't
    # be split per-patch into shared-named outputs, so skip the whole file.
    if (!"PatchGroup" %in% names(tw_valid)) {
        message(
            "No PatchGroup column in ",
            basename(wetland_file),
            " - skipping"
        )
        return(invisible(NULL))
    }
    # NA PatchGroups cannot name an output raster (and `NA %in% NA` is TRUE in R,
    # so they used to slip through the filters below silently) -- see
    # patch_groups.R.
    na_drop <- drop_na_patch_groups(tw_valid)
    tw_valid <- na_drop$sf
    if (na_drop$n_na > 0) {
        message(
            "Dropping ", na_drop$n_na, " polygon(s) with NA PatchGroup in ",
            basename(wetland_file)
        )
    }
    if (nrow(tw_valid) == 0) {
        message(
            "No polygons with a usable PatchGroup in ",
            basename(wetland_file), " - skipping"
        )
        return(invisible(NULL))
    }
    # Per-PatchGroup summed area AND bounding box -- both gate a group; see
    # patch_groups.R for the thresholds and the failure modes each one catches.
    side <- patchsize * 2
    patch_area <- patch_group_summary(tw_valid)
    cls <- classify_patch_groups(patch_area, side)
    keep_groups <- cls$keep
    small <- cls$small
    if (nrow(small) > 0) {
        message(
            "Dropping ", nrow(small), " PatchGroup(s) below area threshold in ",
            basename(wetland_file), ": ",
            paste0(small$PatchGroup, " (", round(small$area), " m2)", collapse = ", ")
        )
    }
    oversize <- cls$oversize
    if (nrow(oversize) > 0) {
        message(
            "Dropping ", nrow(oversize), " PatchGroup(s) whose bbox is not one ",
            side, " m square in ", basename(wetland_file),
            " (id reused across separated patches?): ",
            paste0(
                oversize$PatchGroup, " (", round(oversize$w), " x ",
                round(oversize$h), " m)",
                collapse = ", "
            )
        )
    }
    tw_grouped_list <- tw_valid |>
        dplyr::filter(as.character(PatchGroup) %in% keep_groups) %>%
        dplyr::filter(st_is_valid(.)) |>
        dplyr::group_split(PatchGroup)

    # Output folder mirrors the vector source folder (see the fn build below).
    out_dir <- if (
        str_detect(patchPath, pattern = "R_Patches_Vector_NWIextra/?$")
    ) {
        "Data/Training_Data/R_Patches_NWIextra/"
    } else if (str_detect(patchPath, pattern = "R_Patches_Vector_NWI/?$")) {
        "Data/Training_Data/R_Patches_NWI/"
    } else {
        "Data/Training_Data/R_Patches/"
    }

    # Label by the full source-file prefix (text before _cluster_), used for
    # BOTH outputs so names line up: the NWI vector file is named
    # "NWI_<reviewed-basename>", so its file_tag is exactly "NWI_" + the
    # reviewed file's file_tag. Combined with the shared patch_group this makes
    # every NWI raster == "NWI_" + its field-annotated counterpart's name
    # (and a source-NWI patch becomes NWI_NWI_*). Using the full prefix also
    # keeps a HUC's multiple reviewed gpkgs (NWI_ADK_WCT_AJS vs NWI_NWI_AJS)
    # from colliding.
    file_tag <- sub(
        "_cluster_.*$",
        "",
        tools::file_path_sans_ext(basename(wetland_file))
    )
    # The literal _huc_ separator keeps cluster 12 from matching cluster 120;
    # scoping by file_tag keeps one gpkg from wiping a sibling gpkg's patches.
    fn_prefix <- paste0(
        file_tag, "_cluster_", cluster_num, "_huc_", huc_num, "_patch_"
    )

    # REMOVE_EXISTING: wipe this HUC's previously written patches so changed
    # vector data is fully re-rasterized. Done as a sweep (not just
    # overwrite=TRUE) so PatchGroups that no longer exist in the new vector file
    # don't survive as stale rasters. Deliberately placed AFTER the
    # source-ready / PatchGroup / area filtering above -- a HUC that is being
    # skipped keeps its existing patches rather than losing them to a transient
    # missing input. Note this cannot clean up a HUC whose vector file was
    # deleted outright, since that file is never iterated over.
    if (removeExisting) {
        stale <- list.files(out_dir, full.names = TRUE)
        stale <- stale[startsWith(basename(stale), fn_prefix)]
        if (length(stale) > 0) {
            message(
                "REMOVE_EXISTING: deleting ", length(stale),
                " existing patch file(s) for ", fn_prefix
            )
            file.remove(stale)
        }
    }

    #### Each patch should be a separate file that is patchsize*2 x patchsize*2
    # Build the lazy source layers ONCE for this HUC and reuse them across every
    # patch. build_huc_stack_patch() otherwise re-opens all 7 sources and
    # recomputes log(flowacc) over the whole HUC per patch (18-31x on big HUCs),
    # accumulating full-HUC allocations that OOM-kill under the per-task cgroup.
    huc_lyrs <- if (length(tw_grouped_list) > 0) huc_layers(paths) else NULL
    for (i in seq_along(tw_grouped_list)) {
        # message("The number is ", i)
        skip_to_next <- FALSE
        tw_vect <- vect(tw_grouped_list[[i]])
        # PatchGroup is constant within a group -- this is the shared per-patch id.
        patch_group <- tw_grouped_list[[i]]$PatchGroup[1]

        tryCatch(
            {
                fn <- paste0(
                    out_dir,
                    fn_prefix,
                    patch_group,
                    "_",
                    patchsize * 2,
                    "m.tif"
                )

                if (!file.exists(fn)) {
                    # Build the predictor stack for just this patch window, in memory.
                    stack <- build_huc_stack_patch(
                        paths,
                        tw_vect,
                        lyrs = huc_lyrs
                    )
                    dem_crop <- stack[["DEM"]]

                    tw_rast <- tw_vect |>
                        terra::rasterize(
                            y = dem_crop,
                            field = "MOD_CLASS",
                            touches = TRUE
                        )
                    tw_rast_lc <- levels(tw_rast)[[1]][[2]] #character vector of levels present
                    tw_rast_ln <- levels(tw_rast)[[1]][[1]] #numbers/integers of levels present
                    fct_n <- fct_df[fct_df$MOD_CLASS %in% tw_rast_lc, ][, 1] # subset the levels present from the full factor dataframe
                    tw_rast_sub <- subst(
                        tw_rast,
                        from = tw_rast_ln,
                        to = fct_n,
                        raw = TRUE
                    )
                    levels(tw_rast_sub) <- fct_df

                    # fn_labels <- paste0("Data/Training_Data/R_Patches_Labels/", "labels_only_", sourceWetlands, "_cluster_", cluster_num, "_huc_", huc_num, "_patch_", i, "_", patchsize*2, "m.tif" )

                    # Regular Patches with all predictors

                    tryCatch(
                        {
                            cropped_stack_labeled <- c(stack, tw_rast_sub)
                            writeRaster(
                                cropped_stack_labeled,
                                filename = fn,
                                overwrite = TRUE
                            )
                        },
                        error = function(e) {
                            message(
                                "Excluding patch ", patch_group, " (", fn,
                                "): failed to write stack: ",
                                conditionMessage(e)
                            )
                            skip_to_next <<- TRUE
                        }
                    )
                    if (skip_to_next) {
                        next
                    }
                } else {
                    # This patch already exists -- skip ONLY this one and keep going.
                    # (Was return(invisible(NULL)), which exited the WHOLE HUC: on any
                    # resume of a partially-written HUC it stopped at patch_1 and
                    # dropped patches 2..N, truncating that HUC's output.)
                    message("Already file ", fn)
                }
            },
            # Patches inside the HUC boundary but outside the DEM/other source
            # rasters land here (e.g. "[crop] extents do not overlap") -- exclude
            # the patch, say which one, and keep going.
            error = function(e) {
                message(
                    "Excluding patch ", patch_group, " of ",
                    basename(wetland_file), ": ", conditionMessage(e)
                )
                return(invisible(NULL))
            }
        )
    }

    return(NULL)
}

# future_lapply has no per-element error handling: any error escaping the worker
# prints "Caught simpleError. Canceling all iterations ..." and halts the whole
# Rscript, so every gpkg after the bad one in this cluster is never (re)generated
# and its stale rasters survive untouched (REMOVE_EXISTING never reaches them).
# On 2026-08-12 two malformed files wiped out all of cluster 208 and cluster 225
# that way. Contain the blast radius to the one file, and name it in the log.
rast_chip_patch_create <- function(wetland_file) {
    tryCatch(
        rast_chip_patch_create_one(wetland_file),
        error = function(e) {
            message(
                "SKIPPING ", basename(wetland_file),
                " - unhandled error: ", conditionMessage(e)
            )
            invisible(NULL)
        }
    )
}

### Non-parallel
# system.time({lapply(l_wet_cluster, rast_chip_patch_create)})
#
# l_dem_cluster[[1]] |> rast() |> plot()
# l_hydro_cluster[[1]] |> rast() |> plot()
# l_chm_cluster[[1]] |> rast() |> plot()
# l_naip_cluster[[1]] |> rast() |> plot()
# l_sat_cluster[[1]] |> rast() |> plot()

### Parallel

slurm_cpus <- Sys.getenv("SLURM_CPUS_PER_TASK", unset = "")

if (nzchar(slurm_cpus)) {
    corenum <- as.integer(slurm_cpus)
} else {
    corenum <- min(future::availableCores(), 4)
}

print(corenum)
options(future.globals.maxSize = 48.0 * 1e9)
# plan(multisession, workers = corenum)
plan(future.callr::callr, workers = corenum)

future_lapply(
    l_wet_cluster,
    rast_chip_patch_create,
    future.seed = TRUE,
    future.packages = c("terra", "sf", "dplyr", "tidyr", "stringr", "purrr"),
    future.globals = TRUE
    # future.globals = list(
    #   l_chm_cluster = l_chm_cluster,
    #   l_dem_cluster = l_dem_cluster,
    #   l_lidar_cluster = l_lidar_cluster,
    #   l_sat_cluster = l_sat_cluster,
    #   l_terr_cluster = l_terr_cluster,
    #   l_hydro_cluster = l_hydro_cluster,
    #   args = args,
    #   fct_df = fct_df
    # )
)

### Checks
# l_patches <- list.files("Data/Training_Data/R_Patches_Vector")
#
# check_df <- data.frame(patch_file_name = l_patches,
#                        reviewer = rep("NAME", length(l_patches)),
#                        boundaries_altered = rep("TBD", length(l_patches)),
#                        confidence = rep("TBD", length(l_patches)))
#
# readr::write_csv(check_df, "Data/Training_Data/R_Patches_Vector/Vector_Patch_Checklist.csv")
# ### Checks
# list_patches <- list.files("Data/Training_Data/R_Patches_Labels/", full.names = T)
# lapply(list_patches, \(x) rast(x))
# lp <- lapply(list_patches, FUN = \(x) {rast(x) |> nlyr()}) |> unlist()
# # lapply(list_patches, FUN = \(x) {rast(x) |> nlyr()}) |> unlist() |> table()
#
# le <- lapply(list_patches, FUN = \(x) {rast(x, lyrs = "MOD_CLASS") |> values() |> unique() |> nrow()}) |> unlist()
#
# list_patches[le == 1]
# list_patches[lp < 27]
