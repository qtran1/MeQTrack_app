#!/usr/bin/env Rscript
# datasets.R — print the reference-dataset registry as JSON.
#
# Reuses `.REFERENCE_DATASETS` from the pipeline (single source of truth) so
# the MCP server never drifts from what the pipeline actually supports.
# Run with cwd = project root (relative source path + renv).
#   Rscript mcp/r/datasets.R

`%||%` <- function(a, b) if (is.null(a)) b else a

suppressWarnings(suppressMessages(
  source(file.path("pipeline", "pipeline_modules", "reference_projection.R"))
))

ds <- .REFERENCE_DATASETS
out <- lapply(names(ds), function(k) {
  d <- ds[[k]]
  list(
    key       = k,
    label     = d$label %||% k,
    embedding = d$embedding %||% NA_character_,
    beta_rds  = d$beta_rds %||% NA_character_,
    metadata  = d$metadata %||% NA_character_,
    class_col = d$class_col %||% NA_character_
  )
})

cat(jsonlite::toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = "null"))
