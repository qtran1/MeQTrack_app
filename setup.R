# setup.R — one-time provisioning for MeQTrack_app.
#
# Run from the project root on the user's Mac, with R >= 4.4:
#   Rscript setup.R
#
# What it does:
#   1. Installs `renv` globally if missing.
#   2. Activates renv in this project (creates .Rprofile + renv/).
#   3. Installs BiocManager pinned to a Bioconductor release that matches R's minor version.
#   4. Installs CRAN + Bioconductor dependencies used by the pipeline.
#   5. Installs the bundled yamapData tarball from pipeline/data/.
#   6. Snapshots everything into renv.lock.
#
# Idempotent: safe to re-run. Packages already installed are skipped by renv.

# Use Posit Package Manager (PPM) as the default CRAN mirror on macOS.
# PPM hosts macOS arm64 binaries for current R versions more reliably than
# CRAN itself — including freshly-released package versions where CRAN
# hasn't built the binary yet. This is the main defence against the
# `<cmath> file not found` source-compile failure on macOS Tahoe SDKs.
options(repos = c(CRAN = "https://packagemanager.posit.co/cran/latest"))

# Force binary-only installs on macOS. Recent macOS SDKs (Tahoe / MacOSX26.x)
# break source compilation for R packages that use C++ — clang can't find
# <cmath> because libc++ headers moved within the SDK. CRAN and Bioconductor
# ship arm64 binaries for the supported R versions (4.4 / 4.5 / 4.6), so we
# never need to compile from source on this host. If a package has no binary
# available, fail fast rather than trying to compile — easier to see and fix.
if (.Platform$OS.type == "unix" && Sys.info()[["sysname"]] == "Darwin") {
  options(pkgType = "binary")
  options(install.packages.compile.from.source = "never")
}

# Use all available cores for any compilation that does happen.
options(Ncpus = parallel::detectCores(logical = FALSE))

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
r_ver <- getRversion()
message(sprintf("R version detected: %s", r_ver))

if (r_ver < "4.4.0") {
  stop(
    "MeQTrack_app targets R >= 4.4. Please upgrade R before running setup.R.\n",
    "  See https://cran.r-project.org/"
  )
}

# Let BiocManager pick the Bioconductor release for the running R. The
# pairing isn't 1:1 (Bioc has two releases per year against the same R
# minor — e.g. R 4.5 had both Bioc 3.21 and 3.22) so any hardcoded map
# we ship would go stale every six months. Passing version = NULL to
# BiocManager::install() means "use the current release for this R",
# which is what we want.
message(sprintf(
  "Will let BiocManager pick the Bioconductor release for R %s.", r_ver
))

# Verify we're running from the project root (pipeline/ must exist).
if (!dir.exists("pipeline") || !file.exists("pipeline/methylation_pipeline.R")) {
  stop(
    "setup.R must be run from the MeQTrack_app project root.\n",
    "  Current wd: ", getwd()
  )
}

# Verify yamapData tarball is present.
yamap_tarball <- file.path("pipeline", "data", "yamapData_0.0.3.tar.gz")
if (!file.exists(yamap_tarball)) {
  stop(
    "Missing yamapData tarball at ", yamap_tarball, ".\n",
    "  The CNV step cannot run without it. Place it in pipeline/data/ and re-run."
  )
}

# ---------------------------------------------------------------------------
# 1. renv bootstrap
# ---------------------------------------------------------------------------
if (!requireNamespace("renv", quietly = TRUE)) {
  message("Installing renv...")
  install.packages("renv")
}

# Activate renv in the project (idempotent; creates .Rprofile + renv/ if missing).
if (!file.exists("renv/activate.R")) {
  message("Activating renv in the project...")
  renv::activate()
} else {
  source("renv/activate.R")
}

# Tell renv's implicit dependency scanner to ignore the optional CNV
# backends that the pipeline references via `::` but doesn't run in the
# default path. Without this, every snapshot will re-add ChAMP + ChAMPdata
# to the lockfile and demand they be installed.
renv::settings$ignored.packages(c("ChAMP", "ChAMPdata"))

# ---------------------------------------------------------------------------
# 2. BiocManager, pinned
# ---------------------------------------------------------------------------
if (!requireNamespace("BiocManager", quietly = TRUE)) {
  message("Installing BiocManager...")
  renv::install("BiocManager")
}

# Initialize Bioconductor against whatever release pairs with the
# current R. No version arg means "current" — which is the right
# choice because Bioc's release schedule (twice a year, paired with R)
# doesn't fit a hardcoded map.
BiocManager::install(update = FALSE, ask = FALSE)

