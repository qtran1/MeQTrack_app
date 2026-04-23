#' Filter probes from beta values matrix
#'
#' @param beta_values Beta values matrix
#' @param array_type Array type
#' @param detection_p Detection p-values matrix
#' @param detection_p_threshold Threshold for detection p-values (default: 0.01)
#' @param remove_sex_chromosomes Whether to remove probes on sex chromosomes
#' @param remove_snps Whether to remove probes containing SNPs
#' @param remove_cross_reactive Whether to remove cross-reactive probes
#' @param keep_probe_list Path to file containing probes to keep (optional)
#' @param probe_list_column Column name in keep_probe_list file containing probe IDs
#' @param min_sample_success_rate Minimum proportion of samples with valid measurements
#' @param output_dir Output directory for filtered files
#' @param data_dir directory contains kept probes for each array type
#' @return Filtered beta values matrix
filter_probes <- function(beta_values, 
                          array_type = "EPICv2", 
                          detection_p = NULL,
                          detection_p_threshold = 0.05,
                          remove_sex_chromosomes = TRUE,
                          remove_snps = TRUE,
                          remove_cross_reactive = TRUE,
                          keep_probe_list = NULL,
                          probe_list_column = "x",
                          min_sample_success_rate = 0.3,
                          output_dir = ".",
                          data_dir = "./data") {
  
  original_probe_count <- nrow(beta_values)
  message(paste("Original probe count:", original_probe_count))
  message(paste("Beta values dimensions:", nrow(beta_values), "x", ncol(beta_values)))
   
  # If array_type is "auto", determine it based on the number of probes
  # Note: Use more appropriate thresholds since beta_values may already be filtered
  if (array_type == "auto") {
    n_probes <- nrow(beta_values)
    if (n_probes < 500000) {
      array_type <- "450K"
      message("Auto-detected array type: 450K")
    } else if (n_probes < 950000) {
      array_type <- "EPIC"
      message("Auto-detected array type: EPIC")
    } else {
      array_type <- "EPICv2"
      message("Auto-detected array type: EPICv2")
    }
  }
  
  # Track filtered probes
  filtered_probes <- list()
  
  # 1. Filter by detection p-value
  # If detection_p is NULL, try to load from standard location
  if (is.null(detection_p) && !is.null(output_dir)) {
    detection_p_file <- file.path(output_dir, "detection_p.txt")
    if (file.exists(detection_p_file)) {
      message("Loading detection p-values from: ", detection_p_file)
      detection_p <- read_beta_values(detection_p_file)
      message("Loaded detection p-values: ", nrow(detection_p), "x", ncol(detection_p))
    } else {
      # Try to load from parent directory
      parent_dir <- dirname(output_dir)
      rgset_file <- file.path(parent_dir, "rgset.RData")
      if (file.exists(rgset_file)) {
        message("Loading detection p-values from RData file: ", rgset_file)
        load(rgset_file)
        if (exists("rgset")) {
          detection_p <- detectionP(rgset)
          message("Calculated detection p-values from rgset: ", nrow(detection_p), "x", ncol(detection_p))
        }
      }
    }
  }

  ## Use detection p-value to determine if any probes are performing poorly and should be removed. 
  ## We used "min_sample_success_rate" in this case 
  if (!is.null(detection_p)) {
    message("Filtering probes by detection p-value...")
    message("Biggest Detection p-value ", max(detection_p))
    # Ensure probes are in the same order
    if (nrow(detection_p) == nrow(beta_values) && 
        all(rownames(detection_p) == rownames(beta_values))) {
      # Probes are already aligned
    } else {
      detection_p <- detection_p[match(rownames(beta_values), rownames(detection_p)), ]
    }
    message("The detection_p_threshold is ", detection_p_threshold, "\n")
    # Keep probes that have passed detection p-value threshold in at least x% of samples
    # Handle NA values properly by treating them as failed detection
    detection_p <- as.data.frame(detection_p)
  
    ## Use detection p-value to determine if any probes are performing poorly and should be removed. 
    ## We used 20% in this case which allows for one sample failure per probe 
    # Finally, we can set all failed probes that have not been removed to NA in the beta table
    detection_p[detection_p > 0.05] <- NA

    ## Reorder pvals table to be same order as sample_table
    detection_p <- detection_p[, match(colnames(beta_values), colnames(detection_p))]

    ## Use detection p-value to determine if any probes are performing poorly and should be removed. 
    row_Ps <- apply(detection_p, 1, function(x) {
      sum(is.na(x))
    })

    probes_to_remove <- which(row_Ps > ((ncol(detection_p) * min_sample_success_rate)))   
    print(
      paste(
        length(probes_to_remove) ,
        "Probes failed by each having a detection P value > 0.05 in more than", min_sample_success_rate, "of samples",
        sep = " "
      )
    )
    ## Now we can remove these probes from the beta table and the detection p-values
    if (length(probes_to_remove) > 0){
      beta_v2.detP <- beta_values[-probes_to_remove, ]
      pvals2 <- detection_p[-probes_to_remove, ]
    }else{
      beta_v2.detP <- beta_values
      pvals2 <- detection_p
    }
    ## Finally, we can set all failed probes that have not been removed to NA in the beta table
    #beta_v2.detP[is.na(pvals2)] <- NA

    # 2. Try to get pre-select probes, but continue even if it fails
    ## Using functions from DMRcate, we are able to remove SNP and CH associated probes from the beta table.
    #beta_v2.clean <- rmSNPandCH(beta_v2.detP, rmXY=TRUE)

    ## Note: If you would like to keep all of the SNPs then you can set parameters in the above code as follows. 
    ##rmSNPandCH(beta_v2.detP2, dist=0, mafcut = 1)

    ## We can also remove the replicate probes and collapse them based off preference. Mean, sensitivity, specificity and random are available options. We will use mean in this scenario
    #if (array_type == "EPICv2") {
    #  beta_v2.clean <- rmPosReps(beta_v2.clean, filter.strategy = "mean")
    #}
    #message("beta_v2.clean: ", nrow(beta_v2.clean))
  }

  probe_file_map <- list(
    "450K"   = file.path(data_dir, "keep.probes.450K.txt"),
    "EPIC"   = file.path(data_dir, "keep.probes.EPIC.txt"),
    "EPICv2" = file.path(data_dir, "keep.probes.EPICv2.txt")
  )

  if (array_type == "450K") {
    probe_file <- probe_file_map[["450K"]]
  } else if (array_type == "EPIC") {
    message("EPIC was selected.")
    probe_file <- probe_file_map[["EPIC"]]
  } else {
    message("EPICv2 was selected.")
    probe_file <- probe_file_map[["EPICv2"]]
  }

  if (!file.exists(probe_file)) {
    stop(
      "Probe keep-list file not found: ", probe_file, "\n",
      "  Expected array type  : ", array_type, "\n",
      "  data_dir used        : ", data_dir, "\n",
      "  Pass --data_dir <path> pointing to the folder that contains keep.probes.", array_type, ".txt"
    )
  }
  keep.probes <- read.table(probe_file, header = TRUE)

  if (array_type == "EPICv2") {
    # Extract base probe names from the filtered beta_v2.detP matrix (not original beta_values)
    beta_base_names <- gsub("_.*$", "", rownames(beta_v2.detP))
    keep_base_names <- gsub("_.*$", "", keep.probes$x)
    
    # Debug: Show samples of names to understand the mismatch
    message("Sample beta probe names: ", paste(head(rownames(beta_v2.detP), 3), collapse = ", "))
    message("Sample keep probe names: ", paste(head(keep.probes$x, 3), collapse = ", "))
    message("Sample beta base names: ", paste(head(beta_base_names, 3), collapse = ", "))
    message("Sample keep base names: ", paste(head(keep_base_names, 3), collapse = ", "))
    
    # Find which beta probes have matching base names in the keep list
    keep_indices <- beta_base_names %in% keep_base_names
    beta_values.clean <- beta_v2.detP[keep_indices, ]
    
    message(paste("EPICv2 probe matching: kept", sum(keep_indices), "out of", length(keep_indices), "probes"))
  } else {
    # For 450K and EPIC, use direct name matching with the extracted probe names
    beta_values.clean <- beta_v2.detP[rownames(beta_v2.detP) %in% keep.probes$x, ]
  } 
  
  
  # Output filtering statistics
  filtered_count <- original_probe_count - nrow(beta_values.clean)
  message(paste("Total filtered probes:", filtered_count, 
                "(", round(filtered_count/original_probe_count*100, 2), "%)"))
  message(paste("Remaining probes:", nrow(beta_values.clean)))
  
  # Write filtered probe lists to file
  if (!is.null(output_dir)) {
    dir.create(file.path(output_dir, "filtered_probes"), showWarnings = FALSE, recursive = TRUE)
    
    # Save each category of filtered probes
    for (category in names(filtered_probes)) {
      if (length(filtered_probes[[category]]) > 0) {
        write.table(
          filtered_probes[[category]],
          file = file.path(output_dir, "filtered_probes", paste0(category, "_probes.txt")),
          row.names = FALSE, col.names = FALSE, quote = FALSE
        )
      }
    }
    
    # Save filtering summary
    filtering_summary <- data.frame(
      Category = c("Original", names(filtered_probes), "Remaining"),
      Count = c(
        original_probe_count,
        sapply(filtered_probes, length),
        nrow(beta_values.clean)
      ),
      Percentage = c(
        100,
        sapply(filtered_probes, function(x) round(length(x)/original_probe_count*100, 2)),
        round(nrow(beta_values.clean)/original_probe_count*100, 2)
      )
    )
    
    write.csv(
      filtering_summary,
      file = file.path(output_dir, "filtered_probes", "filtering_summary.csv"),
      row.names = FALSE
    )
  }
  
  return(beta_values.clean)
}

