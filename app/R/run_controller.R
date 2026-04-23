# app/R/run_controller.R
# ---------------------------------------------------------------------------
# Shiny module that owns pipeline execution: Run/Cancel controls, stage
# progress tracking, live log tail, and post-run actions (open report,
# reveal in file manager).
#
# Wave 3 module. Consumes the samplesheet module's reactive state and talks
# to the pipeline through pipeline_bridge.R (already written).
#
# Design note (deviation from mvp-plan §2.1):
#   mvp-plan suggests ExtendedTask + promises + future. We use callr::r_bg
#   directly (a real OS subprocess) and poll its state via invalidateLater.
#   ExtendedTask is designed to move a synchronous R computation to a future
#   worker so it doesn't block the session; since callr::r_bg is already a
#   separate OS process the session is never blocked, and ExtendedTask adds
#   scaffolding without a payoff. If we ever need the promise-resolution
#   model (chaining then()/catch() on the run outcome), we can wrap the
#   handle in an ExtendedTask without changing the UI.
#
# Public exports:
#   run_controller_ui(id)                list of UI fragments (main / header)
#   run_controller_server(id, ss_state, workspace, project_root_)
#     -> reactive list(state, stage, run_dir, exit_code)   (for header badge)
# ---------------------------------------------------------------------------

# Stage keys (machine) and labels (display). Order matters: index = step #.
RUN_STAGES <- c(
  preprocess    = "Preprocessing",
  qc            = "Quality control",
  filtering     = "Probe filtering",
  dim_reduction = "Dimensionality reduction",
  cnv           = "Copy-number variation",
  visualization = "Report generation"
)

# Regex that matches the pipeline's stage-start log line. The pipeline emits
# lines like: "[2026-04-22 14:03:11] Step 3: Probe filtering".
STAGE_LINE_RE <- "Step\\s+([1-6]):"

