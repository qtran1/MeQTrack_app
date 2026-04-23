# app/app.R — Shiny entrypoint for MeQTrack.
#
# Wave 2 shell:
#   - bslib Bootstrap 5 theme
#   - three-pane layout: sidebar (inputs) | main (tabbed content) |
#     footer (status strip)
#   - Samplesheet tab wired to the real samplesheet_module
#   - QC / Dim-Reduction / CNV / Report tabs are placeholders until their
#     respective waves
#
# Launch:
#   From the project root:
#     R -e 'shiny::runApp("app", launch.browser = TRUE, host = "127.0.0.1")'
#   Or double-click meqtrack.command (macOS) / meqtrack.bat (Windows).

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(shinyFiles)
  library(DT)
})

# ---------------------------------------------------------------------------
# Module sources
# ---------------------------------------------------------------------------
# shiny::runApp("app") sets the working directory to the app/ folder
# before sourcing this file, so module paths are relative to app/.
# project_root() in workspace.R walks up one level for pipeline paths.
source(file.path("R", "workspace.R"),          local = FALSE)
source(file.path("R", "validators.R"),         local = FALSE)
source(file.path("R", "array_detect.R"),       local = FALSE)
source(file.path("R", "samplesheet_module.R"), local = FALSE)
source(file.path("R", "pipeline_bridge.R"),    local = FALSE)
source(file.path("R", "run_controller.R"),     local = FALSE)

# ---------------------------------------------------------------------------
# First-launch workspace creation
# ---------------------------------------------------------------------------
WORKSPACE_PATH <- ensure_workspace()

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
# Build module UI pieces once so we can drop slots into multiple layout
# positions (sidebar vs main vs metadata card).
ss_ui  <- samplesheet_ui("samplesheet")
run_ui <- run_controller_ui("run")

ui <- bslib::page_navbar(
  title = tags$span(
    tags$strong("MeQTrack"),
    tags$span(" — methylation analysis", class = "text-muted small ms-2")
  ),
  theme = bslib::bs_theme(
    version = 5,
    primary = "#2c7fb8"   # muted blue accent; neutral for data work
  ),
  window_title = "MeQTrack",
  fillable = TRUE,
  # -----------------------------------------------------------------
  # Samplesheet tab (Wave 2)
  # -----------------------------------------------------------------
  bslib::nav_panel(
    title = "Samplesheet",
    icon = icon("table"),
    bslib::layout_sidebar(
      sidebar = bslib::sidebar(
        width = 320,
        ss_ui$sidebar,
        hr(),
        div(
          class = "text-muted small",
          tags$strong("Workspace:"), br(),
          tags$code(WORKSPACE_PATH)
        )
      ),
      bslib::card(
        bslib::card_header("Samples"),
        bslib::card_body(ss_ui$main, fillable = FALSE)
      ),
      bslib::card(
        bslib::card_header("Metadata"),
        bslib::card_body(ss_ui$metadata, fillable = FALSE)
      )
    )
  ),
  # -----------------------------------------------------------------
  # Run tab (Wave 3)
  # -----------------------------------------------------------------
  bslib::nav_panel(
    title = "Run",
    icon = icon("play"),
    bslib::card(
      bslib::card_header("Pipeline run"),
      bslib::card_body(run_ui$main, fillable = FALSE)
    )
  ),
  # -----------------------------------------------------------------
  # Placeholder tabs for later waves
  # -----------------------------------------------------------------
  bslib::nav_panel(
    title = "QC", icon = icon("chart-column"),
    bslib::card(
      bslib::card_header("QC view"),
      bslib::card_body(
        tags$p(tags$em(
          "QC metrics and plots will appear here after Wave 3 introduces ",
          "the run controller and Wave 4 wires in the result views."
        ))
      )
    )
  ),
  bslib::nav_panel(
    title = "Dim. reduction", icon = icon("diagram-project"),
    bslib::card(
      bslib::card_header("t-SNE / UMAP / Clustering"),
      bslib::card_body(
        tags$p(tags$em("Populated in Wave 4."))
      )
    )
  ),
  bslib::nav_panel(
    title = "CNV", icon = icon("dna"),
    bslib::card(
      bslib::card_header("CNV review"),
      bslib::card_body(
        tags$p(tags$em("Populated in Wave 4."))
      )
    )
  ),
  bslib::nav_panel(
    title = "Report", icon = icon("file-lines"),
    bslib::card(
      bslib::card_header("Report"),
      bslib::card_body(
        tags$p(tags$em(
          "The run's HTML report is opened from the Run tab's ",
          "\"Open report in browser\" action. An in-app preview arrives in Wave 4."
        ))
      )
    )
  ),
  # -----------------------------------------------------------------
  # Footer / status strip
  # -----------------------------------------------------------------
  bslib::nav_spacer(),
  bslib::nav_item(
    uiOutput("header_status", inline = TRUE)
  )
)

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------
server <- function(input, output, session) {
  ss_state <- samplesheet_server(
    "samplesheet",
    workspace     = function() WORKSPACE_PATH,
    project_root_ = project_root
  )

  run_state <- run_controller_server(
    "run",
    ss_state      = ss_state,
    workspace     = function() WORKSPACE_PATH,
    project_root_ = project_root
  )

  # Header status (top-right): once a run has started, surface its state;
  # otherwise fall back to samplesheet readiness.
  output$header_status <- renderUI({
    rs <- run_state()
    if (!identical(rs$state, RUN_STATE_IDLE)) {
      return(render_state_badge(rs$state, rs$stage,
                                started_at = NULL, ended_at = NULL))
    }
    st <- ss_state()
    if (isTRUE(st$valid)) {
      tags$span(class = "badge bg-success me-2",
                icon("circle-check"), " Samplesheet OK")
    } else if (!is.null(st$samplesheet_path)) {
      tags$span(class = "badge bg-warning text-dark me-2",
                icon("triangle-exclamation"), " Samplesheet has issues")
    } else {
      tags$span(class = "badge bg-secondary me-2",
                "No samplesheet loaded")
    }
  })

  # Log the samplesheet state to the launcher terminal whenever it changes;
  # cheap observability before we have a proper status panel.
  observe({
    st <- ss_state()
    if (is.null(st$samplesheet_path)) return()
    message(sprintf(
      "[samplesheet] %s | array_type=%s | valid=%s | n_ok=%s | n_bad=%s",
      st$samplesheet_path,
      st$array_type,
      isTRUE(st$valid),
      if (is.null(st$validated_df)) NA else sum(st$validated_df$Status == STATUS_OK),
      if (is.null(st$validated_df)) NA else sum(st$validated_df$Status != STATUS_OK)
    ))
  })
}

shinyApp(ui, server)
