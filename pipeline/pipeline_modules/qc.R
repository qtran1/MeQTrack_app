#' Perform quality control on methylation data
#'
#' @param rgset RGChannelSet object
#' @param beta_values Beta values matrix
#' @param sample_info Sample information data frame
#' @param detection_p_threshold Threshold for per-probe detection p-values
#' @param sample_detection_p_threshold Threshold for mean sample detection p-values
#' @param failed_probe_percent_threshold Max allowed percent of failed probes per sample
#' @param min_median_intensity Minimum acceptable median intensity (log2) for bisulfite check
#' @param output_dir Output directory for QC data/report (CSV, RData)
#' @param plots_dir  Output directory for QC plots (PDF/HTML). Defaults to
#'                   \code{file.path(output_dir, "plots")} for backward compat.
#' @return List of QC results and plots
perform_qc <- function(rgset, beta_values, sample_info,
                       detection_p_threshold          = 0.01,
                       sample_detection_p_threshold   = 0.05,
                       failed_probe_percent_threshold = 25,
                       min_median_intensity           = 10.5,
                       output_dir = ".",
                       plots_dir  = NULL) {

  if (is.null(plots_dir)) plots_dir <- file.path(output_dir, "plots")
  dir.create(plots_dir,  showWarnings = FALSE, recursive = TRUE)
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # ---------------------------------------------------------------------------
  # Detection p-values
  # ---------------------------------------------------------------------------
  message("Calculating detection p-values...")
  detP <- detectionP(rgset)

  mean_detP            <- colMeans(detP)
  failed_probes_count  <- colSums(detP > detection_p_threshold)
  failed_probes_percent <- failed_probes_count / nrow(detP) * 100

  # ---------------------------------------------------------------------------
  # Median intensity via minfi QC (raw, pre-normalisation)
  # ---------------------------------------------------------------------------
  message("Calculating median channel intensities (pre-normalisation)...")
  ms_raw        <- minfi::preprocessRaw(rgset)
  mfi_qc        <- minfi::getQC(ms_raw)
  median_meth   <- setNames(mfi_qc$mMed, rownames(mfi_qc))
  median_unmeth <- setNames(mfi_qc$uMed, rownames(mfi_qc))

  # ---------------------------------------------------------------------------
  # Build per-sample QC table
  # ---------------------------------------------------------------------------
  sample_ids <- colnames(detP)

  sample_qc <- data.frame(
    Sample_ID                    = sample_ids,
    Mean_Detection_P             = mean_detP[sample_ids],
    Failed_Probes_Count          = failed_probes_count[sample_ids],
    Failed_Probes_Percent        = round(failed_probes_percent[sample_ids], 3),
    Median_Meth_Intensity        = round(median_meth[sample_ids],   2),
    Median_Unmeth_Intensity      = round(median_unmeth[sample_ids], 2),
    stringsAsFactors = FALSE,
    row.names = NULL
  )

  # ---------------------------------------------------------------------------
  # Failure flags — NOTE: low intensity is INFORMATIONAL ONLY, not a failure.
  # Scanner gain settings legitimately vary across sites/batches; SWAN
  # normalisation may recover affected samples.
  # ---------------------------------------------------------------------------
  sample_qc$Flag_Mean_DetP     <- sample_qc$Mean_Detection_P      >= sample_detection_p_threshold
  sample_qc$Flag_Failed_Probes <- sample_qc$Failed_Probes_Percent >= failed_probe_percent_threshold

  # Informational intensity flag — does NOT contribute to Pass_QC
  sample_qc$Note_Low_Intensity <- sample_qc$Median_Meth_Intensity   < min_median_intensity |
                                  sample_qc$Median_Unmeth_Intensity  < min_median_intensity

  # Pass/fail based on detection p and failed probe rate only
  sample_qc$Pass_QC <- !(sample_qc$Flag_Mean_DetP | sample_qc$Flag_Failed_Probes)

  # ---------------------------------------------------------------------------
  # SWAN recovery check for low-intensity samples
  # Run SWAN normalisation and check whether median intensities improve above
  # the threshold — helps distinguish scanner gain artefacts from true failures.
  # ---------------------------------------------------------------------------
  low_int_ids <- sample_qc$Sample_ID[sample_qc$Note_Low_Intensity]

  sample_qc$SWAN_Median_Meth   <- NA_real_
  sample_qc$SWAN_Median_Unmeth <- NA_real_
  sample_qc$SWAN_Recoverable   <- NA

  if (length(low_int_ids) > 0) {
    message(sprintf(
      "%d sample(s) have low median intensity (< %.1f) — running SWAN normalisation check ...",
      length(low_int_ids), min_median_intensity
    ))
    tryCatch({
      ms_swan    <- minfi::preprocessSWAN(rgset, mSet = ms_raw, verbose = FALSE)
      qc_swan    <- minfi::getQC(ms_swan)
      swan_meth  <- setNames(qc_swan$mMed, rownames(qc_swan))
      swan_unmeth <- setNames(qc_swan$uMed, rownames(qc_swan))

      for (sid in low_int_ids) {
        if (sid %in% names(swan_meth)) {
          sm <- round(swan_meth[sid],   2)
          su <- round(swan_unmeth[sid], 2)
          sample_qc$SWAN_Median_Meth[sample_qc$Sample_ID   == sid] <- sm
          sample_qc$SWAN_Median_Unmeth[sample_qc$Sample_ID == sid] <- su
          # Recoverable = both channels exceed threshold after SWAN
          sample_qc$SWAN_Recoverable[sample_qc$Sample_ID   == sid] <-
            sm >= min_median_intensity & su >= min_median_intensity
        }
      }

      n_recovered <- sum(sample_qc$SWAN_Recoverable %in% TRUE)
      n_not       <- sum(sample_qc$SWAN_Recoverable %in% FALSE)
      message(sprintf(
        "  SWAN recovery: %d recoverable, %d not recoverable, %d not checked",
        n_recovered, n_not,
        sum(is.na(sample_qc$SWAN_Recoverable))
      ))
      if (n_not > 0) {
        not_rec <- sample_qc$Sample_ID[sample_qc$SWAN_Recoverable %in% FALSE]
        message("  Not recoverable after SWAN: ", paste(not_rec, collapse = ", "))
      }
    }, error = function(e) {
      warning("SWAN normalisation check failed: ", e$message)
    })
  }

  # ---------------------------------------------------------------------------
  # Human-readable failure reason (detection p / probe rate only)
  # and informational notes (intensity + SWAN result)
  # ---------------------------------------------------------------------------
  sample_qc$Failure_Reason <- apply(sample_qc, 1, function(r) {
    reasons <- character(0)
    if (isTRUE(as.logical(r["Flag_Mean_DetP"])))
      reasons <- c(reasons, sprintf("Mean detection p (%.4f) >= %.4f",
                                    as.numeric(r["Mean_Detection_P"]),
                                    sample_detection_p_threshold))
    if (isTRUE(as.logical(r["Flag_Failed_Probes"])))
      reasons <- c(reasons, sprintf("Failed probes (%.2f%%) >= %.1f%%",
                                    as.numeric(r["Failed_Probes_Percent"]),
                                    failed_probe_percent_threshold))
    if (length(reasons) == 0) "PASS" else paste(reasons, collapse = "; ")
  })

  sample_qc$Notes <- apply(sample_qc, 1, function(r) {
    notes <- character(0)
    if (isTRUE(as.logical(r["Note_Low_Intensity"]))) {
      swan_rec <- r["SWAN_Recoverable"]
      intensity_note <- sprintf(
        "Low pre-norm intensity (Meth=%.1f, Unmeth=%.1f; threshold=%.1f)",
        as.numeric(r["Median_Meth_Intensity"]),
        as.numeric(r["Median_Unmeth_Intensity"]),
        min_median_intensity
      )
      swan_note <- if (is.na(swan_rec)) {
        "SWAN check not run"
      } else if (isTRUE(as.logical(swan_rec))) {
        sprintf("recoverable after SWAN (Meth=%.1f, Unmeth=%.1f)",
                as.numeric(r["SWAN_Median_Meth"]),
                as.numeric(r["SWAN_Median_Unmeth"]))
      } else {
        sprintf("NOT recoverable after SWAN (Meth=%.1f, Unmeth=%.1f)",
                as.numeric(r["SWAN_Median_Meth"]),
                as.numeric(r["SWAN_Median_Unmeth"]))
      }
      notes <- c(notes, paste0(intensity_note, " — ", swan_note))
    }
    if (length(notes) == 0) "" else paste(notes, collapse = "; ")
  })

  # Merge with sample info (keep all QC rows)
  sample_qc <- merge(sample_qc, sample_info, by = "Sample_ID", all.x = TRUE)

  # ---------------------------------------------------------------------------
  # Save CSV report (key QC columns first, then sample metadata columns)
  # ---------------------------------------------------------------------------
  key_cols  <- c("Sample_ID", "Pass_QC", "Failure_Reason", "Notes",
                 "Mean_Detection_P", "Failed_Probes_Count", "Failed_Probes_Percent",
                 "Median_Meth_Intensity", "Median_Unmeth_Intensity",
                 "Flag_Mean_DetP", "Flag_Failed_Probes", "Note_Low_Intensity",
                 "SWAN_Median_Meth", "SWAN_Median_Unmeth", "SWAN_Recoverable")
  extra_cols <- setdiff(names(sample_qc), key_cols)
  col_order  <- c(intersect(key_cols, names(sample_qc)), extra_cols)

  out_path <- file.path(output_dir, "sample_qc_report.csv")
  write.csv(sample_qc[, col_order],
            file      = out_path,
            row.names = FALSE)
  message("QC report saved: ", out_path)

  # ---------------------------------------------------------------------------
  # QC plots
  # ---------------------------------------------------------------------------
  qc_plots <- generate_qc_plots(rgset, detP, beta_values, sample_qc,
                                detection_p_threshold, sample_detection_p_threshold,
                                plots_dir)

  # minfi PDF QC report
  tryCatch(
    minfi::qcReport(rgset,
                    sampNames = if ("Sample_Name" %in% names(sample_qc))
                                  sample_qc$Sample_Name
                                else
                                  sample_qc$Sample_ID,
                    pdf = file.path(plots_dir, "minfi_qcReport.pdf")),
    error = function(e) warning("minfi::qcReport failed: ", e$message)
  )

  # ---------------------------------------------------------------------------
  # Summary message
  # ---------------------------------------------------------------------------
  n_pass     <- sum(sample_qc$Pass_QC)
  n_fail     <- nrow(sample_qc) - n_pass
  n_low_int  <- sum(sample_qc$Note_Low_Intensity)
  message(sprintf("QC complete: %d passed, %d failed (see sample_qc_report.csv)",
                  n_pass, n_fail))
  if (n_fail > 0) {
    message("Failed samples:")
    failed_df <- sample_qc[!sample_qc$Pass_QC, c("Sample_ID", "Failure_Reason")]
    for (i in seq_len(nrow(failed_df)))
      message(sprintf("  %s: %s", failed_df$Sample_ID[i], failed_df$Failure_Reason[i]))
  }
  if (n_low_int > 0) {
    message(sprintf(
      "%d sample(s) flagged for low pre-normalisation intensity (informational, not failed):",
      n_low_int
    ))
    low_df <- sample_qc[sample_qc$Note_Low_Intensity, c("Sample_ID", "Notes")]
    for (i in seq_len(nrow(low_df)))
      message(sprintf("  %s: %s", low_df$Sample_ID[i], low_df$Notes[i]))
  }

  list(
    sample_qc                    = sample_qc,
    passed_samples               = sample_qc$Sample_ID[sample_qc$Pass_QC],
    failed_samples               = sample_qc$Sample_ID[!sample_qc$Pass_QC],
    low_intensity_samples        = sample_qc$Sample_ID[sample_qc$Note_Low_Intensity],
    swan_recoverable             = sample_qc$Sample_ID[sample_qc$SWAN_Recoverable %in% TRUE],
    swan_not_recoverable         = sample_qc$Sample_ID[sample_qc$SWAN_Recoverable %in% FALSE],
    detection_p                  = detP,
    detection_p_threshold        = detection_p_threshold,
    sample_detection_p_threshold = sample_detection_p_threshold,
    plots                        = qc_plots
  )
}