# Overall run states.
RUN_STATE_IDLE      <- "idle"
RUN_STATE_RUNNING   <- "running"
RUN_STATE_COMPLETED <- "completed"
RUN_STATE_FAILED    <- "failed"
RUN_STATE_CANCELLED <- "cancelled"

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
run_controller_ui <- function(id) {
  ns <- shiny::NS(id)
  list(
    # Main content for the Run tab.
    main = shiny::tagList(
      shiny::div(
        class = "d-flex gap-2 align-items-center mb-3",
        shiny::actionButton(
          ns("run"), label = "Run analysis",
          icon = shiny::icon("play"),
          class = "btn-primary"
        ),
        shiny::actionButton(
          ns("cancel"), label = "Cancel",
          icon = shiny::icon("stop"),
          class = "btn-outline-danger"
        ),
        shiny::uiOutput(ns("state_badge"), inline = TRUE)
      ),
      shiny::uiOutput(ns("prereq_msg")),
      bslib::card(
        bslib::card_header("Stages"),
        bslib::card_body(
          shiny::uiOutput(ns("stages_panel"))
        )
      ),
      bslib::card(
        bslib::card_header("Live log (last 20 lines)"),
        bslib::card_body(
          shiny::verbatimTextOutput(ns("log_tail"), placeholder = TRUE)
        )
      ),
      bslib::card(
        bslib::card_header("Actions"),
        bslib::card_body(
          shiny::uiOutput(ns("post_run_actions"))
        )
      )
    ),
    # Compact header slot — state badge in the navbar.
    header = shiny::uiOutput(ns("header_badge"), inline = TRUE)
  )
}

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------
run_controller_server <- function(id, ss_state, workspace, project_root_) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # Core reactive state. We keep one authoritative reactiveValues bag so
    # the UI renderers only depend on this, not on the bridge handle shape.
    rv <- shiny::reactiveValues(
      state       = RUN_STATE_IDLE,
      handle      = NULL,                  # pipeline_bridge handle, or NULL
      run_dir     = NULL,                  # absolute path
      log_file    = NULL,
      stage       = NA_character_,         # currently running stage key
      stage_times = NULL,                  # named list: <stage> -> start POSIXct
      stage_ends  = NULL,                  # named list: <stage> -> end POSIXct (NULL while running)
      stage_state = NULL,                  # named chr:  <stage> -> pending|running|done|failed
      started_at  = NULL,
      ended_at    = NULL,
      exit_code   = NA_integer_,
      error_msg   = NULL,
      report_path = NULL
    )

    reset_stages <- function() {
      rv$stage_state <- stats::setNames(
        rep("pending", length(RUN_STAGES)),
        names(RUN_STAGES)
      )
      rv$stage_times <- stats::setNames(
        vector("list", length(RUN_STAGES)),
        names(RUN_STAGES)
      )
      rv$stage_ends <- stats::setNames(
        vector("list", length(RUN_STAGES)),
        names(RUN_STAGES)
      )
      rv$stage <- NA_character_
    }

    reset_stages()

    # --- Run button ------------------------------------------------------
    shiny::observeEvent(input$run, {
      st <- ss_state()
      if (!isTRUE(st$valid)) {
        shiny::showNotification(
          "Samplesheet is not ready. Fix validation issues first.",
          type = "warning"
        )
        return()
      }
      if (identical(rv$state, RUN_STATE_RUNNING)) {
        shiny::showNotification("A run is already in progress.", type = "message")
        return()
      }

      ws <- if (is.function(workspace)) workspace() else workspace
      pr <- if (is.function(project_root_)) project_root_() else project_root_

      stem <- tools::file_path_sans_ext(basename(st$samplesheet_path))
      run_id <- sprintf("%s_%s", format(Sys.time(), "%Y%m%d-%H%M%S"), stem)
      run_dir <- file.path(ws, "runs", run_id)

      reset_stages()
      rv$run_dir     <- run_dir
      rv$started_at  <- Sys.time()
      rv$ended_at    <- NULL
      rv$exit_code   <- NA_integer_
      rv$error_msg   <- NULL
      rv$report_path <- NULL

      handle <- tryCatch(
        bridge_launch(
          samplesheet     = st$samplesheet_path,
          output_dir      = run_dir,
          data_dir        = file.path(pr, "pipeline", "data"),
          array_type      = st$array_type %||% "auto",
          threads         = 4L,
          step            = "all",
          pipeline_script = file.path(pr, "pipeline", "methylation_pipeline.R")
        ),
        error = function(e) {
          shiny::showNotification(
            sprintf("Failed to launch pipeline: %s", conditionMessage(e)),
            type = "error", duration = NULL
          )
          NULL
        }
      )
      if (is.null(handle)) return()

      rv$handle   <- handle
      rv$log_file <- handle$log_file
      rv$state    <- RUN_STATE_RUNNING

      message(sprintf("[run_controller] launched run_id=%s dir=%s",
                      handle$run_id, run_dir))
    }, ignoreInit = TRUE)

    # --- Cancel button ---------------------------------------------------
    shiny::observeEvent(input$cancel, {
      if (!identical(rv$state, RUN_STATE_RUNNING)) return()
      if (is.null(rv$handle)) return()

      bridge_kill(rv$handle)
      rv$state     <- RUN_STATE_CANCELLED
      rv$ended_at  <- Sys.time()

      # Mark the in-progress stage as failed (it was interrupted) and
      # freeze its elapsed time.
      if (!is.na(rv$stage) && !is.null(rv$stage_state)) {
        rv$stage_state[[rv$stage]] <- "failed"
        rv$stage_ends[[rv$stage]]  <- rv$ended_at
      }

      quarantine_partial_outputs(rv$run_dir)
      message(sprintf("[run_controller] cancelled run dir=%s", rv$run_dir))
    }, ignoreInit = TRUE)

    # --- Poll loop: refreshes every second while a run is active ---------
    shiny::observe({
      if (!identical(rv$state, RUN_STATE_RUNNING)) return()
      if (is.null(rv$handle)) return()

      # Re-trigger this observer every second so long as we're running.
      shiny::invalidateLater(1000, session)

      # 1. Parse log tail for stage transitions.
      lines <- bridge_log_tail(rv$handle, n = 500L)
      update_stage_progress(rv, lines)

      # 2. Detect process exit and finalize state.
      if (!bridge_is_running(rv$handle)) {
        code <- bridge_exit_code(rv$handle)
        rv$exit_code <- if (is.na(code)) NA_integer_ else as.integer(code)
        rv$ended_at  <- Sys.time()

        if (isTRUE(rv$exit_code == 0L)) {
          rv$state <- RUN_STATE_COMPLETED
          # Close out the last running stage first, then mark all done.
          if (!is.na(rv$stage) && !is.null(rv$stage_state)) {
            rv$stage_state[[rv$stage]] <- "done"
            rv$stage_ends[[rv$stage]]  <- rv$ended_at
          }
          rv$stage_state[] <- "done"
          rv$stage <- NA_character_
          rv$report_path <- discover_report(rv$run_dir)
        } else {
          rv$state <- RUN_STATE_FAILED
          if (!is.na(rv$stage) && !is.null(rv$stage_state)) {
            rv$stage_state[[rv$stage]] <- "failed"
            rv$stage_ends[[rv$stage]]  <- rv$ended_at
          }
          rv$error_msg <- extract_last_error(lines)
        }
      }
    })

    # --- UI outputs ------------------------------------------------------
    output$prereq_msg <- shiny::renderUI({
      st <- ss_state()
      if (isTRUE(st$valid)) return(NULL)
      shiny::div(
        class = "alert alert-secondary", role = "alert",
        shiny::tags$strong("Waiting on samplesheet. "),
        "Load a valid samplesheet on the Samplesheet tab to enable Run."
      )
    })

    output$state_badge <- shiny::renderUI({
      render_state_badge(rv$state, rv$stage, rv$started_at, rv$ended_at)
    })

    output$header_badge <- shiny::renderUI({
      # Header version is identical for now; app.R decides whether to show
      # this (run state) or the samplesheet state.
      render_state_badge(rv$state, rv$stage, rv$started_at, rv$ended_at)
    })

    output$stages_panel <- shiny::renderUI({
      # Re-render every second while running so the elapsed-time of the
      # currently-running stage ticks. Finished stages have a frozen end
      # time, so their elapsed value is stable across re-renders.
      if (identical(rv$state, RUN_STATE_RUNNING)) {
        shiny::invalidateLater(1000, session)
      }
      render_stages(rv$stage_state, rv$stage_times, rv$stage_ends,
                    current = rv$stage, run_state = rv$state)
    })

    output$log_tail <- shiny::renderText({
      if (identical(rv$state, RUN_STATE_RUNNING)) {
        shiny::invalidateLater(1000, session)
      }
      if (is.null(rv$handle)) return("(no run started yet)")
      lines <- bridge_log_tail(rv$handle, n = 20L)
      if (!length(lines)) return("(waiting for first log line…)")
      paste(lines, collapse = "\n")
    })

    output$post_run_actions <- shiny::renderUI({
      render_post_run_actions(ns, rv$state, rv$report_path, rv$log_file,
                              rv$error_msg, rv$run_dir)
    })

    # --- Action handlers -------------------------------------------------
    shiny::observeEvent(input$open_report, {
      if (is.null(rv$report_path) || !file.exists(rv$report_path)) {
        shiny::showNotification("Report file not found.", type = "warning")
        return()
      }
      utils::browseURL(normalizePath(rv$report_path, winslash = "/"))
    }, ignoreInit = TRUE)

    shiny::observeEvent(input$reveal_report, {
      if (is.null(rv$report_path) || !file.exists(rv$report_path)) {
        shiny::showNotification("Report file not found.", type = "warning")
        return()
      }
      reveal_in_file_manager(rv$report_path)
    }, ignoreInit = TRUE)

    shiny::observeEvent(input$open_log, {
      if (is.null(rv$log_file) || !file.exists(rv$log_file)) {
        shiny::showNotification("Log file not found.", type = "warning")
        return()
      }
      utils::browseURL(normalizePath(rv$log_file, winslash = "/"))
    }, ignoreInit = TRUE)

    shiny::observeEvent(input$reveal_run_dir, {
      if (is.null(rv$run_dir) || !dir.exists(rv$run_dir)) {
        shiny::showNotification("Run directory not found.", type = "warning")
        return()
      }
      reveal_in_file_manager(rv$run_dir)
    }, ignoreInit = TRUE)

    # --- Public reactive (for header badge in app.R) --------------------
    shiny::reactive({
      list(
        state     = rv$state,
        stage     = rv$stage,
        run_dir   = rv$run_dir,
        exit_code = rv$exit_code
      )
    })
  })
}

