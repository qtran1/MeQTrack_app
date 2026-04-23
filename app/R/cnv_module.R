# app/R/cnv_module.R
# ---------------------------------------------------------------------------
# CNV views:
#   Per-sample — dropdown selector + embedded per-sample genome-wide PDF
#     (the pipeline already renders these via conumee2's CNV.genomeplot;
#     re-rendering in-browser would be expensive and redundant).
#   Frequency — embedded cnv_frequency_plot.pdf.
#   Heatmap   — simple segment-level ggplot → plotly from cnv_results$segments.
#
# The pipeline's standalone pipeline/cnv_heatmap.R is ~700 lines of Rscript
# CLI with optparse and is not easily sourced as a library. Re-implementing
# its full functionality (metadata sidebars, palette control, etc.) is
# deferred to a later wave; Wave 4 ships a minimal in-browser heatmap that
# covers the acceptance criteria.
# ---------------------------------------------------------------------------

cnv_module_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::navset_tab(
    bslib::nav_panel(
      "Per-sample",
      shiny::fluidRow(
        shiny::column(3,
          shiny::h6("Sample"),
          shiny::uiOutput(ns("sample_selector")),
          shiny::uiOutput(ns("sample_qc_note"))
        ),
        shiny::column(9, shiny::uiOutput(ns("cnv_pdf_frame")))
      )
    ),
    bslib::nav_panel(
      "Frequency",
      shiny::uiOutput(ns("frequency_frame"))
    ),
    bslib::nav_panel(
      "Heatmap",
      plotly::plotlyOutput(ns("heatmap_plot"), height = "600px")
    )
  )
}

cnv_module_server <- function(id, results) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # Sample selector is populated from the QC report (authoritative list).
    output$sample_selector <- shiny::renderUI({
      r <- results()
      if (is.null(r) || is.null(r$qc_report)) {
        return(shiny::tags$em(class = "text-muted",
                              "No completed run yet."))
      }
      ids <- as.character(r$qc_report$Sample_ID)
      shiny::selectInput(ns("sample"), label = NULL,
                         choices = ids, selected = ids[1])
    })

    output$sample_qc_note <- shiny::renderUI({
      r <- results()
      sid <- input$sample
      if (is.null(r) || is.null(sid)) return(NULL)
      if (sid %in% r$qc_fail_ids) {
        shiny::div(class = "alert alert-warning mt-2",
                   shiny::icon("triangle-exclamation"),
                   " This sample failed QC.")
      } else NULL
    })

    output$cnv_pdf_frame <- shiny::renderUI({
      r <- results()
      sid <- input$sample
      if (is.null(r) || is.null(sid)) {
        return(shiny::div(class = "alert alert-secondary",
                          "Select a sample to view its CNV profile."))
      }
      rel <- file.path("figures", "cnv",
                       sprintf("%s_cnv_profile.pdf", sid))
      disk <- file.path(r$run_dir, rel)
      if (!file.exists(disk)) {
        return(shiny::div(class = "alert alert-warning",
                          sprintf("CNV profile not found for %s.", sid)))
      }
      shiny::tags$iframe(
        src = paste0(r$run_url_base, "/", rel),
        style = "width: 100%; height: 75vh; border: 1px solid #dee2e6; border-radius: 4px;"
      )
    })

    output$frequency_frame <- shiny::renderUI({
      r <- results()
      if (is.null(r)) {
        return(shiny::div(class = "alert alert-secondary",
                          "No completed run yet."))
      }
      rel <- "figures/cnv/cnv_frequency_plot.pdf"
      disk <- file.path(r$run_dir, rel)
      if (!file.exists(disk)) {
        return(shiny::div(class = "alert alert-warning",
                          "Frequency plot not found."))
      }
      shiny::tags$iframe(
        src = paste0(r$run_url_base, "/", rel),
        style = "width: 100%; height: 75vh; border: 1px solid #dee2e6; border-radius: 4px;"
      )
    })

    output$heatmap_plot <- plotly::renderPlotly({
      r <- results()
      if (is.null(r) || is.null(r$cnv) || is.null(r$cnv$segments)) {
        return(plotly::plot_ly() |>
                 plotly::layout(title = "No CNV segments available."))
      }
      cnv_segment_heatmap(r$cnv$segments, r$qc_fail_ids)
    })
  })
}

