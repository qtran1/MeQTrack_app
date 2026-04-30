# app/R/settings_module.R
# ---------------------------------------------------------------------------
# Wave 6 Theme 6d Phase 1 — user-tunable pipeline parameters.
#
# Five numeric knobs across QC and dimensionality reduction. The reactive
# returned by settings_module_server() is consumed by run_controller, which
# passes the values into bridge_launch on each run. Per the v1.1 decision,
# these apply to the next launch only — there is no workspace-default
# persistence layer (past runs remember their own settings via the
# run_manifest.json parameters block, which the past-runs attach feeds back
# into these inputs).
#
# Public exports:
#   settings_module_ui(id)
#   settings_module_server(id, attach_run) -> reactive list of parameters
# ---------------------------------------------------------------------------

# Authoritative defaults — must match pipeline_modules/config.R$default_config.
SETTINGS_DEFAULTS <- list(
  qc_detection_p          = 0.01,
  qc_failed_pct           = 25,
  dim_variable_probes     = 10000L,
  dim_tsne_perplexity     = 5L,
  dim_umap_neighbors      = 15L
)

settings_module_ui <- function(id) {
  ns <- shiny::NS(id)
  d  <- SETTINGS_DEFAULTS
  shiny::tagList(
    shiny::div(
      class = "row g-3",
      shiny::div(
        class = "col-md-6",
        shiny::h6(class = "text-muted text-uppercase small fw-semibold",
                  "Quality control"),
        shiny::numericInput(
          ns("qc_detection_p"),
          shiny::tagList("Detection-p threshold ",
                         shiny::tags$small(class = "text-muted",
                                           sprintf("(default %s)", d$qc_detection_p))),
          value = d$qc_detection_p, min = 0, max = 1, step = 0.01
        ),
        shiny::numericInput(
          ns("qc_failed_pct"),
          shiny::tagList("Failed-probe % threshold ",
                         shiny::tags$small(class = "text-muted",
                                           sprintf("(default %s)", d$qc_failed_pct))),
          value = d$qc_failed_pct, min = 0, max = 100, step = 1
        )
      ),
      shiny::div(
        class = "col-md-6",
        shiny::h6(class = "text-muted text-uppercase small fw-semibold",
                  "Dimensionality reduction"),
        shiny::numericInput(
          ns("dim_variable_probes"),
          shiny::tagList("# variable probes ",
                         shiny::tags$small(class = "text-muted",
                                           sprintf("(default %s)", d$dim_variable_probes))),
          value = d$dim_variable_probes, min = 100, max = 1e6, step = 1000
        ),
        shiny::numericInput(
          ns("dim_tsne_perplexity"),
          shiny::tagList("t-SNE perplexity ",
                         shiny::tags$small(class = "text-muted",
                                           sprintf("(default %s)", d$dim_tsne_perplexity))),
          value = d$dim_tsne_perplexity, min = 1, max = 100, step = 1
        ),
        shiny::numericInput(
          ns("dim_umap_neighbors"),
          shiny::tagList("UMAP neighbors ",
                         shiny::tags$small(class = "text-muted",
                                           sprintf("(default %s)", d$dim_umap_neighbors))),
          value = d$dim_umap_neighbors, min = 2, max = 200, step = 1
        )
      )
    ),
    shiny::div(
      class = "mt-2",
      shiny::actionButton(
        ns("reset"), "Reset to defaults",
        icon = shiny::icon("arrow-rotate-left"),
        class = "btn-sm btn-outline-secondary"
      )
    )
  )
}

settings_module_server <- function(id, attach_run = shiny::reactive(NULL)) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    shiny::observeEvent(input$reset, {
      for (k in names(SETTINGS_DEFAULTS)) {
        shiny::updateNumericInput(session, k, value = SETTINGS_DEFAULTS[[k]])
      }
    })

    # When a past run is attached, populate inputs from its manifest if it
    # carries a parameters block. Missing keys leave the current value alone.
    shiny::observeEvent(attach_run(), {
      path <- attach_run()
      if (is.null(path)) return()
      params <- read_run_parameters(path)
      if (is.null(params)) return()
      apply_params_to_inputs(session, params)
    }, ignoreInit = TRUE)

    # Reactive bag consumed by run_controller. Each input falls back to its
    # default if the user blanks the field.
    shiny::reactive({
      list(
        qc.detection_p_threshold          = numeric_or_default(
          input$qc_detection_p, SETTINGS_DEFAULTS$qc_detection_p),
        qc.failed_probe_percent_threshold = numeric_or_default(
          input$qc_failed_pct, SETTINGS_DEFAULTS$qc_failed_pct),
        dim.variable_probes               = integer_or_default(
          input$dim_variable_probes, SETTINGS_DEFAULTS$dim_variable_probes),
        dim.tsne_perplexity               = integer_or_default(
          input$dim_tsne_perplexity, SETTINGS_DEFAULTS$dim_tsne_perplexity),
        dim.umap_n_neighbors              = integer_or_default(
          input$dim_umap_neighbors, SETTINGS_DEFAULTS$dim_umap_neighbors)
      )
    })
  })
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

numeric_or_default <- function(x, default) {
  if (is.null(x) || length(x) == 0L || is.na(x)) return(default)
  as.numeric(x)
}

integer_or_default <- function(x, default) {
  if (is.null(x) || length(x) == 0L || is.na(x)) return(default)
  as.integer(x)
}

# Read the parameters block from a run's manifest. Returns NULL if missing.
read_run_parameters <- function(run_dir) {
  if (is.null(run_dir) || !dir.exists(run_dir)) return(NULL)
  m_path <- file.path(run_dir, "run_manifest.json")
  if (!file.exists(m_path)) return(NULL)
  m <- tryCatch(jsonlite::read_json(m_path, simplifyVector = TRUE),
                error = function(e) NULL)
  if (is.null(m)) return(NULL)
  m$parameters
}

# Update the input widgets from a saved parameters block.
apply_params_to_inputs <- function(session, params) {
  pairs <- list(
    qc_detection_p      = params$qc.detection_p_threshold,
    qc_failed_pct       = params$qc.failed_probe_percent_threshold,
    dim_variable_probes = params$dim.variable_probes,
    dim_tsne_perplexity = params$dim.tsne_perplexity,
    dim_umap_neighbors  = params$dim.umap_n_neighbors
  )
  for (input_id in names(pairs)) {
    v <- pairs[[input_id]]
    if (!is.null(v) && length(v) == 1L && !is.na(v)) {
      shiny::updateNumericInput(session, input_id, value = v)
    }
  }
}