# ---------------------------------------------------------------------------
# 3. CRAN dependencies
# ---------------------------------------------------------------------------
cran_packages <- c(
  # Pipeline runtime
  "optparse", "data.table", "ggplot2", "plotly", "Rtsne", "umap",
  "dendextend", "circlize", "htmlwidgets", "rmarkdown", "knitr",
  "DT", "yaml", "ggrepel", "RColorBrewer",
  # App runtime
  "shiny", "bslib", "shinyFiles", "shinycssloaders",
  "promises", "future", "callr",
  "ggdendro", "jsonlite",
  # Needed for the conumee2 GitHub fallback (supports `subdir = ...`)
  "remotes"
)

message("Installing CRAN packages (may take a while on first run)...")
# Use install.packages directly instead of renv::install here. renv::install
# can silently no-op on packages that are already referenced in the lockfile
# but not actually installed (leaving the library incomplete). Going through
# install.packages() + the binary-only options above is more reliable on
# macOS Tahoe hosts.
install.packages(cran_packages, type = "binary",
                 repos = "https://packagemanager.posit.co/cran/latest")

# ---------------------------------------------------------------------------
# 4. Bioconductor dependencies
# ---------------------------------------------------------------------------
# NOTE: pipeline's install_dependencies() lists `conumee`; the code uses
# `conumee2`. conumee2 is not in every Bioc release — we handle it
# separately below with a GitHub fallback.
bioc_packages <- c(
  # core analysis
  "minfi", "limma", "missMethyl", "matrixStats", "snifter",
  "DMRcate", "GenomicRanges", "sesame", "Gviz",
  # Illumina 450K / EPIC / EPICv2 manifests + annotations
  "IlluminaHumanMethylation450kmanifest",
  "IlluminaHumanMethylation450kanno.ilmn12.hg19",
  "IlluminaHumanMethylationEPICmanifest",
  "IlluminaHumanMethylationEPICanno.ilm10b4.hg19",
  "IlluminaHumanMethylationEPICv2manifest",
  "IlluminaHumanMethylationEPICv2anno.20a1.hg38"
)

# NOTE on ChAMP / ChAMPdata:
# The pipeline supports three CNV backends: conumee (default), ChAMP, and
# cnAnalysis450k. Only conumee runs in the default pipeline path and in the
# MVP example. ChAMP is optional — selected by setting
# config$cnv$method = "ChAMP". If a user wants that backend, they install
# ChAMP + ChAMPdata themselves:
#   BiocManager::install(c("ChAMP", "ChAMPdata"),
#                        update = FALSE, ask = FALSE)
# We skip it here to avoid a ~40 MB download from the Bioc 3.21 archive
# mirror (slow, frequently times out) for code that never runs in MVP.

message("Installing Bioconductor packages (this is the slow part)...")
BiocManager::install(bioc_packages, update = FALSE, ask = FALSE)

# conumee2: not in Bioc 3.21. Try Bioc first, fall back to GitHub.
# The GitHub repo hosts the package inside a `conumee2/` subdirectory, so
# we use remotes::install_github(subdir=) rather than renv::install(), which
# would look for DESCRIPTION at the repo root and fail.
if (!requireNamespace("conumee2", quietly = TRUE)) {
  message("Installing conumee2 (Bioc first, GitHub fallback)...")
  bioc_ok <- tryCatch({
    BiocManager::install("conumee2", update = FALSE, ask = FALSE)
    requireNamespace("conumee2", quietly = TRUE)
  }, error = function(e) FALSE, warning = function(w) FALSE)

  if (!isTRUE(bioc_ok)) {
    bioc_label <- tryCatch(
      as.character(BiocManager::version()),
      error = function(e) "(unknown)"
    )
    message("conumee2 not in Bioc ", bioc_label,
            "; installing from GitHub (hovestadtlab/conumee2, subdir=conumee2)...")
    if (!requireNamespace("remotes", quietly = TRUE)) {
      install.packages("remotes", type = "binary",
                       repos = "https://cran.r-project.org")
    }
    remotes::install_github("hovestadtlab/conumee2",
                            subdir = "conumee2",
                            upgrade = "never")
  }
}

# ---------------------------------------------------------------------------
# 5. yamapData from local tarball
# ---------------------------------------------------------------------------
if (!requireNamespace("yamapData", quietly = TRUE)) {
  message(sprintf("Installing yamapData from %s ...", yamap_tarball))
  install.packages(yamap_tarball, repos = NULL, type = "source")
  if (!requireNamespace("yamapData", quietly = TRUE)) {
    stop("yamapData installation failed.")
  }
} else {
  message("yamapData already installed.")
}

# ---------------------------------------------------------------------------
# 6. Snapshot lockfile
# ---------------------------------------------------------------------------
message("Writing renv.lock...")
# type = "implicit" scans only packages actually referenced by project R
# scripts (setup.R, pipeline/*, app/*, scripts/*), so it ignores unrelated
# packages that may already live in the user's library.
# force = TRUE skips the interactive prompt when renv sees packages it
# can't classify (e.g. yamapData installed from a local tarball).
renv::snapshot(prompt = FALSE, type = "implicit", force = TRUE)

message("\nDone. Next: Rscript scripts/run_example.R")
