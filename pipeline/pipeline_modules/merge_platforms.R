# ---------------------------------------------------------------------------
# Cross-platform cohort merging
#
# Public API:
#   merge_platform_betas(sources, policy = "intersection")
#   merge_platform_sample_info(sources)
#   merge_platform_segments(sources, output_file)
#   merge_platforms(sources, output_dir, policy)
#
# A "source" is one completed single-platform run directory plus the platform
# label it was run as. Preprocessing must be per-platform: minfi's
# read.metharray.exp(force = TRUE) silently truncates to the smallest common
# probe set when IDAT sizes differ, so a mixed cohort read in one shot yields a
# corrupted probe space. We therefore never merge upstream of beta values.
#
# Note on probe IDs: the preprocessing step already strips EPICv2 design
# suffixes (cg00000029_TC21 -> cg00000029) and collapses replicate probes to
# per-CpG means, so beta_values.txt carries plain CpG IDs on every platform.
# .normalize_probe_ids() below is retained as a defensive no-op for the case
# where a caller passes a matrix that has not been through preprocessing.
# ---------------------------------------------------------------------------

#' Strip EPICv2 design suffixes and collapse replicate CpGs to per-CpG means.
#'
#' Mirrors reference_projection.R's .normalize_probe_ids(). A no-op when
#' rownames carry no suffix (450K / EPIC v1, and post-preprocessing EPICv2).
#'
#' @param beta Numeric matrix, probes x samples.
#' @return Matrix with plain-CpG rownames, replicates averaged.
.normalize_probe_ids <- function(beta) {
  beta <- as.matrix(beta)
  pid  <- rownames(beta)
  base <- sub("_.*$", "", pid)
  if (identical(base, pid)) return(beta)

  if (anyDuplicated(base) == 0L) {
    rownames(beta) <- base
    return(beta)
  }
  sums   <- rowsum(beta, base, na.rm = TRUE)
  counts <- rowsum(1 * !is.na(beta), base)
  counts[counts == 0] <- NA_real_          # all-NA group -> NA, not 0/0
  sums / counts
}

#' Read a beta matrix written by write_beta_values().
#'
#' @param path Path to beta_values.txt (or .txt.gz), first column ProbeID.
#' @return Numeric matrix, probes x samples.
.read_beta_file <- function(path) {
  if (!file.exists(path)) stop("Beta file not found: ", path)
  df <- utils::read.delim(path, row.names = 1, check.names = FALSE,
                          stringsAsFactors = FALSE)
  as.matrix(df)
}

#' Normalise the `sources` argument into a validated data frame.
#'
#' Accepts either a named character vector (names = platform labels, values =
#' run directories) or a data frame with `platform` and `dir` columns.
.as_sources <- function(sources) {
  if (is.data.frame(sources)) {
    stopifnot(all(c("platform", "dir") %in% names(sources)))
    out <- sources[, c("platform", "dir")]
  } else {
    if (is.null(names(sources)) || any(!nzchar(names(sources)))) {
      stop("`sources` must be a named vector: names = platform, values = run dir.")
    }
    out <- data.frame(platform = names(sources),
                      dir      = unname(as.character(sources)),
                      stringsAsFactors = FALSE)
  }
  if (nrow(out) < 2) {
    stop("Merging needs at least 2 platform sources; got ", nrow(out), ".")
  }
  if (anyDuplicated(out$platform)) {
    stop("Duplicate platform labels in `sources`: ",
         paste(out$platform[duplicated(out$platform)], collapse = ", "))
  }
  missing <- !dir.exists(out$dir)
  if (any(missing)) {
    stop("Run directory not found for platform(s): ",
         paste(sprintf("%s (%s)", out$platform[missing], out$dir[missing]),
               collapse = "; "))
  }
  out
}

