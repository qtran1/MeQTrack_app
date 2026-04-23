# app/R/dimred_module.R
# ---------------------------------------------------------------------------
# Dim-reduction views: t-SNE, UMAP, hierarchical clustering.
#
# t-SNE and UMAP are rendered with plotly so the user can hover for sample
# names and pick a metadata column to color by. QC-fail samples always use
# a triangle marker regardless of color scheme so they stay identifiable.
#
# Dendrogram is a horizontal plotly rebuild (leaves on the left, branches
# grow right). Labels are plain horizontal text anchored to extend leftward
# from x=0, so long Sample_IDs stay readable. QC-fail leaf labels are red.
# ---------------------------------------------------------------------------

dimred_module_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::navset_tab(
    bslib::nav_panel(
      "t-SNE",
      shiny::uiOutput(ns("tsne_header")),
      shiny::fluidRow(
        shiny::column(3, shiny::uiOutput(ns("tsne_color_selector"))),
        shiny::column(9, plotly::plotlyOutput(ns("tsne_plot"), height = "600px"))
      )
    ),
    bslib::nav_panel(
      "UMAP",
      shiny::uiOutput(ns("umap_header")),
      shiny::fluidRow(
        shiny::column(3, shiny::uiOutput(ns("umap_color_selector"))),
        shiny::column(9, plotly::plotlyOutput(ns("umap_plot"), height = "600px"))
      )
    ),
    bslib::nav_panel(
      "Dendrogram",
      shiny::uiOutput(ns("dendro_header")),
      plotly::plotlyOutput(ns("dendro_plot"), height = "600px")
    )
  )
}

dimred_module_server <- function(id, results) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # --- t-SNE ---------------------------------------------------------
    output$tsne_header <- shiny::renderUI({
      r <- results()
      if (is.null(r) || is.null(r$tsne)) {
        return(shiny::div(class = "alert alert-secondary",
                          "No t-SNE results yet. Run the pipeline first."))
      }
      dup_info <- r$tsne$duplicates
      if (!is.null(dup_info) && length(dup_info) > 0L) {
        shiny::div(class = "alert alert-info",
                   shiny::tags$strong("Note: "),
                   sprintf("%d duplicate sample(s) removed before t-SNE: %s",
                           length(dup_info),
                           paste(dup_info, collapse = ", ")))
      } else NULL
    })

    output$tsne_color_selector <- shiny::renderUI({
      r <- results()
      if (is.null(r) || is.null(r$tsne)) return(NULL)
      render_color_selector(ns("tsne_color"), r$metadata_cols)
    })

    output$tsne_plot <- plotly::renderPlotly({
      r <- results()
      if (is.null(r) || is.null(r$tsne)) {
        return(plotly::plot_ly(type = "scatter", mode = "markers"))
      }
      scatter_dimred(r$tsne$coords, r$sample_info, r$qc_fail_ids,
                     color_by = input$tsne_color, kind = "t-SNE")
    })

    # --- UMAP ----------------------------------------------------------
    output$umap_header <- shiny::renderUI({
      r <- results()
      if (is.null(r) || is.null(r$umap)) {
        shiny::div(class = "alert alert-secondary",
                   "No UMAP results yet. Run the pipeline first.")
      } else NULL
    })

    output$umap_color_selector <- shiny::renderUI({
      r <- results()
      if (is.null(r) || is.null(r$umap)) return(NULL)
      render_color_selector(ns("umap_color"), r$metadata_cols)
    })

    output$umap_plot <- plotly::renderPlotly({
      r <- results()
      if (is.null(r) || is.null(r$umap)) {
        return(plotly::plot_ly(type = "scatter", mode = "markers"))
      }
      scatter_dimred(r$umap$coords, r$sample_info, r$qc_fail_ids,
                     color_by = input$umap_color, kind = "UMAP")
    })

    # --- Dendrogram ----------------------------------------------------
    output$dendro_header <- shiny::renderUI({
      r <- results()
      if (is.null(r) || is.null(r$hclust)) {
        shiny::div(class = "alert alert-secondary",
                   "No hierarchical clustering results yet.")
      } else {
        shiny::tags$small(class = "text-muted",
                          sprintf("Distance: %s | Method: %s",
                                  r$hclust$distance %||% "(unknown)",
                                  r$hclust$method   %||% "(unknown)"))
      }
    })

    output$dendro_plot <- plotly::renderPlotly({
      r <- results()
      if (is.null(r) || is.null(r$hclust) || is.null(r$hclust$hclust)) {
        return(plotly::plot_ly() |>
                 plotly::layout(title = "No hierarchical clustering results"))
      }
      dendro_plotly(r$hclust$hclust, r$qc_fail_ids)
    })
  })
}

# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------

render_color_selector <- function(input_id, metadata_cols) {
  choices <- c("(none)" = "__none__", metadata_cols)
  if (!length(metadata_cols)) {
    return(shiny::tagList(
      shiny::h6("Color by"),
      shiny::tags$em(class = "text-muted small",
                     "No metadata columns detected.")
    ))
  }
  shiny::tagList(
    shiny::h6("Color by"),
    shiny::selectInput(input_id, label = NULL, choices = choices)
  )
}

# Build a plotly scatter from a coords data frame + sample_info metadata.
# coords is expected to have columns for the first two dims and a sample
# identifier; we detect these flexibly.
scatter_dimred <- function(coords, sample_info, qc_fail_ids,
                           color_by = NULL, kind = "t-SNE") {
  df <- as.data.frame(coords)
  coord_cols <- detect_coord_cols(df)
  if (is.null(coord_cols)) {
    return(plotly::plot_ly() |>
             plotly::layout(title = paste(kind, "— unexpected coords shape")))
  }

  # Sample IDs live in rownames(coords) — the pipeline leaves any in-frame
  # Sample_ID / Sample_Name columns full of NA. Use rownames as the primary
  # source and fall back to a column only if rownames are the default
  # numeric indices.
  rn <- rownames(df)
  id_vals <- if (!is.null(rn) && !all(grepl("^\\d+$", rn))) {
    rn
  } else {
    id_col <- detect_id_col(df)
    if (!is.null(id_col)) as.character(df[[id_col]]) else as.character(seq_len(nrow(df)))
  }

  plot_df <- data.frame(
    .x  = df[[coord_cols[1]]],
    .y  = df[[coord_cols[2]]],
    .id = id_vals,
    stringsAsFactors = FALSE
  )

  # Join metadata so we can color by a samplesheet column.
  if (!is.null(sample_info) && nrow(sample_info) > 0L) {
    merge_key <- if ("Sample_ID" %in% colnames(sample_info)) "Sample_ID" else colnames(sample_info)[1]
    plot_df <- merge(plot_df, sample_info,
                     by.x = ".id", by.y = merge_key, all.x = TRUE, sort = FALSE)
  }

  plot_df$.qc_status <- ifelse(plot_df$.id %in% qc_fail_ids,
                               "QC fail", "QC pass")

  color_vec <- if (!is.null(color_by) && nzchar(color_by) &&
                   color_by != "__none__" && color_by %in% colnames(plot_df)) {
    plot_df[[color_by]]
  } else NULL

  # Marker styling: fixed teal fill (#018571) when no metadata coloring is
  # active; when the user picks a "Color by" column, the SCATTER_PALETTE
  # takes over the fill. Border is always brown (#a6611a) for the
  # teal/brown theme.
  marker_list <- list(
    size = 10,
    opacity = 0.9,
    line = list(width = 1, color = "#a6611a")
  )
  if (is.null(color_vec)) marker_list$color <- "#018571"

  fig <- plotly::plot_ly(
    data = plot_df,
    x = ~.x, y = ~.y,
    type = "scatter", mode = "markers",
    color = color_vec,
    colors = SCATTER_PALETTE,
    symbol = ~.qc_status,
    symbols = c("QC pass" = "circle", "QC fail" = "triangle-up"),
    marker = marker_list,
    text = ~sprintf("<b>%s</b>", .id),
    hovertemplate = paste0(
      "%{text}<br>",
      kind, " 1: %{x:.2f}<br>",
      kind, " 2: %{y:.2f}<extra></extra>"
    )
  ) |>
    plotly::layout(
      xaxis = list(title = paste(kind, "1")),
      yaxis = list(title = paste(kind, "2")),
      margin = list(l = 50, r = 20, t = 20, b = 50)
    ) |>
    plotly_defaults()
  fig
}

