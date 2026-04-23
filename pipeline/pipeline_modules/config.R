# Configuration module for methylation array analysis pipeline

#' Load configuration from file
#'
#' @param config_file Path to configuration file
#' @return Configuration list
load_config <- function(config_file) {
  if (!file.exists(config_file)) {
    stop("Configuration file not found: ", config_file)
  }
  
  if (grepl("\\.R$", config_file)) {
    # Source R file
    source(config_file, local = TRUE)
    if (!exists("config")) {
      stop("Configuration file must define a 'config' variable")
    }
    return(config)
  } else if (grepl("\\.yaml$|\\.yml$", config_file)) {
    # Parse YAML file
    if (!requireNamespace("yaml", quietly = TRUE)) {
      stop("Package 'yaml' is required for parsing YAML config files")
    }
    return(yaml::read_yaml(config_file))
  } else {
    stop("Unsupported configuration file format")
  }
}

#' Default configuration
#'
#' @return Default configuration list
default_config <- function() {
  list(
    # Input
    sample_sheet = "sample_sheet.csv",
    reference_samples = NULL,
    
    # Preprocessing
    normalization = "functional", # Options: raw, illumina, functional, quantile, swan
    
    # QC
    detection_p_threshold          = 0.01,
    sample_detection_p_threshold   = 0.05,
    failed_probe_percent_threshold = 25,
    min_median_intensity           = 10.5,
    filter_failed_samples          = TRUE,
    
    # Probe filtering
    remove_sex_chromosomes = TRUE,
    remove_snps = TRUE,
    remove_cross_reactive = TRUE,
    min_sample_success_rate = 0.75,
    
    # Dimensionality reduction
    variable_probes = 10000,
    tsne_perplexity = 5,
    tsne_dimensions = 2,
    umap_neighbors = 15,
    clustering_method = "complete",
    clustering_distance = "pearson",
    
    # CNV analysis
    cnv_method = "conumee", # Options: conumee, ChAMP, cnAnalysis450k
    cnv_threshold = 0.18,
    cnv_frequency_plot = TRUE,
    
    # Output
    include_interactive_plots = TRUE,
    generate_report = TRUE
  )
}

#' Set up directory structure
#'
#' @param main_dir Main output directory
#' @return List of directory paths
setup_directories <- function(main_dir) {
  figures <- file.path(main_dir, "figures")
  dirs <- list(
    processed             = file.path(main_dir, "processed_data"),
    qc                    = file.path(main_dir, "qc"),
    dim_reduction         = file.path(main_dir, "dimensionality_reduction"),
    cnv                   = file.path(main_dir, "cnv"),
    figures               = figures,
    figures_qc            = file.path(figures, "qc"),
    figures_dim_reduction = file.path(figures, "dim_reduction"),
    figures_cnv           = file.path(figures, "cnv"),
    reports               = file.path(main_dir, "reports")
  )

  for (dir in dirs) {
    dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  }

  return(dirs)
}

#' Log message to file and console
#'
#' @param message Message to log
#' @param log_file Log file path
log_message <- function(message, log_file = NULL) {
  timestamp <- format(Sys.time(), "[%Y-%m-%d %H:%M:%S]")
  log_message <- paste(timestamp, message)
  
  # Print to console
  cat(log_message, "\n")
  
  # Write to log file if provided
  if (!is.null(log_file)) {
    write(log_message, file = log_file, append = TRUE)
  }
}