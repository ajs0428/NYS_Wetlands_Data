#!/usr/bin/env Rscript

###################
# This script creates HUC12 Height Above Nearest Drainage (HAND) from existing
# hydroconditioned DTMs named with 'wbt' in Data/TerrainProcessed/HUC_DEM_Hydro/
# and existing Flow Accumulation in the Data/TerrainProcessed/HUC_Hydro/ folder
# band named flowacc
#
# Per HUC:
#   1. streams = flowacc >= threshold, plus the outlet cells where flow leaves
#      the HUC (WhiteboxTools D8Pointer == 0), so every cell drains somewhere
#   2. HAND    = WhiteboxTools ElevationAboveStream(hydro DEM, streams)
#   3. HAND rewritten as compressed Float32 with band name "hand"
#
# Works on a set of clusters ("all" or a comma list) and every HUC12 in them.
# Optionally takes a slice id/count so a SLURM job array can split the HUC list
# (see Shell_Scripts/step_hand.sh). Resumable: HUCs whose HAND exists are skipped.
###################

args <- c(
  "12", # cluster(s): "all" or comma list e.g. "12,64"
  "Data/TerrainProcessed/HUC_DEM_Hydro/",
  "Data/TerrainProcessed/HUC_Hydro/",
  "Data/TerrainProcessed/HUC_HAND/",
  "Data/TerrainProcessed/HUC_Streams/",
  500000, # flowacc threshold in cells (1 m cells -> 0.5 km2), same statewide
  1, # slice id   (SLURM_ARRAY_TASK_ID)
  1 # slice count (SLURM_ARRAY_TASK_COUNT)
)

args <- commandArgs(trailingOnly = TRUE) # arguments are passed from terminal to here

arg_or <- function(i, default) {
  if (length(args) >= i && nzchar(args[i])) args[i] else default
}

clusterSpec <- args[1]
hydrodemFolder <- args[2]
hydroFolder <- args[3]
handFolder <- args[4]
streamsFolder <- arg_or(5, "Data/TerrainProcessed/HUC_Streams/")
streamThreshold <- as.numeric(arg_or(6, 500000))
sliceId <- as.integer(arg_or(7, 1))
sliceCount <- as.integer(arg_or(8, 1))

cat(
  "these are the arguments: \n",
  "- Cluster number(s) ('all' or comma list):",
  clusterSpec,
  "\n",
  "- Path to the Hydro Processed DEMs in TerrainProcessed folder",
  hydrodemFolder,
  "\n",
  "- Path to the Hydro metrics folder with flow accumulation",
  hydroFolder,
  "\n",
  "- Path to save HAND folder:",
  handFolder,
  "\n",
  "- Path to save stream rasters:",
  streamsFolder,
  "\n",
  "- Flow accumulation stream threshold (cells):",
  streamThreshold,
  "\n",
  "- Slice:",
  sliceId,
  "of",
  sliceCount,
  "\n"
)

stopifnot(
  !is.na(streamThreshold),
  !is.na(sliceId),
  !is.na(sliceCount),
  sliceId >= 1,
  sliceId <= sliceCount
)

###############################################################################################

library(terra)
library(stringr)
library(whitebox)

# terra cap derived from the SLURM per-task budget (step_hand.sh exports
# TASK_MEM_MB). terra only does the streamed threshold + Float32 rewrite here;
# WhiteboxTools is an external process that ignores this cap and holds the DEM,
# streams, D8 pointer and output in RAM, so terra gets a small share.
.task_mem_gb <- as.numeric(Sys.getenv("TASK_MEM_MB", "0")) / 1024
memmax_gb <- if (.task_mem_gb > 0) {
  max(2L, as.integer(floor(.task_mem_gb * 0.25)))
} else {
  8L
}
terraOptions(
  tempdir = "/ibstorage/anthony/NYS_Wetlands_Data/Data/tmp",
  memmax = memmax_gb
)
print(tempdir())

dir.create(handFolder, recursive = TRUE, showWarnings = FALSE)
dir.create(streamsFolder, recursive = TRUE, showWarnings = FALSE)

###############################################################################################
# Work list: every hydro-conditioned DEM in the requested clusters

l_hydrodem <- list.files(
  hydrodemFolder,
  pattern = "^cluster_\\d+_huc_\\d+_wbt\\.tif$",
  full.names = TRUE
)
dem_cluster <- str_extract(basename(l_hydrodem), "(?<=cluster_)\\d+")

if (!identical(tolower(clusterSpec), "all")) {
  wanted <- trimws(strsplit(clusterSpec, ",")[[1]])
  l_hydrodem <- l_hydrodem[dem_cluster %in% wanted]
}

# Biggest first, then round-robin, so array slices get a balanced share of the
# large HUCs. Slicing is done on the FULL list (before the skip-existing check)
# so every array element agrees on who owns which HUC.
l_hydrodem <- l_hydrodem[order(-file.size(l_hydrodem), l_hydrodem)]
l_hydrodem <- l_hydrodem[(seq_along(l_hydrodem) - 1) %% sliceCount == sliceId - 1]
message(length(l_hydrodem), " hydro DEM(s) in this slice")

###############################################################################################

