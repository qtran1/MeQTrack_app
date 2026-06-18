# app/R/qc_module.R
# ---------------------------------------------------------------------------
# QC view: per-sample DT table + the pipeline's own interactive QC HTML
# plots embedded via iframe.
#
# We don't re-render QC plots from the underlying minfi QC object — the
# pipeline's `figures/qc/interactive_*.html` files are already plotly
# outputs self-contained with all their assets. Embedding them is faster,
# smaller, and matches what the shareable HTML report already shows.
# ---------------------------------------------------------------------------

# Plain-English explanations attached as native title attributes to the QC
# table's column headers. Hover-to-read; no Bootstrap init needed.
QC_COL_TOOLTIPS <- list(
  Sample_ID               = "Sentrix ID identifying this sample.",
  Mean_Detection_P        = "Average detection p-value across all probes for this sample. Lower is better; healthy samples typically sit near 0.001.",
  Failed_Probes_Count     = "Number of probes whose detection p-value exceeds the per-probe threshold (default 0.01).",
  Failed_Probes_Percent   = "Percent of probes that failed the detection-p check, within this sample. Compared against the failed-probe % threshold.",
  Median_Meth_Intensity   = "log2 median methylated-channel intensity (raw, pre-normalization).",
  Median_Unmeth_Intensity = "log2 median unmethylated-channel intensity (raw, pre-normalization).",
  Pass_QC                 = "TRUE = sample passed both the mean-detection-p and failed-probe checks.",
  Flag_Mean_DetP          = "TRUE when the sample's mean detection-p exceeds the cohort threshold (default 0.05).",
  Flag_Failed_Probes      = "TRUE when the failed-probe percent reaches the threshold (default 25%).",
  GCT_Score               = "Bisulfite-conversion control (GCT, Zhou et al. 2017). ~1.0 = complete conversion; higher = more incomplete. NA when not computed (e.g. EPICv2).",
  Flag_GCT                = "TRUE when the GCT score exceeds the conversion threshold (default 1.3) — incomplete bisulfite conversion. Contributes to Pass_QC (fails the sample).",
  Sesame_Sex              = "Predicted sex from sesame's curated X/Y probe model (MALE/FEMALE). Informational — compare against expected sex and the minfi prediction to catch sample swaps.",
  Horvath_Age             = "Predicted epigenetic age (years) from the Horvath 353-CpG clock (Horvath 2013). Informational — a large gap from the known age can flag a mislabelled sample.",
  Note_Low_Intensity      = "Informational only — does NOT contribute to Pass_QC. Flags samples with low median intensities, often a scanner-gain issue that SWAN normalization can recover.",
  SWAN_Median_Meth        = "Median methylated intensity AFTER SWAN normalization. Computed only for low-intensity samples.",
  SWAN_Median_Unmeth      = "Median unmethylated intensity after SWAN normalization. Computed only for low-intensity samples.",
  SWAN_Recoverable        = "TRUE when SWAN normalization brings intensities above threshold — the low-intensity flag was a scanner-gain artifact, not a true failure."
)

# Tooltips for the standalone bisulfite-conversion (GCT) QC table.
QC_CONVERSION_TOOLTIPS <- list(
  Sample_ID  = "Sentrix ID identifying this sample.",
  GCT_Score  = "Bisulfite-conversion control (GCT score, Zhou et al. 2017). A value near 1.0 means complete conversion; higher values indicate more residual incomplete conversion. Informational only — does not affect Pass_QC.",
  Array_Type = "Array platform detected for this sample.",
  Note       = "Empty when GCT was computed. Otherwise explains why it was skipped (e.g. EPICv2 not yet supported)."
)

qc_module_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::navset_tab(
    bslib::nav_panel(
      "Sample metrics",
      shiny::uiOutput(ns("summary_banner")),
      shinycssloaders::withSpinner(
        DT::DTOutput(ns("qc_table")),
        type = 7, color = COLORS$primary
      )
    ),
    bslib::nav_panel(
      "Conversion QC",
      shinycssloaders::withSpinner(
        DT::DTOutput(ns("conversion_table")),
        type = 7, color = COLORS$primary
      )
    ),
    bslib::nav_panel(
      "Density plot",
      shiny::uiOutput(ns("density_frame"))
    ),
    bslib::nav_panel(
      "MDS plot",
      shiny::uiOutput(ns("mds_frame"))
    )
  )
}