#' Merge per-platform beta matrices into one cohort matrix.
#'
#' Policy "intersection" keeps only CpGs present on every platform, so no value
#' is ever imputed and every sample carries real measurements. This is the safe
#' default for joint dimensionality reduction: dim_reduction.R drops any probe
#' with an NA (see run_tsne/run_umap), and it does so *after*
#' select_variable_probes() has already ranked probes — so a union-style merge
#' would let imputed or missing values steer variable-probe selection and then
#' silently collapse back toward the intersection anyway.
#'
#' @param sources Named vector or data frame of platform -> run directory.
#' @param policy  Currently only "intersection".
#' @param which   "raw" (beta_values.txt) or "filtered"
#'                (filtered_beta_values.txt).
#' @return List: beta (matrix), probes_per_platform, n_common, platform_of_sample.
merge_platform_betas <- function(sources, policy = "intersection",
                                 which = "raw") {
  src <- .as_sources(sources)
  policy <- match.arg(policy, c("intersection"))
  fname <- switch(match.arg(which, c("raw", "filtered")),
                  raw      = "beta_values.txt",
                  filtered = "filtered_beta_values.txt")

  mats <- list()
  n_probes <- integer(nrow(src))
  for (i in seq_len(nrow(src))) {
    p    <- src$platform[i]
    path <- file.path(src$dir[i], "processed_data", fname)
    if (!file.exists(path) && file.exists(paste0(path, ".gz"))) {
      path <- paste0(path, ".gz")
    }
    message(sprintf("merge_platform_betas: reading %s (%s)...", p, basename(path)))
    m <- .normalize_probe_ids(.read_beta_file(path))
    if (anyDuplicated(colnames(m))) {
      stop("Duplicate sample columns within platform ", p, ".")
    }
    mats[[p]]   <- m
    n_probes[i] <- nrow(m)
    message(sprintf("  %s: %d probes x %d samples", p, nrow(m), ncol(m)))
  }
  names(n_probes) <- src$platform

  common <- Reduce(intersect, lapply(mats, rownames))
  if (length(common) == 0) {
    stop("No probes shared across platforms — cannot merge.")
  }
  common <- sort(common)

  # Guard against the same sample appearing under two platforms.
  all_cols <- unlist(lapply(mats, colnames), use.names = FALSE)
  if (anyDuplicated(all_cols)) {
    dup <- unique(all_cols[duplicated(all_cols)])
    stop("Sample(s) present in more than one platform source: ",
         paste(dup, collapse = ", "))
  }

  beta <- do.call(cbind, lapply(mats, function(m) m[common, , drop = FALSE]))
  rownames(beta) <- common

  platform_of_sample <- rep(names(mats), vapply(mats, ncol, integer(1)))
  names(platform_of_sample) <- all_cols

  pct <- 100 * length(common) / max(n_probes)
  message(sprintf(
    "merge_platform_betas: %d common probes (%.1f%% of the largest platform's %d); %d samples total.",
    length(common), pct, max(n_probes), ncol(beta)))
  if (pct < 40) {
    warning(sprintf(
      "merge_platform_betas: intersection retains only %.1f%% of probes — check that platforms were preprocessed consistently.",
      pct))
  }

  # NA audit: intersection removes platform-specific probes but not probes that
  # simply failed detection, so report what dim_reduction will later drop.
  n_na_rows <- sum(apply(beta, 1, anyNA))
  if (n_na_rows > 0) {
    message(sprintf(
      "  note: %d/%d common probes carry >=1 NA and will be dropped by dim reduction.",
      n_na_rows, length(common)))
  }

  list(beta               = beta,
       probes_per_platform = n_probes,
       n_common           = length(common),
       n_na_rows          = n_na_rows,
       platform_of_sample = platform_of_sample)
}

