#!/usr/bin/env Rscript
# summarize.R <run_dir> [what] — summarize an .RData result as JSON.
#
# Reuses the app's load_results_bundle(). Currently handles "cnv": per-sample
# gain/loss segment counts. Best-effort — degrades to {available:false}.
# Run with cwd = project root.

`%||%` <- function(a, b) if (is.null(a)) b else a

args <- commandArgs(trailingOnly = TRUE)
run_dir <- args[1]
what    <- if (length(args) >= 2) args[2] else "cnv"

emit <- function(x) cat(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null"))

bundle <- tryCatch({
  suppressWarnings(suppressMessages(
    source(file.path("app", "R", "results_loader.R"))
  ))
  load_results_bundle(run_dir)
}, error = function(e) NULL)

if (is.null(bundle) || is.null(bundle$cnv) || is.null(bundle$cnv$segments)) {
  emit(list(available = FALSE, message = "No CNV segments found — run the 'cnv' step."))
  quit(status = 0)
}

seg <- as.data.frame(bundle$cnv$segments)
pick <- function(cands) { for (n in cands) if (n %in% names(seg)) return(n); NA_character_ }
c_id   <- pick(c("ID", "Sample", "sample_id", "Sample_ID"))
c_mean <- pick(c("seg.mean", "Seg_Mean", "mean"))

if (is.na(c_id) || is.na(c_mean)) {
  emit(list(available = FALSE, message = "CNV segments missing expected columns."))
  quit(status = 0)
}

gain <- 0.18; loss <- -0.20
ids <- unique(as.character(seg[[c_id]]))
per_sample <- lapply(ids, function(s) {
  m <- as.numeric(seg[[c_mean]][as.character(seg[[c_id]]) == s])
  list(sample = s,
       n_segments = length(m),
       n_gain = sum(m > gain, na.rm = TRUE),
       n_loss = sum(m < loss, na.rm = TRUE))
})

emit(list(
  available = TRUE,
  gain_threshold = gain,
  loss_threshold = loss,
  n_samples = length(ids),
  per_sample = per_sample
))
