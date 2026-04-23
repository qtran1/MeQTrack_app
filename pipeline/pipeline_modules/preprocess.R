# Preprocessing module for methylation array analysis pipeline

#' Read sample sheet
#'
#' @param sample_sheet_path Path to sample sheet CSV
#' @return Data frame containing sample information
read_sample_sheet <- function(sample_sheet_path) {
  if (!file.exists(sample_sheet_path)) {
    stop("Sample sheet not found: ", sample_sheet_path)
  }
  
  # Function to read data files
  read_data <- function(file) {
      message("Reading data from: ", file)
      data <- fread(file, header = TRUE)
      data <- as.data.frame(data)
      
      # Clean column names if they start with X
      if (grepl("X", colnames(data)[1])) {
        colnames(data) <- gsub("X", "", colnames(data))
      }
      
      # Set row names and remove the first column if it's an index
      if (colnames(data[1]) != "Sentrix_ID") {
        rownames(data) <- data[, 1]
        data <- data[, -1]
      }
      
      return(data)
    }
  sample_sheet <- read_data(sample_sheet_path)
  
  # Check required columns
  required_cols <- c("Sentrix_ID", "Sample_Name", "Basename")
  missing_cols <- required_cols[!required_cols %in% colnames(sample_sheet)]
  
  if (length(missing_cols) > 0) {
    stop("Sample sheet is missing required column(s): ", paste(missing_cols, collapse = ", "))
  }

  # Check for and remove duplicate Basename entries (would crash read.metharray)
  dup_mask <- duplicated(sample_sheet$Basename)
  if (any(dup_mask)) {
    dup_basenames <- unique(sample_sheet$Basename[dup_mask])
    warning(
      length(dup_basenames), " duplicate Basename(s) found and removed (keeping first occurrence):\n",
      paste0("  ", dup_basenames, collapse = "\n")
    )
    sample_sheet <- sample_sheet[!dup_mask, ]
    message("Sample sheet after deduplication: ", nrow(sample_sheet), " samples remain.")
  }

  return(sample_sheet)
}

#' Determine array type from data
#'
#' @param rgset Raw data RGChannelSet
#' @return String indicating array type (450k, EPIC, EPICv2)
determine_array_type <- function(rgset) {
  # Get number of probes
  n_probes <- nrow(rgset)
  
  if (n_probes < 600000) {
    return("450k")
  } else if (n_probes < 900000) {
    return("EPIC")
  } else {
    return("EPICv2")
  }
}