#' Select most variable probes
#'
#' Get the array-specific probe keep-list file path.
#'
#' @param array_type  One of "450K", "EPIC", "EPICv2", or "auto".
#' @param data_dir    Directory containing the keep.probes.*.txt files.
#' @return  Path to the probe list file, or NULL if not found.
get_array_probe_list <- function(array_type, data_dir = "./data") {
  probe_files <- list(
    "450K"   = file.path(data_dir, "keep.probes.450K.txt"),
    "EPIC"   = file.path(data_dir, "keep.probes.EPIC.txt"),
    "EPICv2" = file.path(data_dir, "keep.probes.EPICv2.txt")
  )

  if (is.null(array_type) || array_type == "auto") {
    # Return first file that exists
    for (f in probe_files) {
      if (file.exists(f)) return(f)
    }
    return(NULL)
  }

  path <- probe_files[[array_type]]
  if (is.null(path)) {
    warning("Unknown array_type '", array_type, "'. Cannot select probe list.")
    return(NULL)
  }
  if (!file.exists(path)) {
    warning("Probe list file not found: ", path)
    return(NULL)
  }
  path
}

#' @param beta_values Beta values matrix
#' @param n_probes Number of probes to select
#' @param method Method for selecting variable probes (sd, mad, iqr)
#' @return Matrix with subset of most variable probes
select_variable_probes <- function(beta_values, n_probes = 10000, method = "sd") {
  message(paste("Selecting", n_probes, "most variable probes using", method, "method..."))
  
  if (method == "sd") {
    # Standard deviation
    variation <- apply(beta_values, 1, sd, na.rm = TRUE)
  } else if (method == "mad") {
    # Median absolute deviation
    variation <- apply(beta_values, 1, mad, na.rm = TRUE)
  } else if (method == "iqr") {
    # Interquartile range
    variation <- apply(beta_values, 1, function(x) {
      quantile(x, 0.75, na.rm = TRUE) - quantile(x, 0.25, na.rm = TRUE)
    })
  } else {
    stop("Unsupported method: ", method)
  }
  
  # Sort by variation measure
  ordered_idx <- order(variation, decreasing = TRUE)
  
  # Select top n_probes
  selected_idx <- ordered_idx[1:min(n_probes, length(ordered_idx))]
  
  return(beta_values[selected_idx, ])
}
