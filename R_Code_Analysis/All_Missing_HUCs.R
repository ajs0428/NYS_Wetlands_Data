library(readr)
library(dplyr)
library(stringr)
library(purrr)

###############

missing_huc_files <- list.files("Data/MissingProcessing/", full.names = TRUE)
missing_huc_df <- readr::read_csv(missing_huc_files) |>
  filter(!is.na(huc))
print(missing_huc_df, n = nrow(missing_huc_df))

summ_missing_huc_df <- missing_huc_df |>
  distinct(cluster, source) |>
  arrange(source, cluster)
summ_missing_huc_df
###############
# Per-source specs: Rscript path, SLURM resources, and ordered args.
# `$number` is substituted per cluster inside the generated for-loop.

source_specs <- list(
  DEM = list(
    script = "R_Code_Analysis/DEM_Extract_singleVect_CMD.r",
    job_name = "dem_missing",
    nodelist = "cbsuxu04,cbsuxu05,cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10",
    mem = "32G", cpus = 2, ntasks = 5, ntasks_per_node = 1,
    log_prefix = "dem_missing",
    use_srun = TRUE,
    args = c('"Data/NYS_DEM_Indexes"',
             '"Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"',
             '"$number"',
             '"Data/DEMs/"',
             '"Data/TerrainProcessed/HUC_DEMs/"')
  ),
  NAIP = list(
    script = "R_Code_Analysis/NAIP_Processing_CMD.R",
    job_name = "naip_missing",
    nodelist = "cbsuxu09,cbsuxu10",
    mem = "64G", cpus = 2, ntasks = 2, ntasks_per_node = NA,
    log_prefix = "naip_missing",
    use_srun = FALSE,
    args = c('"Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"',
             '"$number"',
             '"Data/NAIP/HUC_NAIP_Processed/"')
  ),
  Satellite = list(
    script = "R_Code_Analysis/Sentinel_FromGEE_Processing.R",
    job_name = "sat_missing",
    nodelist = "cbsuxu09,cbsuxu10",
    mem = "32G", cpus = 2, ntasks = 2, ntasks_per_node = NA,
    log_prefix = "sat_gee_missing",
    use_srun = TRUE,
    args = c('"Data/TerrainProcessed/HUC_DEMs/"',
             '"Data/Satellite/GEE_Download_NY_HUC_Sentinel_Indices/"',
             '"Data/Satellite/HUC_Processed_NY_Sentinel_Indices/"',
             '"$number"')
  ),
  TerrainCurv = list(
    script = "R_Code_Analysis/terrain_metrics_noparallel_filter_singleVect_CMD.r",
    job_name = "curv_missing",
    nodelist = "cbsuxu09,cbsuxu10",
    mem = "128G", cpus = 1, ntasks = 2, ntasks_per_node = NA,
    log_prefix = "terrain_curv_missing",
    use_srun = TRUE,
    args = c('"$number"',
             '"Data/TerrainProcessed/HUC_DEMs"',
             '"curv"',
             '"Data/TerrainProcessed/HUC_TerrainMetrics/"')
  ),
  TerrainDMV = list(
    script = "R_Code_Analysis/terrain_metrics_filter_singleVect_CMD.r",
    job_name = "dmv_missing",
    nodelist = "cbsuxu09,cbsuxu10",
    mem = "48G", cpus = 3, ntasks = 2, ntasks_per_node = NA,
    log_prefix = "terrain_dmv_missing",
    use_srun = FALSE,
    args = c('"$number"',
             '"Data/TerrainProcessed/HUC_DEMs"',
             '"dmv"',
             '"Data/TerrainProcessed/HUC_TerrainMetrics/"')
  ),
  TerrainSlp = list(
    script = "R_Code_Analysis/terrain_metrics_filter_singleVect_CMD.r",
    job_name = "slp_missing",
    nodelist = "cbsuxu09,cbsuxu10",
    mem = "64G", cpus = 2, ntasks = 2, ntasks_per_node = NA,
    log_prefix = "terrain_slp_missing",
    use_srun = FALSE,
    args = c('"$number"',
             '"Data/TerrainProcessed/HUC_DEMs"',
             '"slp"',
             '"Data/TerrainProcessed/HUC_TerrainMetrics/"')
  ),
  CHM = list(
    script = "R_Code_Analysis/CHM_extraction.R",
    job_name = "chm_missing",
    nodelist = "cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10",
    mem = "36G", cpus = 2, ntasks = 5, ntasks_per_node = 1,
    log_prefix = "chm_missing",
    use_srun = TRUE,
    args = c('"Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"',
             '"$number"',
             '"Data/CHMs/AWS"')
  ),
  Lidar = list(
    script = "R_Code_Analysis/Lidar_HUC_Processing.R",
    job_name = "lidar_missing",
    nodelist = "cbsuxu06,cbsuxu07,cbsuxu08,cbsuxu09,cbsuxu10",
    mem = "84G", cpus = 1, ntasks = 5, ntasks_per_node = 1,
    log_prefix = "lidar_huc_missing",
    use_srun = TRUE,
    args = c('"Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"',
             '"$number"',
             '"Data/Lidar/HUC_Lidar_Metrics/"')
  ),
  Hydro = list(
    script = "R_Code_Analysis/hydro_metrics_singleVect_CMD.r",
    job_name = "hydro_missing",
    nodelist = "cbsuxu09,cbsuxu10",
    mem = "128G", cpus = 1, ntasks = 2, ntasks_per_node = 1,
    log_prefix = "hydro_missing",
    use_srun = TRUE,
    args = c('"Data/NY_HUCS/NY_Cluster_Zones_250_CROP_NAomit_6347.gpkg"',
             '"$number"',
             '"Data/TerrainProcessed/HUC_DEMs/"',
             '"Data/TerrainProcessed/HUC_Hydro/"')
  )
)

