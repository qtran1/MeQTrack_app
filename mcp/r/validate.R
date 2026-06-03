#!/usr/bin/env Rscript
# validate.R <samplesheet.csv> — validate a samplesheet, print JSON.
#
# Reuses the app's validators.R + array_detect.R so the MCP server applies the
# exact same checks as the Shiny Samplesheet tab.
# Run with cwd = project root.

args <- commandArgs(trailingOnly = TRUE)
ss <- args[1]

emit <- function(x) cat(jsonlite::toJSON(x, auto_unbox = TRUE, pretty = TRUE, null = "null"))

if (is.na(ss) || !nzchar(ss)) {
  emit(list(ok = FALSE, error = "Usage: validate.R <samplesheet.csv>")); quit(status = 0)
}

suppressWarnings(suppressMessages({
  source(file.path("app", "R", "validators.R"))
  source(file.path("app", "R", "array_detect.R"))
}))

rs <- read_samplesheet(ss)
if (!is.null(rs$df)) df <- rs$df else df <- NULL
if (is.null(df)) {
  emit(list(ok = FALSE, error = rs$error %||% paste("Could not read samplesheet:", ss)))
  quit(status = 0)
}

ss_dir   <- rs$samplesheet_dir %||% dirname(normalizePath(ss))
pipe_dir <- normalizePath(file.path("pipeline"), mustWork = FALSE)

v   <- validate_rows(df, ss_dir, pipe_dir)
sm  <- validation_summary(v)
arr <- tryCatch(detect_array_from_samplesheet(v),
                error = function(e) list(array_type = NA_character_, reason = conditionMessage(e)))

rows <- lapply(seq_len(nrow(v)), function(i) {
  list(
    sample_name = as.character(v$Sample_Name[i]),
    sentrix_id  = as.character(v$Sentrix_ID[i]),
    status      = as.character(v$Status[i]),
    detail      = as.character(v$StatusDetail[i])
  )
})

emit(list(
  ok           = isTRUE(sm$ok),
  n_total      = sm$n_total,
  n_ok         = sm$n_ok,
  n_bad        = sm$n_bad,
  array_type   = arr$array_type,
  array_reason = arr$reason,
  rows         = rows
))
