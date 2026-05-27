### merge_band_stats.R
###
### Merge per-cluster band-statistic JSONs (produced by
### DL_Extract_Normalize_Stats_FullRasters.R) into ONE global min/max JSON,
### combining clusters with min-of-mins / max-of-maxs per band.
###
### The global file reflects every partial currently in <partials_dir>, so run
### this as the final step once all batches' per-cluster partials exist (or just
### re-run it after the last batch finishes).
###
### Usage:
###   Rscript merge_band_stats.R <partials_dir> <output_json>

library(jsonlite)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop("Usage: Rscript merge_band_stats.R <partials_dir> <output_json>")
}
partials_dir <- args[1]
output_json  <- args[2]

files <- list.files(partials_dir, pattern = "\\.json$", full.names = TRUE)
if (length(files) == 0) stop("No partial JSONs found in ", partials_dir)

cat("Merging", length(files), "cluster partials from", partials_dir, "\n")

global_min <- list()
global_max <- list()
for (f in files) {
  s <- fromJSON(f)
  for (b in names(s)) {
    mn <- s[[b]]$min
    mx <- s[[b]]$max
    global_min[[b]] <- if (is.null(global_min[[b]])) mn else min(global_min[[b]], mn, na.rm = TRUE)
    global_max[[b]] <- if (is.null(global_max[[b]])) mx else max(global_max[[b]], mx, na.rm = TRUE)
  }
}

bands <- names(global_min)
out <- lapply(bands, \(b) list(band = b, min = global_min[[b]], max = global_max[[b]]))
names(out) <- bands

dir.create(dirname(output_json), recursive = TRUE, showWarnings = FALSE)
write_json(out, output_json, pretty = TRUE, auto_unbox = TRUE)

cat("\nGlobal band statistics written to:", output_json, "\n\nSummary:\n")
for (b in bands) {
  cat(sprintf("  %-15s  min: %12.4f  max: %12.4f\n", b, global_min[[b]], global_max[[b]]))
}