hand_func <- function(dem_fn) {
  base <- sub("_wbt\\.tif$", "", basename(dem_fn)) # cluster_<N>_huc_<HUC>
  facc_fn <- file.path(hydroFolder, paste0(base, "_wbt_TWI_Facc.tif"))
  streams_fn <- file.path(streamsFolder, paste0(base, "_streams.tif"))
  hand_fn <- file.path(handFolder, paste0(base, "_HAND.tif"))

  if (file.exists(hand_fn)) {
    message("HAND already made: ", hand_fn)
    return("exists")
  }
  if (!file.exists(facc_fn)) {
    warning("No flow accumulation for ", base, " — HAND NOT written")
    return("no_flowacc")
  }
  t0 <- Sys.time()

  # Outputs are written under a temp name and renamed, so a killed task never
  # leaves a truncated file that the file.exists() resume check would trust.
  streams_tmp <- tempfile(pattern = paste0(base, "_streams_"), fileext = ".tif")
  hand_wbt <- tempfile(pattern = paste0(base, "_handwbt_"), fileext = ".tif")
  hand_tmp <- tempfile(pattern = paste0(base, "_hand_"), fileext = ".tif")
  d8_tmp <- tempfile(pattern = paste0(base, "_d8_"), fileext = ".tif")
  on.exit(unlink(c(streams_tmp, hand_wbt, hand_tmp, d8_tmp)), add = TRUE)

  # 1. Streams. Thresholded in terra rather than wbt_extract_streams: the
  #    flowacc lives in band 1 of a 2-band NaN-nodata raster, which WBT can't
  #    take directly (it wants a single band and chokes on NaN nodata), so WBT
  #    would need a rewritten copy first — this is that one pass, and it yields
  #    the streams directly. Byte raster, 1 = stream, 0 = NoData: the same
  #    convention as ExtractStreams without zero_background.
  fa <- rast(facc_fn, lyrs = 1)
  if (!identical(names(fa), "flowacc")) {
    stop("Band 1 of ", facc_fn, " is '", names(fa), "', expected 'flowacc'")
  }
  dem <- rast(dem_fn)
  if (!compareGeom(fa, dem, stopOnError = FALSE)) {
    stop("flowacc and hydro DEM grids differ for ", base)
  }
  #    Outlet cells are drainage too. A flow path that leaves the HUC (coast,
  #    HUC boundary) without meeting a thresholded stream gets NoData from
  #    ElevationAboveStream — 85% of the land in coastal cluster 118 HUC
  #    020302010403, and lowering the threshold barely helps (67% covered even
  #    at 25,000 cells). Outlets are the cells with no downslope neighbour in
  #    WBT's own D8 pointer (value 0) — on a depressionless DEM those are only
  #    the cells where flow exits — so seeding them gives every cell a HAND
  #    (height above its exit point) and leaves stream-draining cells unchanged
  #    (verified: 100% coverage, max diff 0 where both were valid).
  wbt_d8_pointer(
    dem = normalizePath(dem_fn),
    output = d8_tmp,
    compress_rasters = FALSE
  )
  if (!file.exists(d8_tmp)) {
    stop("D8Pointer produced no output for ", base)
  }
  writeRaster(
    (fa >= streamThreshold) | (rast(d8_tmp) == 0),
    streams_tmp,
    datatype = "INT1U",
    NAflag = 0,
    names = "streams",
    overwrite = TRUE
  )

  # 2. HAND. ElevationAboveStream derives its own D8 pointer from the DEM, so
  #    it needs the depressionless (wbt) DEM. wbt_* returns a status instead of
  #    raising, so check for the output.
  wbt_elevation_above_stream(
    dem = normalizePath(dem_fn),
    streams = streams_tmp,
    output = hand_wbt,
    compress_rasters = FALSE
  )
  if (!file.exists(hand_wbt)) {
    stop("ElevationAboveStream produced no output for ", base)
  }

  # 3. WBT writes Float64 (inherits the DEM type); store compressed Float32.
  writeRaster(
    rast(hand_wbt),
    hand_tmp,
    datatype = "FLT4S",
    names = "hand",
    overwrite = TRUE,
    gdal = c("COMPRESS=LZW", "PREDICTOR=2", "BIGTIFF=IF_SAFER")
  )

  # tempdir and outputs share a filesystem, so these renames are atomic.
  # HAND last: its presence marks the HUC as done.
  if (!file.rename(streams_tmp, streams_fn) || !file.rename(hand_tmp, hand_fn)) {
    stop("Could not move outputs into place for ", base)
  }
  message(
    "HAND written: ",
    hand_fn,
    " (",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1),
    " min)"
  )
  "written"
}

# Per-HUC tryCatch: one bad HUC must not abort the rest of the slice.
status <- vapply(
  l_hydrodem,
  function(f) {
    tryCatch(hand_func(f), error = function(e) {
      message("FAILED ", basename(f), ": ", conditionMessage(e))
      "failed"
    })
  },
  character(1)
)

print(table(status))
bad <- basename(l_hydrodem)[status %in% c("failed", "no_flowacc")]
if (length(bad) > 0) {
  message("HUCs without HAND:\n", paste(" ", bad, collapse = "\n"))
  quit(status = 1)
}
