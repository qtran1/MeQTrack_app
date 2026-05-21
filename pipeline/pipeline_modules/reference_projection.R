# reference_projection.R
# ---------------------------------------------------------------------------
# Reference-projection module (MeQTrack v2.0.0).
#
# Projects user methylation samples onto a pre-trained reference t-SNE
# embedding, so a query sample is positioned against thousands of labelled
# reference methylomes instead of being clustered only against itself.
#
# Projection engine: snifter::project() (an R wrapper around openTSNE).
# snifter::project(x, new, old) recomputes the affinities of `old` and
# checks them against the embedding's stored affinities — so `old` MUST be
# the *complete, unmodified* reference beta matrix the embedding was built
# on. Probe harmonisation therefore happens on the QUERY side only: the
# query is reshaped to exactly the reference probe set (same probes, same
# order), imputing any it lacks with the reference per-probe mean.
#
# The reference embedding was built from SWAN-normalised betas, so the
# query is preprocessed with preprocessSWAN() to match.
#
# Functions:
#   load_reference(dataset, reference_dir)
#   preprocess_query_swan(samplesheet)
#   harmonize_query(query_beta, ref_beta)
#   project_onto_reference(reference, query_beta_harmonized, perplexity)
#   plot_reference_projection(reference, projected, output_dir, file)
#   run_reference_projection(samplesheet, dataset, reference_dir, output_dir, perplexity)
# ---------------------------------------------------------------------------

# Registry of available reference datasets. Each entry names the files under
# reference_dir and the metadata columns carrying the Sentrix ID, the
# tumour-class label, and the per-class plotting colour. v2.0.0 ships the
# COMET primary-diagnostic set; the full 4685-sample COMET set is a v2.1
# candidate and would be added here.
.REFERENCE_DATASETS <- list(
  COMET_1915 = list(
    label       = "COMET primary-diagnostic (1915 patient tumours)",
    embedding   = "tSNE_embedding_1915sample_overlap_probesEPICv1andv2.RData",
    beta_rds    = "beta_1915_COMET.rds",
    beta_csv    = "beta_top10K_COMET_ped_patient_diagnostic_primary1915samples2.csv",
    metadata    = "COMET_Labkey_August_12_2025.csv",
    sentrix_col = "X850k Tumor File Name",
    class_col   = "Tumor Group For Clustering",
    color_col   = "Col"
  )
)

# ---------------------------------------------------------------------------
# Load a reference dataset
# ---------------------------------------------------------------------------

