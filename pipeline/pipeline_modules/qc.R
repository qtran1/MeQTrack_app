#' Predicted age from the Horvath 353-CpG epigenetic clock (Horvath 2013)
#'
#' Computed directly from the Horvath353 coefficient table shipped in
#' sesameData's \code{age.inference}. NOTE: sesame 1.30.0's \code{predictAge()}
#' is incompatible with this bundled data (it expects a newer model object with
#' a \code{param$slope}/\code{response2age} structure), so we apply the linear
#' model and Horvath's inverse age transform ourselves.
#'
#' @param betas Named numeric vector of beta values (names = cg probe IDs)
#' @param horvath Horvath353 coefficient data frame (CpGmarker, CoefficientTraining)
#' @param min_probes Minimum matched clock probes required; below this -> NA
#' @return Predicted age in years, or NA if too few probes match
horvath_age <- function(betas, horvath, min_probes = 200) {
  intercept <- horvath$CoefficientTraining[horvath$CpGmarker == "(Intercept)"]
  keep      <- horvath$CpGmarker != "(Intercept)"
  cg        <- horvath$CpGmarker[keep]
  coef      <- horvath$CoefficientTraining[keep]
  b         <- betas[cg]
  ok        <- !is.na(b)
  if (sum(ok) < min_probes) return(NA_real_)
  s <- intercept + sum(coef[ok] * b[ok])
  # Horvath 2013 inverse age transform (adult.age = 20)
  adult_age <- 20
  if (s < 0) (1 + adult_age) * exp(s) - 1 else (1 + adult_age) * s + adult_age
}

#' Per-sample sesame sample-integrity inferences (sex + epigenetic age)
#'
#' These are valuable for detecting sample swaps / mislabelling. Sex uses
#' sesame's curated X/Y probe model; age uses the Horvath353 clock. Both
#' operate on the beta matrix already computed upstream. Wrapped so a failure
#' (e.g. unsupported platform, missing sesameData cache) yields NA, never an
#' error. sesame 1.30.0 does not provide karyotype or ethnicity inference.
#'
#' @param beta_values Beta matrix (probes x samples)
#' @return data.frame(Sample_ID, Sesame_Sex, Horvath_Age)
compute_sample_inferences <- function(beta_values) {
  sample_ids <- colnames(beta_values)
  out <- data.frame(Sample_ID = sample_ids,
                    Sesame_Sex = NA_character_,
                    Horvath_Age = NA_real_,
                    stringsAsFactors = FALSE)

  # Sex — sesame::inferSex auto-detects platform from probe names.
  out$Sesame_Sex <- vapply(sample_ids, function(sid) {
    tryCatch(as.character(sesame::inferSex(beta_values[, sid])),
             error = function(e) NA_character_)
  }, character(1))

  # Age — Horvath353 from sesameData's age.inference table.
  horvath <- tryCatch(sesameData::sesameDataGet("age.inference")$Horvath353,
                      error = function(e) {
                        warning("Could not load Horvath353 age model: ",
                                conditionMessage(e))
                        NULL
                      })
  if (!is.null(horvath)) {
    out$Horvath_Age <- round(vapply(sample_ids, function(sid) {
      tryCatch(horvath_age(beta_values[, sid], horvath),
               error = function(e) NA_real_)
    }, numeric(1)), 1)
  }
  out
}

