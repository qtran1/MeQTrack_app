#!/usr/bin/env Rscript
# write_run_config.R <output_dir> <params.json> — write a per-run run_config.R.
#
# Reuses the app's `.write_run_config()` (in pipeline_bridge.R) so the flat ->
# nested parameter translation is identical to the Shiny app and never drifts.
# Sourcing pipeline_bridge.R only defines functions (no side effects).
# Prints the path to the written run_config.R (or nothing if no overrides).
# Run with cwd = project root.

args <- commandArgs(trailingOnly = TRUE)
output_dir  <- args[1]
params_json <- args[2]

suppressWarnings(suppressMessages(
  source(file.path("app", "R", "pipeline_bridge.R"))
))

params <- jsonlite::read_json(params_json, simplifyVector = TRUE)
path <- .write_run_config(output_dir, params)
if (!is.null(path)) cat(path)