# ---------------------------------------------------------------------------
# Helpers (pure, module-internal)
# ---------------------------------------------------------------------------

# Parse the log tail and advance rv$stage / rv$stage_state / rv$stage_times.
# We only look for "Step N:" markers emitted by methylation_pipeline.R.
update_stage_progress <- function(rv, lines) {
  if (!length(lines)) return(invisible())
  matches <- regmatches(lines, regexec(STAGE_LINE_RE, lines))
  step_nums <- vapply(matches, function(m) {
    if (length(m) < 2L) NA_integer_ else as.integer(m[2])
  }, integer(1))
  step_nums <- step_nums[!is.na(step_nums)]
  if (!length(step_nums)) return(invisible())

  latest <- max(step_nums)
  if (latest < 1L || latest > length(RUN_STAGES)) return(invisible())

  new_stage_key <- names(RUN_STAGES)[latest]
  if (identical(rv$stage, new_stage_key)) return(invisible())

  now <- Sys.time()
  # Close out the previous stage (if any) as done and freeze its elapsed time.
  if (!is.na(rv$stage)) {
    rv$stage_state[[rv$stage]] <- "done"
    rv$stage_ends[[rv$stage]]  <- now
  }
  # Mark all earlier stages done (in case we missed their start line because
  # the log was truncated). No timing info available for retroactive ones.
  if (latest > 1L) {
    for (i in seq_len(latest - 1L)) {
      k <- names(RUN_STAGES)[i]
      if (identical(rv$stage_state[[k]], "pending")) {
        rv$stage_state[[k]] <- "done"
      }
    }
  }
  rv$stage <- new_stage_key
  rv$stage_state[[new_stage_key]] <- "running"
  rv$stage_times[[new_stage_key]] <- now
  rv$stage_ends[[new_stage_key]]  <- NULL
}

