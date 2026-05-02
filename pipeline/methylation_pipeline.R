#!/usr/bin/env Rscript

#==============================================================================
# Methylation Array Analysis Pipeline
# 
# This pipeline performs comprehensive analysis of Illumina methylation arrays:
# - 450k, EPIC (850K), and EPICv2
# - Preprocessing and normalization
# - Quality control
# - Probe filtering
# - Dimensionality reduction (tSNE, UMAP)
# - Copy number variation analysis
# - Visualization
#
# Created: May 2025
#==============================================================================
##clean the environment
message("Clean the environment")
rm(list=ls())


# Process command line arguments
suppressPackageStartupMessages(library(optparse))

MEQTRACK_VERSION <- "1.1.2"

cat("┌───────────────────────────────────────────────────┐\n")
cat("│                     MeQTrack                      │\n")
cat("│ Methylation Quality control and analysis Tracking │\n")
cat(sprintf("│                   Version %s                   │\n", MEQTRACK_VERSION))
cat("└───────────────────────────────────────────────────┘\n\n")


option_list <- list(
  make_option(c("-c", "--config"), type="character", default=NULL,
              help="Configuration file path", metavar="file"),
  make_option(c("-s", "--step"), type="character", default="all",
              help="Pipeline step to run [all|preprocess|qc|dim_reduction|cnv|visualization]", 
              metavar="step"),
  make_option(c("-a", "--array_type"), type="character", default="auto",
              help="Array type [450k|EPIC|EPICv2|auto]", metavar="type"),
  make_option(c("-o", "--output"), type="character", default="./results",
              help="Output directory", metavar="directory"),
  make_option(c("-d", "--data_dir"), type="character", default="./data",
              help="Data directory", metavar="directory"),
  make_option(c("-t", "--threads"), type="integer", default=4,
              help="Number of CPU threads to use", metavar="number"),
  make_option(c("-i", "--input"), type="character", default="./example/sample_sheet.csv",
              help="Path to sample sheet CSV file", metavar="file"),
  make_option("--hpc", action="store_true", default=FALSE,
              help="Generate HPC submission scripts")
)

opt_parser <- OptionParser(
  option_list = option_list,
  description = paste("MeQTrack v", MEQTRACK_VERSION, 
                      "- Methylation Quality control and analysis Tracking Pipeline", sep = "")
)
opt <- parse_args(opt_parser)



# Load necessary libraries
suppressPackageStartupMessages({
  library(data.table)
  library(limma)
  library(minfi)
  library(RColorBrewer)
  library(missMethyl)
  library(matrixStats)
  library(DMRcate)
  library(stringr)
  library(ggplot2)
  library(plotly)
  library(Rtsne)
  library(umap)
  library(dendextend)
  library(parallel)
  library(conumee2)
  library(sesame)
  library(yamapData)
})

# Set working directory to the script's location so relative paths work
# regardless of where Rscript is invoked from
script_dir <- tryCatch(
  dirname(normalizePath(sys.frame(1)$ofile)),
  error = function(e) {
    args <- commandArgs(trailingOnly = FALSE)
    script_arg <- args[grepl("^--file=", args)]
    if (length(script_arg)) dirname(normalizePath(sub("^--file=", "", script_arg)))
    else getwd()
  }
)
setwd(script_dir)

# Source pipeline modules
source("pipeline_modules/config.R")
source("pipeline_modules/utils.R")
source("pipeline_modules/preprocess.R")
source("pipeline_modules/qc.R")
source("pipeline_modules/filtering.R")
source("pipeline_modules/dim_reduction.R")
source("pipeline_modules/cnv_analysis.R")
source("pipeline_modules/visualization.R")
source("pipeline_modules/hpc.R")

# Set up pipeline variables
cat("Setting up methylation array analysis pipeline...\n")
set.seed(123456)
options(stringsAsFactors = FALSE)

# Load configuration. The user-supplied config (if any) only needs to
# carry the keys it overrides — everything else inherits from default_config().
if (!is.null(opt$config)) {
  config <- deep_merge(default_config(), load_config(opt$config))
} else {
  config <- default_config()
}