# Pick the first two numeric columns that look like coordinates.
detect_coord_cols <- function(df) {
  # Prefer named X/Y or Dim1/Dim2 style columns.
  pats <- c("^X$", "^Y$", "^Dim1$", "^Dim2$", "^V1$", "^V2$",
            "^tsne", "^umap")
  matched <- unlist(lapply(pats, function(p) grep(p, colnames(df), value = TRUE,
                                                   ignore.case = TRUE)))
  matched <- unique(matched)
  numeric_cols <- colnames(df)[vapply(df, is.numeric, logical(1))]
  if (length(matched) >= 2) return(head(matched, 2))
  if (length(numeric_cols) >= 2) return(head(numeric_cols, 2))
  NULL
}

# Pick the sample-ID column.
detect_id_col <- function(df) {
  cands <- c("Sample_ID", "sample_id", "SampleID", "id", "ID", "Sample_Name")
  for (c in cands) if (c %in% colnames(df)) return(c)
  # Fallback: first character column.
  chr_cols <- colnames(df)[vapply(df, function(x)
                                   is.character(x) || is.factor(x), logical(1))]
  if (length(chr_cols)) return(chr_cols[1])
  NULL
}

# Horizontal plotly dendrogram — leaves on the left (labels as plain
# horizontal text extending leftward from x=0), branches grow rightward
# along the x-axis (heights). QC-fail leaf labels are red.
dendro_plotly <- function(hc, qc_fail_ids) {
  if (!requireNamespace("ggdendro", quietly = TRUE)) {
    return(plotly::plot_ly() |>
             plotly::layout(title = "ggdendro package not available"))
  }
  dd  <- ggdendro::dendro_data(hc, type = "rectangle")
  seg <- ggdendro::segment(dd)
  lab <- ggdendro::label(dd)
  lab$label <- as.character(lab$label)
  if (any(is.na(lab$label) | !nzchar(lab$label))) {
    # Safety fallback — should not happen if hc$labels is populated.
    lab$label <- ifelse(is.na(lab$label) | !nzchar(lab$label),
                        paste0("sample_", seq_len(nrow(lab))),
                        lab$label)
  }
  lab$is_fail <- lab$label %in% qc_fail_ids

  max_h <- max(c(seg$y, seg$yend), na.rm = TRUE)
  if (!is.finite(max_h) || max_h <= 0) max_h <- 1

  # Allocate negative-x space for labels proportional to the longest label.
  # 0.06 units per character is a rough heuristic tuned for 12px font.
  longest_chars <- max(nchar(lab$label), 4L)
  label_pad <- max_h * 0.04 * longest_chars

  plotly::plot_ly() |>
    plotly::add_segments(
      x = seg$y, xend = seg$yend,
      y = seg$x, yend = seg$xend,
      line = list(color = COLORS$ink_500, width = 1.2),
      hoverinfo = "skip",
      showlegend = FALSE
    ) |>
    plotly::add_text(
      x = rep(0, nrow(lab)),
      y = lab$x,
      text = lab$label,
      textposition = "middle left",
      textfont = list(
        size  = 12,
        color = ifelse(lab$is_fail, COLORS$fail, COLORS$ink_900),
        family = "Inter, -apple-system, BlinkMacSystemFont, sans-serif"
      ),
      hovertext = ifelse(lab$is_fail,
                         paste0(lab$label, " (QC fail)"),
                         lab$label),
      hoverinfo = "text",
      showlegend = FALSE
    ) |>
    plotly::layout(
      xaxis = list(
        title = "Height",
        range = c(-label_pad, max_h * 1.05),
        zeroline = FALSE
      ),
      yaxis = list(
        title = NULL,
        showticklabels = FALSE,
        zeroline = FALSE,
        showgrid = FALSE,
        range = c(0.5, max(lab$x) + 0.5)
      ),
      margin = list(l = 10, r = 30, t = 20, b = 50)
    ) |>
    plotly_defaults()
}

`%||%` <- function(a, b) if (is.null(a)) b else a