qc_module_server <- function(id, results) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    output$summary_banner <- shiny::renderUI({
      r <- results()
      if (is.null(r)) {
        return(shiny::div(class = "alert alert-secondary",
                          "No completed run yet. Run the pipeline first ",
                          "(Run tab), then this view populates automatically."))
      }
      if (is.null(r$qc_report)) {
        return(shiny::div(class = "alert alert-secondary",
                          "QC results not available yet — waiting for the ",
                          "QC step to finish."))
      }
      n_total <- nrow(r$qc_report)
      n_fail  <- length(r$qc_fail_ids)
      cls <- if (n_fail == 0) "alert alert-success" else "alert alert-warning"
      msg <- if (n_fail == 0) {
        sprintf("%d of %d sample(s) passed QC.", n_total, n_total)
      } else {
        sprintf("%d of %d sample(s) passed QC. %d failed: %s",
                n_total - n_fail, n_total, n_fail,
                paste(r$qc_fail_ids, collapse = ", "))
      }
      shiny::div(class = cls, role = "alert", msg)
    })

    output$qc_table <- DT::renderDT({
      r <- results()
      if (is.null(r) || is.null(r$qc_report)) return(NULL)
      df <- r$qc_report
      # Pass_QC can read as logical, character, or integer depending on the
      # upstream CSV. Normalize to character "TRUE"/"FALSE" so DT's JS-side
      # styleEqual match is deterministic.
      if ("Pass_QC" %in% colnames(df)) {
        df$Pass_QC <- ifelse(as.logical(df$Pass_QC), "TRUE", "FALSE")
      }
      numeric_cols <- which(vapply(df, is.numeric, logical(1)))
      dt <- DT::datatable(
        df,
        rownames = FALSE,
        selection = "none",
        class = "stripe hover compact",
        width = "100%",
        options = list(
          pageLength = 25,
          scrollX = TRUE,
          autoWidth = FALSE,
          dom = "ltip",
          headerCallback = dt_header_tooltips(QC_COL_TOOLTIPS),
          columnDefs = if (length(numeric_cols)) list(list(
            className = "dt-right",
            targets = as.integer(numeric_cols - 1L)
          )) else list()
        )
      )
      if ("Pass_QC" %in% colnames(df)) {
        dt <- DT::formatStyle(
          dt, "Pass_QC", target = "row",
          backgroundColor = DT::styleEqual(
            c("TRUE", "FALSE"), c("#ffffff", "#fde2e4")
          )
        )
      }
      dt
    })

    output$conversion_table <- DT::renderDT({
      r <- results()
      if (is.null(r) || is.null(r$conversion_qc)) return(NULL)
      df <- r$conversion_qc
      numeric_cols <- which(vapply(df, is.numeric, logical(1)))
      DT::datatable(
        df,
        rownames = FALSE,
        selection = "none",
        class = "stripe hover compact",
        width = "100%",
        options = list(
          pageLength = 25,
          scrollX = TRUE,
          autoWidth = FALSE,
          dom = "ltip",
          headerCallback = dt_header_tooltips(QC_CONVERSION_TOOLTIPS),
          columnDefs = if (length(numeric_cols)) list(list(
            className = "dt-right",
            targets = as.integer(numeric_cols - 1L)
          )) else list()
        )
      )
    })

    output$density_frame <- shiny::renderUI({
      qc_iframe(results(),
                rel_path = "figures/qc/interactive_density_plot.html",
                fallback = "Interactive density plot not found.")
    })

    output$mds_frame <- shiny::renderUI({
      qc_iframe(results(),
                rel_path = "figures/qc/interactive_mds_plot.html",
                fallback = "Interactive MDS plot not found.")
    })
  })
}

# Render an iframe pointing at a file under the run's URL base. If the
# file doesn't exist on disk, render a friendly placeholder instead.
qc_iframe <- function(results, rel_path, fallback) {
  if (is.null(results)) {
    return(shiny::div(class = "alert alert-secondary",
                      "No completed run yet."))
  }
  disk_path <- file.path(results$run_dir, rel_path)
  if (!file.exists(disk_path)) {
    return(shiny::div(class = "alert alert-warning", fallback))
  }
  url <- paste0(results$run_url_base, "/", rel_path)
  shiny::tags$iframe(
    src = url,
    style = "width: 100%; height: 75vh; border: 1px solid #dee2e6; border-radius: 4px;"
  )
}