# Override sample_sheet path if provided via command line
if (!is.null(opt$input)) {
  config$sample_sheet <- opt$input
}

# Override probes data path if provided via command line
if (!is.null(opt$data_dir)) {
  config$data_dir <- opt$data_dir
}

# Create output directories
main_dir <- opt$output
dir.create(main_dir, showWarnings = FALSE, recursive = TRUE)
dirs <- setup_directories(main_dir)

# Log configuration
log_file <- file.path(main_dir, "pipeline_log.txt")
log_message("Starting methylation array analysis pipeline", log_file)
log_message(paste("Date:", Sys.time()), log_file)
log_message(paste("Output directory:", main_dir), log_file)
log_message(paste("Array type:", opt$array_type), log_file)
log_message(paste("Probe directory:", opt$data_dir), log_file)
log_message(paste("Threads:", opt$threads), log_file)

if (opt$hpc) {
  log_message("Generating HPC submission scripts", log_file)
  generate_hpc_scripts(config, opt, main_dir)
  quit(save = "no", status = 0)
}

# Run pipeline
run_pipeline <- function(step) {
  # Parse sample sheet
  sample_sheet <- read_sample_sheet(config$sample_sheet)
  
  # Select steps to run
  if (step == "all" || step == "preprocess") {
    log_message("Step 1: Preprocessing methylation data", log_file)
    
    normalization_method <- "swan"  # Default value
    if (!is.null(config$preprocessing) && !is.null(config$preprocessing$normalization)) {
      normalization_method <- config$preprocessing$normalization
      message("check normalization method ", config$preprocessing)
    } else if (!is.null(config$normalization)) {
      # For backward compatibility
      normalization_method <- config$normalization
    }
    
    result <- preprocess_methylation(
      sample_sheet, 
      array_type = opt$array_type,
      normalization = normalization_method,
      threads = opt$threads,
      output_dir = dirs$processed
    )
    save(result, file = file.path(dirs$processed, "preprocessed_data.RData"))
    
    # Extract key components
    beta_values <- result$beta
    m_values <- result$m_values
    rgset <- result$rgset
    sample_info <- result$sample_info
    detection_p <- result$detection_p
    array_type <- result$array_type
    
    # Save beta values as a flat file
    write_beta_values(beta_values, file.path(dirs$processed, "beta_values.txt"))
  } 
  else {
    # Load preprocessed data if not running preprocessing
    log_message("Loading preprocessed data...", log_file)
    data_file <- file.path(dirs$processed, "preprocessed_data.RData")
    if (!file.exists(data_file)) {
      beta_file <- file.path(dirs$processed, "beta_values.txt")
      if (file.exists(beta_file)) {
        log_message("Loading beta values from flat file...", log_file)
        beta_values <- read_beta_values(beta_file)
        
        # Create minimal result object if we only have beta values
        result <- list(
          beta = beta_values,
          array_type = opt$array_type
        )
        array_type <- opt$array_type
      } else {
        stop("Neither preprocessed data nor beta values found. Run preprocessing step first.")
      }
    } else {
      load(data_file)
      # Safety check to ensure we have the expected data structure
      if (!exists("result") || !is.list(result)) {
        stop("Invalid preprocessed data structure in: ", data_file)
      }
      
      # Extract key components
      beta_values <- result$beta
      m_values <- result$m_values
      rgset <- result$rgset
      sample_info <- result$sample_info
      detection_p <- result$detection_p
      array_type <- result$array_type
      
      # Debug: Check if rgset exists
      if (is.null(rgset)) {
        message("WARNING: rgset is NULL in preprocessed data. Some analyses may not work properly.")
      }
      # Add safety checks for NA values in beta_values
      if (is.null(beta_values) || all(is.na(beta_values))) {
        log_message("WARNING: Beta values are NULL or all NA in preprocessed data", log_file)
        
        # Try to load from flat file as backup
        beta_file <- file.path(dirs$processed, "beta_values.txt")
        if (file.exists(beta_file)) {
          log_message("Attempting to load beta values from flat file instead...", log_file)
          beta_values <- read_beta_values(beta_file)
          result$beta <- beta_values
        } else {
          stop("Beta values are NULL or all NA, and no flat file was found.")
        }
      }    
    }
  }
  if (step == "all" || step == "qc") {
    log_message("Step 2: Quality control", log_file)
    
    # Get QC parameters
    detection_p_threshold          <- 0.01   # Default value
    sample_detection_p_threshold   <- 0.05   # Default value
    failed_probe_percent_threshold <- 25     # Default value
    min_median_intensity           <- 10.5   # Default value
    filter_failed_samples          <- TRUE   # Default value

    if (!is.null(config$qc)) {
      if (!is.null(config$qc$detection_p_threshold))
        detection_p_threshold <- config$qc$detection_p_threshold
      if (!is.null(config$qc$sample_detection_p_threshold))
        sample_detection_p_threshold <- config$qc$sample_detection_p_threshold
      if (!is.null(config$qc$failed_probe_percent_threshold))
        failed_probe_percent_threshold <- config$qc$failed_probe_percent_threshold
      if (!is.null(config$qc$min_median_intensity))
        min_median_intensity <- config$qc$min_median_intensity
      if (!is.null(config$qc$filter_failed_samples))
        filter_failed_samples <- config$qc$filter_failed_samples
    }

    qc_results <- perform_qc(
      rgset,
      beta_values,
      sample_info,
      detection_p_threshold          = detection_p_threshold,
      sample_detection_p_threshold   = sample_detection_p_threshold,
      failed_probe_percent_threshold = failed_probe_percent_threshold,
      min_median_intensity           = min_median_intensity,
      output_dir = dirs$qc,
      plots_dir  = dirs$figures_qc
    )
    save(qc_results, file = file.path(dirs$qc, "qc_results.RData"))

    # Filter out failed samples if specified
    if (filter_failed_samples) {
      passed_samples <- qc_results$passed_samples
      n_removed <- length(qc_results$failed_samples)

      if (n_removed > 0) {
        log_message(sprintf("Removing %d failed sample(s) from all data objects: %s",
                            n_removed,
                            paste(qc_results$failed_samples, collapse = ", ")),
                    log_file)

        # Filter beta and M-value matrices
        beta_values <- beta_values[, colnames(beta_values) %in% passed_samples, drop = FALSE]
        if (!is.null(m_values))
          m_values <- m_values[, colnames(m_values) %in% passed_samples, drop = FALSE]

        # Filter RGChannelSet (enables downstream use of rgset with QC-passed samples)
        if (!is.null(rgset))
          rgset <- rgset[, colnames(rgset) %in% passed_samples]

        # Filter sample info
        sample_info <- sample_info[sample_info$Sample_ID %in% passed_samples, ]

      } else {
        log_message("All samples passed QC — no samples removed.", log_file)
      }

      # Save filtered data
      filtered_result <- list(
        beta        = beta_values,
        m_values    = m_values,
        sample_info = sample_info
      )
      save(filtered_result, file = file.path(dirs$processed, "filtered_data.RData"))
    }
  }
  
  # The UI presents QC and probe filtering as a single "QC and probe filtering"
  # stage, so --step qc must also run the filtering step. --step filtering on
  # its own is preserved for CLI back-compat.
  if (step == "all" || step == "qc" || step == "filtering") {
    # Note: deliberately no "Step N:" prefix — probe filtering is a sub-step
    # of the QC stage in the UI and the run_controller's stage-progress parser
    # ignores log lines without that prefix.
    log_message("Probe filtering", log_file)
    
    # Ensure beta_values is loaded and not NULL
    if (is.null(beta_values) || all(is.na(beta_values))) {
      log_message("Beta values not available from previous step. Trying to load from file...", log_file)
      
      # Try to load beta values from file
      beta_file <- file.path(dirs$processed, "beta_values.txt")
      if (file.exists(beta_file)) {
        beta_values <- read_beta_values(beta_file)
        log_message(paste("Loaded beta values with dimensions:", 
                          nrow(beta_values), "x", ncol(beta_values)), log_file)
      } else {
        stop("Beta values not available and could not be loaded from file. Run preprocessing step first.")
      }
    }
    
    # Get filtering parameters (local fallbacks; overridden by config$filtering$* below)
    remove_sex_chromosomes  <- TRUE
    remove_snps             <- TRUE
    remove_cross_reactive   <- TRUE
    min_sample_success_rate <- 0.75     # matches default_config()$filtering$min_sample_success_rate
    keep_probe_list         <- NULL
    probe_list_column       <- "x"
    
    if (!is.null(config$filtering)) {
      if (!is.null(config$filtering$remove_sex_chromosomes)) {
        remove_sex_chromosomes <- config$filtering$remove_sex_chromosomes
      }
      if (!is.null(config$filtering$remove_snps)) {
        remove_snps <- config$filtering$remove_snps
      }
      if (!is.null(config$filtering$remove_cross_reactive)) {
        remove_cross_reactive <- config$filtering$remove_cross_reactive
      }
      if (!is.null(config$filtering$min_sample_success_rate)) {
        min_sample_success_rate <- config$filtering$min_sample_success_rate
      }
      if (!is.null(config$filtering$keep_probe_list)) {
        keep_probe_list <- config$filtering$keep_probe_list
        
        # If the path is relative to data directory
        if (!is.null(keep_probe_list) && !file.exists(keep_probe_list) && !is.null(config$data_dir)) {
          potential_path <- file.path(config$data_dir, keep_probe_list)
          if (file.exists(potential_path)) {
            keep_probe_list <- potential_path
            log_message(paste("Using probe list file:", keep_probe_list), log_file)
          }
        }
        
        # Try to get array-specific probe list if set to "auto"
        if (!is.null(keep_probe_list) && keep_probe_list == "auto" && !is.null(config$data_dir)) {
          keep_probe_list <- get_array_probe_list(opt$array_type, config$data_dir)
          if (!is.null(keep_probe_list)) {
            log_message(paste("Auto-selected probe list file:", keep_probe_list), log_file)
          }
        }
      }
      if (!is.null(config$filtering$probe_list_column)) {
        probe_list_column <- config$filtering$probe_list_column
      }
    }
    
    log_message("Running probe filtering with the following parameters:", log_file)
    log_message(paste("  Array type:", opt$array_type), log_file)
    log_message(paste("  Remove sex chromosomes:", remove_sex_chromosomes), log_file)
    log_message(paste("  Remove SNPs:", remove_snps), log_file)
    log_message(paste("  Remove cross-reactive:", remove_cross_reactive), log_file)
    log_message(paste("  Keep probe list:", keep_probe_list), log_file)
    log_message(paste("  Probe list column:", probe_list_column), log_file)
    log_message(paste("  Min sample success rate:", min_sample_success_rate), log_file)
    
    # Get detection_p if available
    #detection_p_to_use <- NULL
    #if (!is.null(result) && !is.null(result$detection_p)) {
    #  detection_p_to_use <- result$detection_p
    #}

    message("Dimension of beta_value ", dim(beta_values))

    filtered_beta <- filter_probes(
      beta_values,
      array_type = if (!is.null(result) && !is.null(result$array_type)) result$array_type else opt$array_type,
      detection_p = detection_p,
      remove_sex_chromosomes = remove_sex_chromosomes,
      remove_snps = remove_snps,
      remove_cross_reactive = remove_cross_reactive,
      keep_probe_list = keep_probe_list,
      probe_list_column = probe_list_column,
      min_sample_success_rate = min_sample_success_rate,
      output_dir = dirs$processed,
      data_dir = config$data_dir
    )
    
    # Save filtered beta values
    log_message("Saving filtered beta values...", log_file)
    write_beta_values(filtered_beta, file.path(dirs$processed, "filtered_beta_values.txt"))
    
    log_message(paste("Filtering complete. Kept", nrow(filtered_beta), "probes."), log_file)
  } else if (step != "preprocess" && step != "qc") {
    # Try to load filtered data if not running filtering
    log_message("Loading filtered beta values...", log_file)
    filtered_file <- file.path(dirs$processed, "filtered_beta_values.txt")
    
    if (file.exists(filtered_file)) {
      filtered_beta <- read_beta_values(filtered_file)
      log_message(paste("Loaded filtered beta values with dimensions:", 
                        nrow(filtered_beta), "x", ncol(filtered_beta)), log_file)
    } else if (!is.null(beta_values)) {
      log_message("Filtered beta values not found. Using unfiltered beta values.", log_file)
      filtered_beta <- beta_values
    } else {
      stop("Neither filtered nor unfiltered beta values are available. Run preprocessing and filtering steps first.")
    }
  }
  
  if (step == "all" || step == "dim_reduction") {
    log_message("Step 3: Dimensionality reduction analysis", log_file)
    
    # Ensure sample_info is available for dimensionality reduction
    if (is.null(sample_info)) {
      log_message("Sample info not available. Attempting to load...", log_file)
      
      # Try to load from saved sample_info file
      sample_info_file <- file.path(dirs$processed, "sample_info.txt")
      if (file.exists(sample_info_file)) {
        log_message("Loading sample info from file...", log_file)
        sample_info <- read.table(sample_info_file, header = TRUE, sep = "\t", stringsAsFactors = FALSE)
      } else {
        # Fallback: create minimal sample_info from sample sheet or column names
        if (!is.null(sample_sheet)) {
          log_message("Creating sample info from sample sheet...", log_file)
          sample_info <- data.frame(
            Sample_ID = sample_sheet$Sentrix_ID,
            Sample_Name = sample_sheet$Sample_Name,
            stringsAsFactors = FALSE
          )
        } else if (!is.null(filtered_beta)) {
          log_message("Creating minimal sample info from beta values column names...", log_file)
          sample_info <- data.frame(
            Sample_ID = colnames(filtered_beta),
            Sample_Name = colnames(filtered_beta),
            stringsAsFactors = FALSE
          )
        } else {
          stop("Cannot determine sample information. Please ensure sample_info.txt exists or run preprocessing step first.")
        }
      }
    }
    
    # Get dimension reduction parameters
    variable_probes <- 10000  # Default value
    tsne_perplexity <- 5  # Default value
    tsne_dimensions <- 2  # Default value
    umap_neighbors <- 15  # Default value
    clustering_method <- "complete"  # Default value
    clustering_distance <- "pearson"  # Default value
    
    if (!is.null(config$dim_reduction)) {
      if (!is.null(config$dim_reduction$variable_probes)) {
        variable_probes <- config$dim_reduction$variable_probes
      }
      
      if (!is.null(config$dim_reduction$tsne)) {
        if (!is.null(config$dim_reduction$tsne$perplexity)) {
          tsne_perplexity <- config$dim_reduction$tsne$perplexity
        }
        if (!is.null(config$dim_reduction$tsne$dimensions)) {
          tsne_dimensions <- config$dim_reduction$tsne$dimensions
        }
      }
      
      if (!is.null(config$dim_reduction$umap) && !is.null(config$dim_reduction$umap$n_neighbors)) {
        umap_neighbors <- config$dim_reduction$umap$n_neighbors
      }
      
      if (!is.null(config$dim_reduction$clustering)) {
        if (!is.null(config$dim_reduction$clustering$method)) {
          clustering_method <- config$dim_reduction$clustering$method
        }
        if (!is.null(config$dim_reduction$clustering$distance)) {
          clustering_distance <- config$dim_reduction$clustering$distance
        }
      }
    }
    
    # Select top variable probes for clustering
    variable_probes <- select_variable_probes(
      filtered_beta, 
      n_probes = variable_probes,
      method = "sd"
    )
    
    # Perform tSNE
    tsne_results <- run_tsne(
      variable_probes,
      sample_info,
      perplexity = tsne_perplexity,
      dimensions = tsne_dimensions,
      output_dir = dirs$dim_reduction,
      plots_dir  = dirs$figures_dim_reduction
    )

    # Perform UMAP
    umap_results <- run_umap(
      variable_probes,
      sample_info,
      n_neighbors = umap_neighbors,
      output_dir = dirs$dim_reduction,
      plots_dir  = dirs$figures_dim_reduction
    )

    # Perform hierarchical clustering
    hclust_results <- run_hierarchical_clustering(
      variable_probes,
      sample_info,
      method = clustering_method,
      distance = clustering_distance,
      output_dir = dirs$dim_reduction,
      plots_dir  = dirs$figures_dim_reduction
    )
    
    # Save all results
    dim_reduction_results <- list(
      tsne = tsne_results,
      umap = umap_results,
      hclust = hclust_results,
      variable_probes = variable_probes
    )
    save(dim_reduction_results, file = file.path(dirs$dim_reduction, "dim_reduction_results.RData"))
  }
  
  if (step == "all" || step == "cnv") {
    log_message("Step 4: Copy number variation analysis", log_file)
    
    # Ensure array_type is available for CNV analysis
    if (is.null(array_type)) {
      if (!is.null(result) && !is.null(result$array_type)) {
        array_type <- result$array_type
        log_message(paste("Using array_type from result:", array_type), log_file)
      } else if (!is.null(opt$array_type)) {
        array_type <- opt$array_type
        log_message(paste("Using array_type from command line:", array_type), log_file)
      } else {
        array_type <- "EPICv2"  # Default fallback
        log_message(paste("Using default array_type:", array_type), log_file)
      }
    }
    
    # Get CNV parameters
    cnv_method <- "conumee"  # Default value
    cnv_threshold <- 0.18  # Default value
    cnv_frequency_plot <- TRUE  # Default value
    
    if (!is.null(config$cnv)) {
      if (!is.null(config$cnv$method)) {
        cnv_method <- config$cnv$method
      }
      if (!is.null(config$cnv$threshold)) {
        cnv_threshold <- config$cnv$threshold
      }
      if (!is.null(config$cnv$frequency_plot)) {
        cnv_frequency_plot <- config$cnv$frequency_plot
      }
    }
    
    # Determine if we have reference samples
    if (!is.null(config$reference_samples) && file.exists(config$reference_samples)) {
      references <- read_sample_sheet(config$reference_samples)
    } else if (!is.null(config$input) && !is.null(config$input$reference_samples) && 
               file.exists(config$input$reference_samples)) {
      references <- read_sample_sheet(config$input$reference_samples)
    } else {
      references <- NULL
    }
    
    # Run CNV analysis
    cnv_results <- run_cnv_analysis(
      rgset,
      sample_info,
      references = references,
      method = cnv_method,
      array_type = array_type,
      output_dir = dirs$cnv,
      plots_dir  = dirs$figures_cnv,
      threads = opt$threads
    )

    # Generate frequency plot
    if (cnv_frequency_plot) {
      frequency_plot_path <- generate_cnv_frequency_plot(
        cnv_results$segments,
        threshold = cnv_threshold,
        output_dir = dirs$figures_cnv
      )
      # Add frequency plot path to CNV results
      cnv_results$frequency_plot <- frequency_plot_path
    }
    
    # Save CNV results
    save(cnv_results, file = file.path(dirs$cnv, "cnv_results.RData"))
  }
  
  if (step == "all" || step == "visualization") {
    log_message("Step 5: Generate visualizations", log_file)

    # Load required results if they exist
    if (file.exists(file.path(dirs$qc, "qc_results.RData"))) {
      load(file.path(dirs$qc, "qc_results.RData"))
    }

    if (file.exists(file.path(dirs$dim_reduction, "dim_reduction_results.RData"))) {
      load(file.path(dirs$dim_reduction, "dim_reduction_results.RData"))
    }

    if (file.exists(file.path(dirs$cnv, "cnv_results.RData"))) {
      load(file.path(dirs$cnv, "cnv_results.RData"))
    }

    # Generate reports
    generate_report(
      qc_results    = if (exists("qc_results"))           qc_results           else NULL,
      dim_reduction = if (exists("dim_reduction_results")) dim_reduction_results else NULL,
      cnv_data      = if (exists("cnv_results"))           cnv_results           else NULL,
      sample_info   = sample_info,
      output_dirs   = dirs,
      output_dir    = dirs$reports
    )
  }
  
  log_message("Pipeline completed successfully", log_file)
}

# Run the specified pipeline step
run_pipeline(opt$step)