# Render the 6-row stage list.
render_stages <- function(stage_state, stage_times, stage_ends, current, run_state) {
  if (is.null(stage_state)) {
    return(shiny::tags$em("No run yet."))
  }
  now <- Sys.time()
  rows <- lapply(names(RUN_STAGES), function(key) {
    state <- stage_state[[key]] %||% "pending"
    start <- stage_times[[key]]
    end   <- stage_ends[[key]]
    endpoint <- if (!is.null(end)) end else now
    elapsed <- if (is.null(start)) NA else as.numeric(difftime(endpoint, start, units = "secs"))

    badge <- switch(
      state,
      pending = shiny::tags$span(class = "badge bg-secondary", "pending"),
      running = shiny::tags$span(class = "badge bg-primary", "running"),
      done    = shiny::tags$span(class = "badge bg-success", "done"),
      failed  = shiny::tags$span(class = "badge bg-danger", "failed"),
      shiny::tags$span(class = "badge bg-secondary", state)
    )
    elapsed_txt <- if (is.na(elapsed)) "—" else format_elapsed(elapsed)

    shiny::div(
      class = "d-flex align-items-center gap-3 py-1 border-bottom",
      shiny::div(style = "width: 120px;", badge),
      shiny::div(style = "flex: 1;", RUN_STAGES[[key]]),
      shiny::div(class = "text-muted small", style = "width: 100px; text-align: right;",
                 elapsed_txt)
    )
  })
  shiny::tagList(rows)
}

render_state_badge <- function(state, stage, started_at, ended_at) {
  switch(
    state,
    idle = shiny::tags$span(class = "badge bg-secondary", "Idle"),
    running = {
      label <- if (!is.na(stage)) {
        sprintf("Running: %s", RUN_STAGES[[stage]])
      } else {
        "Running"
      }
      shiny::tags$span(class = "badge bg-primary",
                       shiny::icon("spinner"), " ", label)
    },
    completed = shiny::tags$span(class = "badge bg-success",
                                 shiny::icon("circle-check"), " Completed"),
    failed = shiny::tags$span(class = "badge bg-danger",
                              shiny::icon("triangle-exclamation"), " Failed"),
    cancelled = shiny::tags$span(class = "badge bg-warning text-dark",
                                 shiny::icon("ban"), " Cancelled"),
    shiny::tags$span(class = "badge bg-secondary", state)
  )
}

render_post_run_actions <- function(ns, state, report_path, log_file,
                                    error_msg, run_dir) {
  if (identical(state, RUN_STATE_IDLE)) {
    return(shiny::tags$em("Actions appear here after a run finishes."))
  }
  if (identical(state, RUN_STATE_RUNNING)) {
    return(shiny::tags$em("Available once the run finishes."))
  }

  # Completed: report actions + reveal run dir.
  if (identical(state, RUN_STATE_COMPLETED)) {
    has_report <- !is.null(report_path) && file.exists(report_path)
    return(shiny::tagList(
      if (has_report) shiny::tagList(
        shiny::actionButton(ns("open_report"),
                            "Open report in browser",
                            icon = shiny::icon("arrow-up-right-from-square"),
                            class = "btn-success me-2"),
        shiny::actionButton(ns("reveal_report"),
                            reveal_label(),
                            icon = shiny::icon("folder-open"),
                            class = "btn-outline-secondary me-2")
      ) else shiny::div(
        class = "alert alert-warning",
        "Run completed but no HTML report was found under ",
        shiny::tags$code(file.path(basename(run_dir), "report")), "."
      ),
      shiny::actionButton(ns("reveal_run_dir"),
                          "Show run folder",
                          icon = shiny::icon("folder"),
                          class = "btn-outline-secondary me-2"),
      shiny::actionButton(ns("open_log"),
                          "Open log",
                          icon = shiny::icon("file-lines"),
                          class = "btn-outline-secondary")
    ))
  }

  # Failed or cancelled: error message + log + run dir.
  shiny::tagList(
    if (!is.null(error_msg) && nzchar(error_msg)) {
      shiny::div(
        class = "alert alert-danger",
        shiny::tags$strong("Error: "), error_msg
      )
    },
    shiny::actionButton(ns("open_log"),
                        "Open log",
                        icon = shiny::icon("file-lines"),
                        class = "btn-danger me-2"),
    shiny::actionButton(ns("reveal_run_dir"),
                        "Show run folder",
                        icon = shiny::icon("folder"),
                        class = "btn-outline-secondary")
  )
}