#' Load a reference embedding, its training beta matrix, and its metadata.
#'
#' @param dataset       Key into \code{.REFERENCE_DATASETS} (default "COMET_1915").
#' @param reference_dir Directory holding the reference files.
#' @return A list with: dataset, label, embedding (snifter object),
#'   ref_beta (probes x samples, aligned to the embedding), and ref_meta
#'   (data frame: Sentrix, tSNE1, tSNE2, tumor_group, color).
load_reference <- function(dataset = "COMET_1915", reference_dir = "reference") {
  spec <- .REFERENCE_DATASETS[[dataset]]
  if (is.null(spec)) {
    stop("Unknown reference dataset '", dataset, "'. Known: ",
         paste(names(.REFERENCE_DATASETS), collapse = ", "))
  }

  # --- embedding (a single snifter object inside the .RData) ---
  emb_path <- file.path(reference_dir, spec$embedding)
  if (!file.exists(emb_path)) stop("Reference embedding not found: ", emb_path)
  ee <- new.env()
  load(emb_path, envir = ee)
  embedding <- get(ls(ee)[1], envir = ee)
  if (is.null(rownames(embedding))) {
    stop("Reference embedding '", dataset, "' has no rownames — cannot map ",
         "rows to samples. (See goals_v4.md: the 4685-sample embedding has ",
         "this problem; the 1915 set does not.)")
  }

  # --- reference beta matrix: prefer the compact .rds, fall back to CSV ---
  rds <- file.path(reference_dir, spec$beta_rds)
  csv <- file.path(reference_dir, spec$beta_csv)
  if (file.exists(rds)) {
    ref_beta <- readRDS(rds)
  } else if (file.exists(csv)) {
    message("load_reference: parsing reference beta CSV (slow) and caching as .rds ...")
    suppressPackageStartupMessages(library(data.table))
    d <- as.data.frame(data.table::fread(csv))
    rownames(d) <- d[[1]]
    ref_beta <- as.matrix(d[, -1, drop = FALSE])
    saveRDS(ref_beta, rds)
  } else {
    stop("Reference beta matrix not found (looked for ", rds, " and ", csv, ")")
  }
  ref_beta <- as.matrix(ref_beta)

  # Align beta columns to the embedding's sample order.
  if (!identical(colnames(ref_beta), rownames(embedding))) {
    if (!setequal(colnames(ref_beta), rownames(embedding))) {
      stop("Reference beta samples do not match the embedding samples.")
    }
    ref_beta <- ref_beta[, rownames(embedding), drop = FALSE]
  }

  # --- metadata: pull Sentrix / tumour-group / colour, aligned to embedding ---
  md_path <- file.path(reference_dir, spec$metadata)
  if (!file.exists(md_path)) stop("Reference metadata not found: ", md_path)
  suppressPackageStartupMessages(library(data.table))
  md <- as.data.frame(data.table::fread(md_path))
  for (col in c(spec$sentrix_col, spec$class_col, spec$color_col)) {
    if (!col %in% colnames(md)) {
      stop("Metadata is missing expected column '", col, "'.")
    }
  }
  idx <- match(rownames(embedding), as.character(md[[spec$sentrix_col]]))
  if (anyNA(idx)) {
    warning(sprintf("load_reference: %d embedding samples have no metadata row.",
                    sum(is.na(idx))))
  }
  ref_meta <- data.frame(
    Sentrix     = rownames(embedding),
    tSNE1       = as.numeric(embedding[, 1]),
    tSNE2       = as.numeric(embedding[, 2]),
    tumor_group = as.character(md[[spec$class_col]])[idx],
    color       = as.character(md[[spec$color_col]])[idx],
    stringsAsFactors = FALSE
  )
  ref_meta$tumor_group[is.na(ref_meta$tumor_group) | ref_meta$tumor_group == ""] <- "Unknown"

  message(sprintf("load_reference: '%s' — %d reference samples, %d probes, %d tumour groups.",
                  dataset, nrow(embedding), nrow(ref_beta),
                  length(unique(ref_meta$tumor_group))))

  list(dataset = dataset, label = spec$label, embedding = embedding,
       ref_beta = ref_beta, ref_meta = ref_meta)
}

# ---------------------------------------------------------------------------
# Preprocess a query (IDATs -> SWAN-normalised betas)
# ---------------------------------------------------------------------------

#' Read query IDATs and SWAN-normalise, to match the reference's preprocessing.
#'
#' @param samplesheet A data frame with a \code{Basename} column, a path to
#'   such a CSV, or a directory of IDAT files.
#' @return Beta matrix, probes x samples.
preprocess_query_swan <- function(samplesheet) {
  suppressPackageStartupMessages(library(minfi))

  if (is.character(samplesheet) && length(samplesheet) == 1L && dir.exists(samplesheet)) {
    rgset <- read.metharray.exp(base = samplesheet, recursive = TRUE, force = TRUE)
  } else {
    if (is.character(samplesheet)) {
      suppressPackageStartupMessages(library(data.table))
      ss <- as.data.frame(data.table::fread(samplesheet))
    } else {
      ss <- as.data.frame(samplesheet)
    }
    if (!"Basename" %in% colnames(ss)) {
      stop("Query samplesheet needs a 'Basename' column.")
    }
    rgset <- read.metharray.exp(targets = ss, recursive = TRUE, force = TRUE)
  }

  message(sprintf("preprocess_query_swan: %d query sample(s); running SWAN ...",
                  ncol(rgset)))
  mset <- preprocessSWAN(rgset)
  getBeta(mset)
}