#' Perform quality control on methylation data
#'
#' @param rgset RGChannelSet object
#' @param beta_values Beta values matrix
#' @param sample_info Sample information data frame
#' @param detection_p_threshold Threshold for per-probe detection p-values
#' @param sample_detection_p_threshold Threshold for mean sample detection p-values
#' @param failed_probe_percent_threshold Max allowed percent of failed probes per sample
#' @param min_median_intensity Minimum acceptable median intensity (log2) for bisulfite check
#' @param gct Optional data frame of GCT bisulfite-conversion scores
#'   (columns Sample_ID, GCT_Score) from the preprocess step. When supplied,
#'   samples whose GCT exceeds \code{max_gct_score} fail QC. Samples with NA
#'   GCT (e.g. EPICv2, where GCT is not yet computed) are never failed on it.
#' @param max_gct_score GCT failure threshold. A score near 1.0 means complete
#'   bisulfite conversion; higher means more incomplete. Samples with
#'   GCT > max_gct_score fail QC.
#' @param output_dir Output directory for QC data/report (CSV, RData)
#' @param plots_dir  Output directory for QC plots (PDF/HTML). Defaults to
#'                   \code{file.path(output_dir, "plots")} for backward compat.
#' @return List of QC results and plots
perform_qc <- function(rgset, beta_values, sample_info,
                       detection_p_threshold          = 0.01,
                       sample_detection_p_threshold   = 0.05,
                       failed_probe_percent_threshold = 25,
                       min_median_intensity           = 10.5,
                       gct                            = NULL,
                       max_gct_score                  = 1.3,
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
  # Sample-integrity inferences (sesame): predicted sex + Horvath epigenetic
  # age. Informational only — surfaced for sample-swap / mislabelling checks,
  # they do NOT contribute to Pass_QC. Aligned to sample_qc by Sample_ID.
  # ---------------------------------------------------------------------------
  message("Inferring sample sex and epigenetic age (sesame)...")
  inferences <- tryCatch(
    compute_sample_inferences(beta_values),
    error = function(e) {
      warning("Sample inference (sex/age) failed: ", conditionMessage(e))
      NULL
    }
  )
  sample_qc$Sesame_Sex  <- NA_character_
  sample_qc$Horvath_Age <- NA_real_
  if (!is.null(inferences)) {
    sex_lookup <- setNames(inferences$Sesame_Sex,  inferences$Sample_ID)
    age_lookup <- setNames(inferences$Horvath_Age, inferences$Sample_ID)
    sample_qc$Sesame_Sex  <- as.character(sex_lookup[sample_qc$Sample_ID])
    sample_qc$Horvath_Age <- as.numeric(age_lookup[sample_qc$Sample_ID])
  }

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

  # ---------------------------------------------------------------------------
  # GCT bisulfite-conversion gate. Merge the per-sample GCT score (from the
  # preprocess step) and fail samples whose conversion is too incomplete.
  # NA GCT (e.g. EPICv2, not yet computed) is never a failure — Flag_GCT FALSE.
  # ---------------------------------------------------------------------------
  sample_qc$GCT_Score <- NA_real_
  if (!is.null(gct) && all(c("Sample_ID", "GCT_Score") %in% names(gct))) {
    gct_lookup <- setNames(gct$GCT_Score, as.character(gct$Sample_ID))
    sample_qc$GCT_Score <- as.numeric(gct_lookup[sample_qc$Sample_ID])
  }
  sample_qc$Flag_GCT <- !is.na(sample_qc$GCT_Score) &
                        sample_qc$GCT_Score > max_gct_score

  # Pass/fail based on detection p, failed probe rate, and GCT conversion.
  sample_qc$Pass_QC <- !(sample_qc$Flag_Mean_DetP |
                         sample_qc$Flag_Failed_Probes |
                         sample_qc$Flag_GCT)

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
    if (isTRUE(as.logical(r["Flag_GCT"])))
      reasons <- c(reasons, sprintf("Incomplete bisulfite conversion (GCT %.3f > %.2f)",
                                    as.numeric(r["GCT_Score"]),
                                    max_gct_score))
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
                 "GCT_Score", "Sesame_Sex", "Horvath_Age",
                 "Flag_Mean_DetP", "Flag_Failed_Probes", "Flag_GCT", "Note_Low_Intensity",
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
  n_gct_fail <- sum(sample_qc$Flag_GCT)
  if (n_gct_fail > 0) {
    message(sprintf(
      "%d sample(s) FAILED for incomplete bisulfite conversion (GCT > %.2f):",
      n_gct_fail, max_gct_score
    ))
    gct_df <- sample_qc[sample_qc$Flag_GCT, c("Sample_ID", "GCT_Score")]
    for (i in seq_len(nrow(gct_df)))
      message(sprintf("  %s: GCT %.3f", gct_df$Sample_ID[i], gct_df$GCT_Score[i]))
  }

  list(
    sample_qc                    = sample_qc,
    passed_samples               = sample_qc$Sample_ID[sample_qc$Pass_QC],
    failed_samples               = sample_qc$Sample_ID[!sample_qc$Pass_QC],
    low_intensity_samples        = sample_qc$Sample_ID[sample_qc$Note_Low_Intensity],
    swan_recoverable             = sample_qc$Sample_ID[sample_qc$SWAN_Recoverable %in% TRUE],
    swan_not_recoverable         = sample_qc$Sample_ID[sample_qc$SWAN_Recoverable %in% FALSE],
    gct_failed_samples           = sample_qc$Sample_ID[sample_qc$Flag_GCT],
    detection_p                  = detP,
    detection_p_threshold        = detection_p_threshold,
    sample_detection_p_threshold = sample_detection_p_threshold,
    max_gct_score                = max_gct_score,
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
        # Theme colors: teal for QC pass, red for QC fail.
        p <- p %>% plotly::add_lines(
          data = subset_data,
          x = ~x,
          y = ~y,
          name = sample,
          opacity = 0.9,
          line = list(color = ifelse(pass_qc, "#0d9488", "#ef4444"))
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
        
        # Uniform marker styling: teal fill (#018571), brown border
        # (#a6611a). Pass/fail signaling is surfaced on the QC tab's
        # table; keeping the 3D MDS colors uniform makes the point cloud
        # read cleaner.
        p <- plotly::plot_ly(
          data = mds_data,
          x = ~PC1,
          y = ~PC2,
          z = ~PC3,
          text = ~Sample_ID,
          type = "scatter3d",
          mode = "markers",
          marker = list(
            size = 5,
            opacity = 0.9,
            color = "#018571",
            line = list(width = 0.8, color = "#a6611a")
          )
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