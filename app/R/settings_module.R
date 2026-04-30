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

# Build the "<name> [?] (default X)" label for a numeric input. The info
# icon is wrapped in a bslib tooltip so hovering reveals the explanation.
.settings_label <- function(name, default, help_text) {
  shiny::tagList(
    name, " ",
    bslib::tooltip(
      shiny::icon("circle-info", class = "text-muted",
                  style = "cursor: help;"),
      help_text,
      placement = "right"
    ),
    " ",
    shiny::tags$small(class = "text-muted",
                      sprintf("(default %s)", default))
  )
}

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
          .settings_label(
            "Detection-p threshold", d$qc_detection_p,
            paste(
              "Per-probe cutoff on the detection p-value.",
              "Within a sample, a probe is counted as failed when its",
              "p-value exceeds this. Lower values = stricter calls."
            )
          ),
          value = d$qc_detection_p, min = 0, max = 1, step = 0.01
        ),
        shiny::numericInput(
          ns("qc_failed_pct"),
          .settings_label(
            "Failed-probe % per sample", d$qc_failed_pct,
            paste(
              "Maximum share of failed probes a sample is allowed to have",
              "before being flagged. Computed within each sample (failed",
              "probes ÷ total probes × 100), not across the cohort.",
              "A sample at or above this percent fails QC."
            )
          ),
          value = d$qc_failed_pct, min = 0, max = 100, step = 1
        )
      ),
      shiny::div(
        class = "col-md-6",
        shiny::h6(class = "text-muted text-uppercase small fw-semibold",
                  "Dimensionality reduction"),
        shiny::numericInput(
          ns("dim_variable_probes"),
          .settings_label(
            "# variable probes", d$dim_variable_probes,
            paste(
              "How many of the most variable CpG probes (by standard",
              "deviation across samples) to feed into t-SNE / UMAP /",
              "clustering. More probes = more signal but slower; 10,000",
              "is a common starting point."
            )
          ),
          value = d$dim_variable_probes, min = 100, max = 1e6, step = 1000
        ),
        shiny::numericInput(
          ns("dim_tsne_perplexity"),
          .settings_label(
            "t-SNE perplexity", d$dim_tsne_perplexity,
            paste(
              "t-SNE's neighborhood size — roughly the effective number",
              "of neighbors each point considers. Use small values (2–5)",
              "for tiny cohorts (<15 samples); 30 is typical for hundreds.",
              "Must be less than the number of samples."
            )
          ),
          value = d$dim_tsne_perplexity, min = 1, max = 100, step = 1
        ),
        shiny::numericInput(
          ns("dim_umap_neighbors"),
          .settings_label(
            "UMAP neighbors", d$dim_umap_neighbors,
            paste(
              "UMAP's local-vs-global trade-off. Smaller values preserve",
              "fine local structure (clusters); larger values preserve",
              "global topology at the cost of detail. 15 is the package",
              "default."
            )
          ),
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