# ---------------------------------------------------------------------------
# Harmonise a query beta matrix to the reference probe set
# ---------------------------------------------------------------------------

#' Reshape a query beta matrix to exactly the reference probe set.
#'
#' snifter::project() requires \code{ncol(new) == ncol(old)} with matching
#' features, and \code{old} cannot be modified — so the query must carry
#' every reference probe, in the reference's order. Probes the query lacks,
#' and any residual NA values, are imputed with the reference per-probe mean
#' (a neutral choice that does not pull the sample toward any class).
#'
#' @param query_beta Query beta matrix, probes x samples.
#' @param ref_beta   Reference beta matrix, probes x samples.
#' @return Query beta matrix, reference-probes x query-samples.
harmonize_query <- function(query_beta, ref_beta) {
  query_beta <- as.matrix(query_beta)
  ref_probes <- rownames(ref_beta)

  common  <- intersect(ref_probes, rownames(query_beta))
  pct     <- 100 * length(common) / length(ref_probes)
  n_imput <- length(ref_probes) - length(common)
  message(sprintf("harmonize_query: %d/%d reference probes found in query (%.1f%%); %d probe(s) imputed.",
                  length(common), length(ref_probes), pct, n_imput))
  if (pct < 80) {
    warning(sprintf("harmonize_query: only %.1f%% of reference probes present — ",
                    pct), "projection may be unreliable.")
  }

  ref_mean <- rowMeans(ref_beta, na.rm = TRUE)

  # Start every probe at the reference mean, then overwrite with query values.
  out <- matrix(ref_mean, nrow = length(ref_probes), ncol = ncol(query_beta),
                dimnames = list(ref_probes, colnames(query_beta)))
  out[common, ] <- query_beta[common, , drop = FALSE]

  # Replace residual NA (failed probes) with the reference mean.
  na_idx <- which(is.na(out), arr.ind = TRUE)
  if (nrow(na_idx) > 0) {
    out[na_idx] <- ref_mean[na_idx[, 1]]
    message(sprintf("harmonize_query: imputed %d residual NA value(s).", nrow(na_idx)))
  }
  out
}

# ---------------------------------------------------------------------------
# Project the query onto the reference embedding
# ---------------------------------------------------------------------------