#' Concatenate per-platform sample_info, adding a Platform column.
#'
#' Optionally joins extra columns (e.g. Group) from each platform's
#' samplesheet, which sample_info.txt does not carry.
#'
#' @param sources      Named vector or data frame of platform -> run directory.
#' @param samplesheets Optional named vector platform -> samplesheet CSV.
#' @param join_cols    Columns to lift from the samplesheet when available.
#' @return Data frame with Sample_ID, Platform, and any joined columns.
merge_platform_sample_info <- function(sources, samplesheets = NULL,
                                       join_cols = c("Group")) {
  src <- .as_sources(sources)
  out <- list()

  for (i in seq_len(nrow(src))) {
    p    <- src$platform[i]
    path <- file.path(src$dir[i], "processed_data", "sample_info.txt")
    if (!file.exists(path)) stop("sample_info.txt not found for platform ", p)
    si <- utils::read.delim(path, check.names = FALSE, stringsAsFactors = FALSE)
    si$Platform <- p

    if (!is.null(samplesheets) && p %in% names(samplesheets) &&
        file.exists(samplesheets[[p]])) {
      ss <- utils::read.csv(samplesheets[[p]], stringsAsFactors = FALSE,
                            check.names = FALSE)
      key <- intersect(c("Sample_Name", "Sample_ID", "Sentrix_ID"), names(ss))
      have <- intersect(join_cols, names(ss))
      if (length(key) && length(have) && "Sample_Name" %in% names(si)) {
        idx <- match(si$Sample_Name, ss[[key[1]]])
        for (cn in have) si[[cn]] <- ss[[cn]][idx]
      }
    }
    out[[p]] <- si
  }

  # rbind tolerating differing column sets across platforms.
  all_cols <- unique(unlist(lapply(out, names), use.names = FALSE))
  out <- lapply(out, function(d) {
    for (cn in setdiff(all_cols, names(d))) d[[cn]] <- NA
    d[, all_cols, drop = FALSE]
  })
  merged <- do.call(rbind, out)
  rownames(merged) <- NULL

  if ("Sample_ID" %in% names(merged) && anyDuplicated(merged$Sample_ID)) {
    warning("Duplicate Sample_ID values across platforms in merged sample_info.")
  }
  message(sprintf("merge_platform_sample_info: %d samples across %d platforms.",
                  nrow(merged), nrow(src)))
  merged
}

#' Concatenate per-platform CNV segment files.
#'
#' Segments are genomic intervals, so they are platform-independent once called
#' — this is a plain row concatenation, no probe harmonisation involved. Each
#' platform must therefore be segmented by its own conumee2 annotation first
#' (cnv_analysis.R builds one annotation per run).
#'
#' @param sources     Named vector or data frame of platform -> run directory.
#' @param output_file Optional path to write the merged .seg to.
#' @return Data frame of all segments, with a Platform column.
merge_platform_segments <- function(sources, output_file = NULL) {
  src <- .as_sources(sources)
  segs <- list()

  for (i in seq_len(nrow(src))) {
    p    <- src$platform[i]
    path <- file.path(src$dir[i], "cnv", "segments", "combined_cnv_segments.seg")
    if (!file.exists(path)) {
      warning("No combined_cnv_segments.seg for platform ", p, " — skipping.")
      next
    }
    df <- utils::read.delim(path, check.names = FALSE, stringsAsFactors = FALSE)
    if (nrow(df) == 0) {
      warning("Empty segment file for platform ", p, " — skipping.")
      next
    }
    df$Platform <- p
    segs[[p]] <- df
    message(sprintf("merge_platform_segments: %s -> %d segments.", p, nrow(df)))
  }

  if (length(segs) == 0) {
    warning("No segment files found for any platform; nothing merged.")
    return(NULL)
  }
  if (length(segs) < nrow(src)) {
    warning(sprintf("Merged segments cover %d of %d platforms.",
                    length(segs), nrow(src)))
  }

  common_cols <- Reduce(intersect, lapply(segs, names))
  if (length(common_cols) <= 1) {
    stop("Segment files share no common columns — check .seg formats.")
  }
  dropped <- setdiff(unique(unlist(lapply(segs, names), use.names = FALSE)),
                     common_cols)
  if (length(dropped)) {
    message("  note: dropping non-shared segment column(s): ",
            paste(dropped, collapse = ", "))
  }
  merged <- do.call(rbind, lapply(segs, function(d) d[, common_cols, drop = FALSE]))
  rownames(merged) <- NULL

  if (!is.null(output_file)) {
    dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
    utils::write.table(merged, output_file, sep = "\t", quote = FALSE,
                       row.names = FALSE)
    message(sprintf("merge_platform_segments: wrote %d segments -> %s",
                    nrow(merged), output_file))
  }
  merged
}