# ---------------------------------------------------------------------------
# Heatmap renderer — simple segment view
# ---------------------------------------------------------------------------

# Minimal genome-ordered segment heatmap. Rows = samples, x = segment
# genomic coordinate (treating chromosomes as ordered stripes), fill =
# seg.mean clamped to ±1.5.
cnv_segment_heatmap <- function(segments, qc_fail_ids) {
  df <- as.data.frame(segments)
  # Flexible column detection (pipeline & cnv_heatmap.R both touch these).
  col <- function(names, df) {
    for (n in names) if (n %in% colnames(df)) return(n)
    NULL
  }
  c_id   <- col(c("ID", "Sample", "sample_id", "Sample_ID"), df)
  c_chr  <- col(c("chrom", "chromosome", "Chr"), df)
  c_from <- col(c("loc.start", "start", "Start"), df)
  c_to   <- col(c("loc.end", "end", "End"), df)
  c_mean <- col(c("seg.mean", "Seg_Mean", "mean"), df)

  if (any(vapply(list(c_id, c_chr, c_from, c_to, c_mean), is.null, logical(1)))) {
    return(plotly::plot_ly() |>
             plotly::layout(title = "Segments missing expected columns"))
  }

  df <- data.frame(
    sample = as.character(df[[c_id]]),
    chr    = as.character(df[[c_chr]]),
    from   = as.numeric(df[[c_from]]),
    to     = as.numeric(df[[c_to]]),
    mean   = pmax(pmin(as.numeric(df[[c_mean]]), 1.5), -1.5),
    stringsAsFactors = FALSE
  )

  # Order chromosomes naturally (1..22, X, Y), skip sex if absent.
  df$chr <- sub("^chr", "", df$chr)
  chr_order <- c(as.character(1:22), "X", "Y")
  df$chr <- factor(df$chr, levels = intersect(chr_order, unique(df$chr)))

  # Label QC-fail samples with a red prefix so they're obvious in the y-axis.
  df$sample_label <- ifelse(df$sample %in% qc_fail_ids,
                            paste0("⚠ ", df$sample), df$sample)

  p <- ggplot2::ggplot(df,
                       ggplot2::aes(xmin = from, xmax = to,
                                    ymin = as.numeric(factor(sample_label)) - 0.4,
                                    ymax = as.numeric(factor(sample_label)) + 0.4,
                                    fill = mean,
                                    text = paste0(sample, " | ", chr,
                                                  ":", from, "-", to,
                                                  " | seg.mean=", round(mean, 3)))) +
    ggplot2::geom_rect() +
    ggplot2::facet_grid(. ~ chr, scales = "free_x", space = "free_x",
                        switch = "x") +
    ggplot2::scale_fill_gradient2(low = "#1f77b4", mid = "#f7f7f7",
                                  high = "#d62728", midpoint = 0,
                                  limits = c(-1.5, 1.5),
                                  name = "seg.mean") +
    ggplot2::scale_y_continuous(
      breaks = seq_along(unique(df$sample_label)),
      labels = unique(df$sample_label),
      expand = ggplot2::expansion(mult = 0)
    ) +
    ggplot2::labs(x = "Chromosome", y = NULL) +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.text.x = ggplot2::element_blank(),
      axis.ticks.x = ggplot2::element_blank(),
      panel.grid = ggplot2::element_blank(),
      panel.spacing.x = ggplot2::unit(0.1, "lines"),
      strip.placement = "outside",
      strip.text = ggplot2::element_text(size = 8),
      legend.position = "bottom"
    )

  plotly::ggplotly(p, tooltip = "text")
}

`%||%` <- function(a, b) if (is.null(a)) b else a