#' Project a harmonised query onto a reference t-SNE embedding.
#'
#' @param reference              A list from \code{load_reference()}.
#' @param query_beta_harmonized  Output of \code{harmonize_query()}.
#' @param perplexity             Perplexity for the projection's own kNN
#'                               (snifter::project default = 5).
#' @return Data frame: Sample, tSNE1, tSNE2.
project_onto_reference <- function(reference, query_beta_harmonized,
                                   perplexity = 5) {
  suppressPackageStartupMessages(library(snifter))

  # snifter expects samples x features for both `new` and `old`.
  old <- t(as.matrix(reference$ref_beta))     # reference samples x probes
  new <- t(as.matrix(query_beta_harmonized))  # query samples x probes

  stopifnot(identical(colnames(old), colnames(new)))   # same probes, same order
  stopifnot(nrow(old) == nrow(reference$embedding))    # old aligns to embedding

  message(sprintf("project_onto_reference: projecting %d query sample(s) onto '%s' ...",
                  nrow(new), reference$dataset))
  coords <- snifter::project(reference$embedding, new = new, old = old,
                             perplexity = perplexity)
  coords <- as.matrix(coords)[, 1:2, drop = FALSE]

  data.frame(
    Sample = rownames(new),
    tSNE1  = as.numeric(coords[, 1]),
    tSNE2  = as.numeric(coords[, 2]),
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# Plot the projection
# ---------------------------------------------------------------------------

# Replace any colour string R can't parse with a generated fallback.
.safe_color_map <- function(col_map) {
  ok <- vapply(col_map, function(cc) {
    !is.na(cc) && tryCatch({ grDevices::col2rgb(cc); TRUE },
                           error = function(e) FALSE)
  }, logical(1))
  if (any(!ok)) col_map[!ok] <- grDevices::rainbow(sum(!ok))
  col_map
}

#' Plot the reference embedding with the projected query samples overlaid.
#'
#' @param reference  A list from \code{load_reference()}.
#' @param projected  Data frame from \code{project_onto_reference()}.
#' @param output_dir Directory for the PDF.
#' @param file       Optional explicit output path.
#' @return The output PDF path (invisibly).
plot_reference_projection <- function(reference, projected, output_dir = ".",
                                      file = NULL) {
  suppressPackageStartupMessages(library(ggplot2))
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  if (is.null(file)) {
    file <- file.path(output_dir,
                      sprintf("reference_projection_%s.pdf", reference$dataset))
  }

  rm_ <- reference$ref_meta
  rm_$tumor_group <- factor(rm_$tumor_group)
  col_map <- tapply(rm_$color, rm_$tumor_group, function(x) x[1])
  col_map <- .safe_color_map(col_map)

  p <- ggplot() +
    geom_point(data = rm_,
               aes(x = tSNE1, y = tSNE2, fill = tumor_group),
               shape = 21, size = 1.6, stroke = 0.1,
               colour = "grey75", alpha = 0.55) +
    scale_fill_manual(values = col_map, name = "Reference\ntumour group") +
    geom_point(data = projected,
               aes(x = tSNE1, y = tSNE2),
               shape = 23, size = 3.6, stroke = 0.7,
               fill = "#111111", colour = "white") +
    geom_text(data = projected,
              aes(x = tSNE1, y = tSNE2, label = Sample),
              size = 2.8, vjust = -1.1, fontface = "bold") +
    labs(title = sprintf("Query projected onto %s", reference$label),
         subtitle = sprintf("%d query sample(s); black diamonds = query, coloured = reference",
                            nrow(projected)),
         x = "t-SNE 1", y = "t-SNE 2") +
    theme_bw(base_size = 12) +
    theme(legend.text = element_text(size = rel(0.7)),
          panel.grid.minor = element_blank())

  ggsave(file, p, width = 10, height = 8)
  message("plot_reference_projection: wrote ", file)
  invisible(file)
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

#' Run the full reference projection: query IDATs -> projected coordinates.
#'
#' @param samplesheet   Query samplesheet (data frame / CSV path / IDAT dir).
#' @param dataset       Reference dataset key (default "COMET_1915").
#' @param reference_dir Directory holding the reference files.
#' @param output_dir    Directory for the coordinate CSV and plot PDF.
#' @param perplexity    Projection perplexity (default 5).
#' @return A list: reference, projected (data frame), csv, pdf.
run_reference_projection <- function(samplesheet,
                                     dataset       = "COMET_1915",
                                     reference_dir = "reference",
                                     output_dir    = ".",
                                     perplexity    = 5) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  reference  <- load_reference(dataset, reference_dir)
  query_beta <- preprocess_query_swan(samplesheet)
  query_h    <- harmonize_query(query_beta, reference$ref_beta)
  projected  <- project_onto_reference(reference, query_h, perplexity)

  csv <- file.path(output_dir, sprintf("reference_projection_%s.csv", dataset))
  write.csv(projected, csv, row.names = FALSE)
  pdf <- plot_reference_projection(reference, projected, output_dir)

  message(sprintf("run_reference_projection: done — %d sample(s) projected onto '%s'.",
                  nrow(projected), dataset))
  invisible(list(reference = dataset, projected = projected,
                 csv = csv, pdf = pdf))
}
