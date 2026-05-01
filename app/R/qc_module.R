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
          dom = "ltip"
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