###############
# Build a SLURM shell script for one (source, clusters) pair.
# Mirrors the structure in Shell_Scripts/*_loop.sh: SBATCH header,
# cd + TMPDIR + module load, include=(...), for-loop over clusters.

build_shell_script <- function(src, clusters, spec, out_dir) {
  include_str <- paste(clusters, collapse = " ")
  srun_prefix <- if (spec$use_srun) {
    "    srun --nodes=1 --ntasks=1 --exclusive \\\n        "
  } else {
    "    "
  }
  args_joined <- paste(spec$args, collapse = " \\\n        ")
  ntasks_per_node_line <- if (!is.na(spec$ntasks_per_node)) {
    paste0("#SBATCH --ntasks-per-node=", spec$ntasks_per_node, "\n")
  } else {
    ""
  }

  header <- paste0(
    "#!/bin/bash -l\n",
    "#SBATCH --nodelist=", spec$nodelist, "\n",
    "#SBATCH --mail-user=ajs544@cornell.edu\n",
    "#SBATCH --mail-type=ALL\n",
    "#SBATCH --mem-per-cpu=", spec$mem, "\n",
    "#SBATCH --cpus-per-task=", spec$cpus, "\n",
    "#SBATCH --job-name=", spec$job_name, "\n",
    "#SBATCH --ntasks=", spec$ntasks, "\n",
    ntasks_per_node_line,
    "#SBATCH --output=Shell_Scripts/SLURM/slurm-", spec$job_name, "-%j.out\n\n",
    "cd /ibstorage/anthony/NYS_Wetlands_Data/\n\n",
    "export TMPDIR=/ibstorage/anthony/tmp\n\n",
    "module load R/4.4.3\n\n"
  )

  body <- paste0(
    "# Missing clusters identified by All_Missing_HUCs.R on ", Sys.Date(), "\n",
    "include=(", include_str, ")\n\n",
    "for number in \"${include[@]}\"; do\n",
    "    echo \"Running ", src, " Rscript for cluster: $number\"\n",
    srun_prefix, "Rscript ", spec$script, " \\\n        ",
    args_joined,
    " >> \"Shell_Scripts/logs/", spec$log_prefix, "_${number}_$(date +%Y%m%d).log\" 2>&1 &\n",
    "done\n\n",
    "wait\n",
    "echo \"All ", src, " missing-cluster Rscripts completed.\"\n"
  )

  out_path <- file.path(out_dir, paste0("missing_", tolower(src), ".sh"))
  writeLines(paste0(header, body), out_path)
  Sys.chmod(out_path, "755")
  out_path
}

###############
# Generate one shell script per source covering its missing clusters.

out_dir <- "Shell_Scripts/missing"
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

generated_scripts <- summ_missing_huc_df |>
  group_by(source) |>
  summarise(clusters = list(sort(unique(as.integer(cluster)))), .groups = "drop") |>
  mutate(
    script_path = pmap_chr(list(source, clusters), function(src, cls) {
      if (!src %in% names(source_specs)) {
        warning("No spec defined for source: ", src)
        return(NA_character_)
      }
      build_shell_script(src, cls, source_specs[[src]], out_dir)
    })
  )

print(generated_scripts)

###############
# Write a master submitter that sbatches every generated script.

master_path <- file.path(out_dir, "submit_all_missing.sh")
submit_lines <- c(
  "#!/bin/bash -l",
  "# Auto-generated submitter for missing-HUC reprocessing.",
  paste0("# Generated: ", Sys.time()),
  "cd /ibstorage/anthony/NYS_Wetlands_Data/",
  "",
  paste0("sbatch ", na.omit(generated_scripts$script_path))
)
writeLines(submit_lines, master_path)
Sys.chmod(master_path, "755")

message("\nGenerated ", sum(!is.na(generated_scripts$script_path)),
        " per-source shell scripts in ", out_dir,
        "\nSubmit them on the HPC node with:\n  bash ", master_path)