#' Merge beta, sample_info and segments from per-platform runs into one cohort.
#'
#' Writes a merged/ tree mirroring a normal run's processed_data + cnv layout,
#' so the existing dim-reduction and reference-projection steps can consume it
#' unchanged. Deliberately does NOT merge RGChannelSets: minfi::combineArrays
#' down-converts to the lowest common probe space and does not support EPICv2
#' alongside EPIC/450k, and none of dim reduction, reference projection, or CNV
#' plotting consumes an RGSet post-segmentation.
#'
#' @param sources      Named vector or data frame of platform -> run directory.
#' @param output_dir   Destination for the merged cohort.
#' @param policy       Probe reconciliation policy; "intersection".
#' @param which        "raw" or "filtered" beta matrices.
#' @param samplesheets Optional platform -> samplesheet CSV, to lift Group etc.
#' @param compress     Gzip the merged beta matrix (default TRUE).
#' @return List with beta, sample_info, segments and the paths written.
merge_platforms <- function(sources, output_dir, policy = "intersection",
                            which = "raw", samplesheets = NULL,
                            compress = TRUE) {
  src <- .as_sources(sources)
  message("=== Merging ", nrow(src), " platforms: ",
          paste(src$platform, collapse = ", "), " ===")

  proc_dir <- file.path(output_dir, "processed_data")
  seg_dir  <- file.path(output_dir, "cnv", "segments")
  dir.create(proc_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(seg_dir,  recursive = TRUE, showWarnings = FALSE)

  bm <- merge_platform_betas(src, policy = policy, which = which)
  si <- merge_platform_sample_info(src, samplesheets = samplesheets)

  # Align sample_info to the beta column order; carry Platform from the merge
  # so the two can never disagree.
  if ("Sample_ID" %in% names(si)) {
    ord <- match(colnames(bm$beta), si$Sample_ID)
    if (anyNA(ord)) {
      warning(sprintf("%d beta column(s) absent from sample_info: %s",
                      sum(is.na(ord)),
                      paste(utils::head(colnames(bm$beta)[is.na(ord)], 5),
                            collapse = ", ")))
    }
    si <- si[ord[!is.na(ord)], , drop = FALSE]
    rownames(si) <- NULL
  }
  si$Platform <- unname(bm$platform_of_sample[
    match(si$Sample_ID, names(bm$platform_of_sample))])

  beta_path <- file.path(proc_dir,
                         if (compress) "beta_values.txt.gz" else "beta_values.txt")
  con <- if (compress) gzfile(beta_path, "w") else file(beta_path, "w")
  on.exit(try(close(con), silent = TRUE), add = TRUE)
  utils::write.table(
    data.frame(ProbeID = rownames(bm$beta), bm$beta, check.names = FALSE),
    con, sep = "\t", quote = FALSE, row.names = FALSE)
  close(con)
  on.exit(NULL)
  message("merge_platforms: wrote ", beta_path)

  si_path <- file.path(proc_dir, "sample_info.txt")
  utils::write.table(si, si_path, sep = "\t", quote = FALSE, row.names = FALSE)
  message("merge_platforms: wrote ", si_path)

  segs <- merge_platform_segments(
    src, output_file = file.path(seg_dir, "combined_cnv_segments.seg"))

  summary_df <- data.frame(
    platform = src$platform,
    n_samples = as.integer(table(bm$platform_of_sample)[src$platform]),
    n_probes  = as.integer(bm$probes_per_platform[src$platform]),
    stringsAsFactors = FALSE)
  summary_df$n_common_probes <- bm$n_common
  utils::write.csv(summary_df, file.path(output_dir, "merge_summary.csv"),
                   row.names = FALSE)

  message("=== Merge complete: ", bm$n_common, " probes x ",
          ncol(bm$beta), " samples ===")
  invisible(list(beta = bm$beta, sample_info = si, segments = segs,
                 summary = summary_df, beta_path = beta_path))
}