reveal_label <- function() {
  # Finder on macOS, Explorer on Windows, file manager on Linux.
  sys <- Sys.info()[["sysname"]]
  if (sys == "Darwin") "Show in Finder"
  else if (sys == "Windows") "Show in Explorer"
  else "Show in file manager"
}

# Cross-platform "reveal" — select the file in the OS file manager when we
# can, otherwise open the containing directory.
reveal_in_file_manager <- function(path) {
  path <- normalizePath(path, winslash = "/", mustWork = FALSE)
  sys  <- Sys.info()[["sysname"]]
  if (sys == "Darwin") {
    system2("open", args = c("-R", shQuote(path)))
  } else if (sys == "Windows") {
    # explorer /select,<path> highlights the file.
    shell(sprintf('explorer /select,"%s"', gsub("/", "\\\\", path, fixed = TRUE)),
          wait = FALSE)
  } else {
    # xdg-open works on the directory, not individual-file selection.
    dir <- if (dir.exists(path)) path else dirname(path)
    system2("xdg-open", args = shQuote(dir))
  }
  invisible()
}

# Find the generated report HTML. The pipeline writes to <run_dir>/reports/
# (plural) as methylation_analysis_report.html; the mvp-plan spec calls out
# <run_dir>/report/meqtrack_*.html. Check both layouts so either works.
discover_report <- function(run_dir) {
  if (is.null(run_dir)) return(NULL)
  candidates <- c(
    file.path(run_dir, "reports"),
    file.path(run_dir, "report")
  )
  candidates <- candidates[dir.exists(candidates)]
  if (!length(candidates)) return(NULL)
  files <- unlist(lapply(candidates, function(d) {
    list.files(d, pattern = "\\.html$", full.names = TRUE)
  }))
  if (!length(files)) return(NULL)
  # Prefer canonical pipeline filenames; fall back to any .html.
  preferred <- grep("methylation_analysis_report|^meqtrack_", basename(files))
  if (length(preferred)) files <- files[preferred]
  files[order(file.info(files)$mtime, decreasing = TRUE)][1]
}

# Pull the most useful error line from the log tail. Heuristic: last line
# starting with "Error" or containing "Error in".
extract_last_error <- function(lines) {
  if (!length(lines)) return(NULL)
  hits <- grep("^Error\\b|Error in ", lines, value = TRUE)
  if (!length(hits)) return(utils::tail(lines, 1L))
  utils::tail(hits, 1L)
}

# Move partial stage subdirs into <run_dir>/_cancelled/ so a cancelled run
# cannot be mistaken for a successful one. Keeps logs/ and the manifest at
# the top level so the user can still inspect what happened.
quarantine_partial_outputs <- function(run_dir) {
  if (is.null(run_dir) || !dir.exists(run_dir)) return(invisible())
  quarantine <- file.path(run_dir, "_cancelled")
  dir.create(quarantine, recursive = TRUE, showWarnings = FALSE)
  keep <- c("logs", "_cancelled", "run_manifest.json")
  entries <- list.files(run_dir, full.names = FALSE, include.dirs = TRUE,
                        no.. = TRUE)
  for (e in setdiff(entries, keep)) {
    src <- file.path(run_dir, e)
    dst <- file.path(quarantine, e)
    tryCatch(
      file.rename(src, dst),
      warning = function(w) {
        # file.rename can fail across filesystems; fall back to copy+delete.
        file.copy(src, quarantine, recursive = TRUE)
        unlink(src, recursive = TRUE, force = TRUE)
      }
    )
  }
  invisible()
}

format_elapsed <- function(secs) {
  if (is.na(secs)) return("—")
  if (secs < 60) return(sprintf("%ds", round(secs)))
  if (secs < 3600) return(sprintf("%dm %02ds", secs %/% 60, round(secs %% 60)))
  sprintf("%dh %02dm", secs %/% 3600, (secs %% 3600) %/% 60)
}
