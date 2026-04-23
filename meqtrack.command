#!/usr/bin/env bash
# meqtrack.command — macOS launcher for MeQTrack.
#
# Double-click this file in Finder to start the app. Terminal.app opens,
# this script runs, Shiny starts, and your default browser opens to the
# app on http://127.0.0.1:<port>.
#
# The terminal window stays open while the app is running so you can see
# server-level logs. Close it to stop the app.

set -e

# Resolve the script's own directory (robust to spaces, symlinks, and
# being run from anywhere). This lets the user put MeQTrack_app wherever
# they like — the launcher always cds to its sibling app/ and pipeline/.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "${SCRIPT_DIR}"

echo "=============================================================="
echo "  MeQTrack — launching..."
echo "  Project: ${SCRIPT_DIR}"
echo "=============================================================="

# 1. Check R is on PATH. We don't try to install R ourselves.
if ! command -v Rscript >/dev/null 2>&1; then
  cat <<'EOS'

  ERROR: Rscript not found on your PATH.

  MeQTrack needs R >= 4.4 installed. Install from:
      https://cran.r-project.org/bin/macosx/
  and then re-run this launcher.

EOS
  echo "Press Return to close this window."
  read -r _
  exit 1
fi

# 2. Check pandoc (needed by the pipeline's report generator).
if ! command -v pandoc >/dev/null 2>&1; then
  cat <<'EOS'

  WARNING: pandoc not found on your PATH.

  The HTML report generator falls back to a plain-text report when pandoc
  is missing. Install via Homebrew to enable the full report:
      brew install pandoc

  Continuing anyway...

EOS
fi

# 3. Start Shiny. runApp reads app/app.R; renv activates automatically via
#    the project's .Rprofile so the installed library is used.
echo "Starting Shiny server on http://127.0.0.1 ..."
echo "(Close this Terminal window to stop the app.)"
echo

exec Rscript -e 'shiny::runApp("app", launch.browser = TRUE, host = "127.0.0.1")'