#' Load appropriate annotation package based on array type
#'
#' @param array_type Array type (450k, EPIC, EPICv2)
#' @return Annotation object
load_array_annotation <- function(array_type) {
  # Handle auto-detection
  if (array_type == "auto") {
    warning("Array type 'auto' is not valid for loading annotations directly. 
            Please determine the specific array type first or specify it explicitly.")
    array_type <- "EPIC"  # Default to EPIC as fallback
  }
  
  # Check for valid array types
  if (!array_type %in% c("450k", "EPIC", "EPICv2")) {
    stop("Unsupported array type: ", array_type, 
         ". Must be one of: '450k', 'EPIC', 'EPICv2'")
  }

  # Create a safe getAnnotation function
  safe_get_annotation <- function(pkg_name) {
    if (requireNamespace(pkg_name, quietly = TRUE)) {
      tryCatch({
        # Get the annotation object from the package
        pkg_env <- asNamespace(pkg_name)
        anno_obj <- data(pkg_name)
        return(anno_obj)
      }, error = function(e) {
        # If there's an error, provide details and return NULL
        warning("Error getting annotation from package '", pkg_name, "': ", e$message)
        return(NULL)
      })
    } else {
      return(NULL)
    }
  }
  
  # Try to load the appropriate annotation package
  anno_obj <- NULL
  
  if (array_type == "450k") {
    message("Loading 450k annotation...")
    pkg_name <- "IlluminaHumanMethylation450kanno.ilmn12.hg19"
    anno_obj <- safe_get_annotation(pkg_name)
    
    if (is.null(anno_obj)) {
      # Try to fall back to EPIC if 450k package is not available
      warning("Could not load 450k annotation. Trying EPIC annotation as fallback...")
      array_type <- "EPIC"
    } else {
      return(anno_obj)
    }
  }
  
  if (array_type == "EPIC") {
    message("Loading EPIC annotation...")
    # Try the newer version first
    pkg_name <- "IlluminaHumanMethylationEPICanno.ilm10b4.hg19"
    anno_obj <- safe_get_annotation(pkg_name)
    
    if (is.null(anno_obj)) {
      # Try older version
      pkg_name <- "IlluminaHumanMethylationEPICanno.ilm10b3.hg19"
      anno_obj <- safe_get_annotation(pkg_name)
      
      if (!is.null(anno_obj)) {
        warning("Using older EPIC annotation (ilm10b3) as ilm10b4 package is not installed")
        return(anno_obj)
      }
    } else {
      return(anno_obj)
    }
  }
  
  if (array_type == "EPICv2" || is.null(anno_obj)) {
    if (array_type == "EPICv2") {
      message("Loading EPICv2 annotation...")
      message("Loading sesame package ...")
      
    } else {
      message("Trying EPICv2 annotation as last resort...")
    }
    
    pkg_name <- "IlluminaHumanMethylationEPICv2anno.20a1.hg38"
    anno_obj <- safe_get_annotation(pkg_name)
    
    if (!is.null(anno_obj)) {
      return(anno_obj)
    }
  }
}
#' Read methylation array data
#'
#' @param sample_sheet Sample sheet data frame
#' @param array_type Array type
#' @return RGChannelSet object
read_methylation_data <- function(sample_sheet, array_type = "auto") {
  # Read IDAT files
  message(" array data...")
  rgset <- read.metharray.exp(base = NULL, 
                             targets = sample_sheet, 
                             recursive = TRUE,
                             force = TRUE)
  
  # Set annotation
  if (array_type == "auto") {
    array_type <- determine_array_type(rgset)
    message("Auto-detected array type: ", array_type)
  }
  
  if (array_type == "450k") {
    rgset@annotation <- c(array = "IlluminaHumanMethylation450k", 
                         annotation = "ilmn12.hg19")
  } else if (array_type == "EPIC") {
    rgset@annotation <- c(array = "IlluminaHumanMethylationEPIC", 
                         annotation = "ilm10b4.hg19")
  } else if (array_type == "EPICv2") {
    rgset@annotation <- c(array = "IlluminaHumanMethylationEPICv2", 
                         annotation = "20a1.hg38")
  } else {
    stop("Unsupported array type: ", array_type)
  }
  
  return(rgset)
}

#' Preprocess methylation data
#'
#' @param sample_sheet Sample sheet data frame
#' @param array_type Array type
#' @param normalization Normalization method
#' @param threads Number of CPU threads to use
#' @param output_dir Output directory
#' @return List containing preprocessed data
preprocess_methylation <- function(sample_sheet, array_type = "auto", 
                                   normalization = "swan", 
                                   threads = 6,
                                   output_dir = ".") {
  # Build a BiocParallel backend appropriate for the current environment.
  #
  # MulticoreParam (fork-based) causes two known failures on LSF/bsub:
  #   1. "wrong args for environment subassignment" – forked workers inherit
  #      large S4 objects and crash during environment subassignment.
  #   2. "reached CPU time limit" – LSF tracks cumulative CPU time across all
  #      forked child processes and kills the job when the queue limit is hit.
  #
  # Solution: force SerialParam when running inside an LSF job (detected via
  # the LSB_JOBID environment variable), otherwise use MulticoreParam.
  in_lsf <- nchar(Sys.getenv("LSB_JOBID")) > 0
  bpparam <- tryCatch({
    if (in_lsf) {
      message("LSF job detected (LSB_JOBID=", Sys.getenv("LSB_JOBID"),
              "): using SerialParam to avoid fork-based CPU time limit issues.")
      BiocParallel::SerialParam()
    } else if (threads > 1 && .Platform$OS.type == "unix") {
      message("Parallel backend: MulticoreParam (", threads, " workers)")
      BiocParallel::MulticoreParam(threads)
    } else {
      message("Parallel backend: SerialParam (threads = ", threads, ")")
      BiocParallel::SerialParam()
    }
  }, error = function(e) {
    message("Backend creation failed (", conditionMessage(e), "); falling back to SerialParam.")
    BiocParallel::SerialParam()
  })
  BiocParallel::register(bpparam)

  # Read data
  rgset <- read_methylation_data(sample_sheet, array_type)
  print(rgset)
  message("Check rgSet: ", class(rgset)[1], " with ", ncol(rgset), " samples and ", nrow(rgset), " probes")
  save(rgset, file = file.path(output_dir, "rgset.RData"))

  # Get sample information
  sample_info <- data.frame(
    Sample_ID = sample_sheet$Sentrix_ID,
    Sample_Name = sample_sheet$Sample_Name
  )

  # Check normalization method and use default if invalid
  if (is.null(normalization) || !normalization %in% c("raw", "illumina", "functional", "quantile", "swan", "sesame")) {
    normalization <- "swan"
    warning("Invalid normalization method specified. Using 'SWAN' normalization instead.")
  }

  ####If EPICv2, then use sesame to prepare idats and extract beta values
  ## The prep = "CDPB" function will allow for technical corrections to be made.
  ## Specifically, C = Infer infinium I channel, D = dyeBiasNL, B = Noob Normalisation
  if (array_type == "EPICv2"){
    beta_v2 <- sesame::openSesame(sample_sheet$Basename, prep = "QCDB", platform= "EPICv2", func = getBetas, BPPARAM=bpparam,
                                  collapseToPfx = TRUE, collapseMethod = "mean")
    # Reorder beta table to be same order as sample_table
  }else {
    beta_v2 <- sesame::openSesame(sample_sheet$Basename, prep = "QCDB", func = getBetas, BPPARAM=bpparam)
  }
  beta <- beta_v2[, match(sample_sheet$Sentrix_ID, colnames(beta_v2))]
  message("Number of rows in beta: ", nrow(beta))

  ## Reorder detection_p table to be same order as sample_table
  detection_p <- sesame::openSesame(sample_sheet$Basename, func = pOOBAH, return.pval = TRUE, BPPARAM=bpparam)
  detection_p_df = as.data.frame(detection_p)
  detection_p_df <- detection_p_df[, match(sample_sheet$Sentrix_ID, colnames(detection_p_df))]
  message("Number of rows in detection_p: ", nrow(detection_p)) 
  
  # Add predicted sex
  message("Predicting sex based on methylation patterns...")
  pred_sex <- NULL 
  mset_raw <- preprocessRaw(rgset)
  gset <- mapToGenome(mset_raw)
  pred_sex <- getSex(gset)

  # Extract predicted sex values from S4 object
  if (is(pred_sex, "DataFrame") || is(pred_sex, "data.frame")) {
    sample_info$pred_sex <- as.character(pred_sex$predictedSex)
  } else {
    sample_info$pred_sex <- as.character(pred_sex)
  }

  fwrite(detection_p_df, file=file.path(output_dir, "detection_p.txt"), row.names=TRUE, sep="\t")
  m_values = BetaValueToMValue(beta)
  message("Done Preprocessing!")
  write.table(sample_info, file=file.path(output_dir, "sample_info.txt"), row.names=TRUE, sep="\t")

  # Create result object
  result <- list(
    rgset = rgset,
    beta = beta,
    m_values = m_values,
    detection_p = detection_p_df,
    sample_info = sample_info,
    array_type = if (array_type == "auto") determine_array_type(rgset) else array_type,
    normalization = normalization
    )

  
  return(result)
}

#' Write beta values to file
#'
#' @param beta Beta values matrix
#' @param file_path Output file path
write_beta_values <- function(beta, file_path) {
  message("Writing beta values to file: ", file_path)
  beta_df <- as.data.frame(beta)
  beta_df <- cbind(data.frame(ProbeID = rownames(beta)), beta_df)
  
  # Write to file using data.table for better performance
  fwrite(beta_df, file = file_path, sep = "\t", quote = FALSE)
}

#' Read beta values from file
#'
#' @param file_path Input file path
#' @return Beta values matrix
read_beta_values <- function(file_path) {
  message("Reading beta values from file: ", file_path)
  beta_df <- fread(file_path, data.table = FALSE)
  rownames(beta_df) <- beta_df$ProbeID
  beta_df$ProbeID <- NULL
  return(as.matrix(beta_df))
}