#' Generate QC plots
#'
#' @param rgset RGChannelSet object
#' @param detP Detection p-values matrix
#' @param beta_values Beta values matrix
#' @param sample_qc Sample QC metrics data frame
#' @param detection_p_threshold Threshold for detection p-values
#' @param sample_detection_p_threshold Threshold for mean sample detection p-values
#' @param output_dir Output directory for plots
#' @return List of plot paths
generate_qc_plots <- function(rgset, detP, beta_values, sample_qc, 
                              detection_p_threshold = 0.01,
                              sample_detection_p_threshold = 0.05,
                              output_dir = ".") {
  plots <- list()
  
  # 1. Mean detection p-value plot
  message("Generating mean detection p-value plot...")
  pdf_path <- file.path(output_dir, "mean_detection_pvalue.pdf")
  pdf(pdf_path, height = 8, width = 12)
  barplot(sample_qc$Mean_Detection_P, 
          names.arg = sample_qc$Sample_ID, 
          las = 2, 
          cex.names = 0.8,
          col = ifelse(sample_qc$Pass_QC, "forestgreen", "firebrick"),
          main = "Mean Detection P-value by Sample",
          ylab = "Mean Detection P-value")
  abline(h = sample_detection_p_threshold, col = "red", lty = 2)
  text(x = par("usr")[2] * 0.95, 
       y = sample_detection_p_threshold * 1.1, 
       labels = paste("Threshold (", sample_detection_p_threshold, ")", sep = ""), 
       cex = 0.8)
  dev.off()
  plots$mean_detection_pvalue <- pdf_path
  
  # 2. Sample density plot
  message("Generating sample density plot...")
  pdf_path <- file.path(output_dir, "beta_density.pdf")
  pdf(pdf_path, height = 8, width = 10)
  densityPlot(beta_values, 
              sampGroups = sample_qc$Pass_QC, 
              main = "Beta Value Density Plot",
              legend = FALSE)
  legend("topright", 
         legend = c("Pass QC", "Fail QC"), 
         col = c("black", "red"), 
         lty = 1)
  dev.off()
  plots$beta_density <- pdf_path
  
  # 3. Bean plot for beta distribution
  message("Generating bean plot...")
  pdf_path <- file.path(output_dir, "beta_bean_plot.pdf")
  pdf(pdf_path, height = 8, width = 10)
  densityBeanPlot(beta_values, 
                  sampGroups = sample_qc$Pass_QC,
                  main = "Beta Value Distribution")
  dev.off()
  plots$beta_bean <- pdf_path
  
 
  # 4. MDS plot if we have more than 3 samples
  if (ncol(beta_values) > 3) {
    message("Generating MDS plot...")
    pdf_path <- file.path(output_dir, "mds_plot.pdf")
    pdf(pdf_path, height = 8, width = 10)
    
    # Use tryCatch in case MDS calculation fails
    tryCatch({
      mds <- cmdscale(dist(t(beta_values)), k = 3)
      colnames(mds) <- c("PC1", "PC2", "PC3")
      par(mfrow = c(2, 1))
      plot(mds[, 1], mds[, 2], 
           col = ifelse(sample_qc$Pass_QC, "blue", "red"),
           pch = 19,
           main = "MDS Plot - PC1 vs PC2",
           xlab = "PC1", ylab = "PC2")
      text(mds[, 1], mds[, 2], labels = sample_qc$Sample_ID, pos = 3, cex = 0.8)
      
      plot(mds[, 1], mds[, 3], 
           col = ifelse(sample_qc$Pass_QC, "blue", "red"),
           pch = 19,
           main = "MDS Plot - PC1 vs PC3",
           xlab = "PC1", ylab = "PC3")
      text(mds[, 1], mds[, 3], labels = sample_qc$Sample_ID, pos = 3, cex = 0.8)
    }, error = function(e) {
      plot(1, 1, type = "n", xlab = "", ylab = "", axes = FALSE)
      text(1, 1, "MDS plot could not be generated.\nError: ")
      text(1, 0.8, e$message, col = "red")
      warning("Could not generate MDS plot: ", e$message)
    })
    
    dev.off()
    plots$mds <- pdf_path
  }
  
  # Create interactive plots using plotly if requested
  if (requireNamespace("plotly", quietly = TRUE) && 
      requireNamespace("htmlwidgets", quietly = TRUE)) {
    
    # Try to create interactive plots with error handling
    tryCatch({
      # Interactive density plot
      message("Generating interactive density plot...")
      density_data <- lapply(1:ncol(beta_values), function(i) {
        dens <- density(beta_values[, i], na.rm = TRUE)
        data.frame(
          x = dens$x,
          y = dens$y,
          Sample = colnames(beta_values)[i],
          Pass_QC = sample_qc$Pass_QC[match(colnames(beta_values)[i], sample_qc$Sample_ID)]
        )
      })
      density_data <- do.call(rbind, density_data)
      
      p <- plotly::plot_ly()
      for (sample in unique(density_data$Sample)) {
        subset_data <- density_data[density_data$Sample == sample, ]
        pass_qc <- subset_data$Pass_QC[1]
        p <- p %>% plotly::add_lines(
          data = subset_data,
          x = ~x, 
          y = ~y, 
          name = sample,
          line = list(color = ifelse(pass_qc, "blue", "red"))
        )
      }
      p <- p %>% plotly::layout(
        title = "Beta Value Density Distribution",
        xaxis = list(title = "Beta Value"),
        yaxis = list(title = "Density")
      )
      
      html_path <- file.path(output_dir, "interactive_density_plot.html")
      htmlwidgets::saveWidget(plotly::as_widget(p), html_path)
      plots$interactive_density <- html_path
      
      # Interactive MDS plot if we have more than 3 samples
      if (ncol(beta_values) > 3 && exists("mds")) {
        message("Generating interactive MDS plot...")
        mds_data <- as.data.frame(mds)
        mds_data$Sample_ID <- rownames(mds_data)
        mds_data <- merge(mds_data, sample_qc, by = "Sample_ID")
        
        p <- plotly::plot_ly(
          data = mds_data,
          x = ~PC1, 
          y = ~PC2, 
          z = ~PC3,
          color = ~Pass_QC,
          colors = c("red", "blue"),
          text = ~Sample_ID,
          type = "scatter3d",
          mode = "markers",
          marker = list(size = 5)
        ) %>% 
          plotly::layout(
            title = "3D MDS Plot",
            scene = list(
              xaxis = list(title = "PC1"),
              yaxis = list(title = "PC2"),
              zaxis = list(title = "PC3")
            )
          )
        
        html_path <- file.path(output_dir, "interactive_mds_plot.html")
        htmlwidgets::saveWidget(plotly::as_widget(p), html_path)
        plots$interactive_mds <- html_path
      }
    }, error = function(e) {
      warning("Could not generate interactive plots: ", e$message)
    })
  }
  
  return(plots)
}