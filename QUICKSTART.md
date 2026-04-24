# MeQTrack — Quickstart

End-user install path is **unzip + double-click**. Developer steps for
running from a clone are further down.

## Install (from the release zip)

You need **R ≥ 4.4** and **pandoc ≥ 2.x** on your machine before
launching:

- **R** — <https://cran.r-project.org/>
- **pandoc** — `brew install pandoc` on macOS, or
  <https://pandoc.org/installing.html> on Windows.

Then:

1. Download `MeQTrack_app-<version>.zip` and unzip it anywhere on disk
   (Desktop, `~/Applications`, an external drive — wherever you'd like).
2. **macOS:** double-click `meqtrack.command` inside the unzipped folder.
   **Windows:** double-click `meqtrack.bat`.
3. A Terminal / Command Prompt window opens. The **first launch** runs
   `setup.R` to install all R packages — this takes 5–15 minutes depending
   on network and CPU. Watch the window; the app starts automatically when
   setup finishes.
4. Subsequent launches are instant: the launcher detects the populated
   library cache and skips straight to starting the Shiny server, then
   opens the app in your default browser at `http://127.0.0.1:<port>`.
5. Close the Terminal / Command window to stop the app. Uninstall = delete
   the unzipped folder.

If R or pandoc isn't installed, the launcher prints a clear message
pointing at the install link instead of crashing.

---

## Developer setup (from a clone)

Skip this if you used the release zip above — these steps reproduce the
same environment manually. Useful for working on the code.

### Prerequisites

You need these installed on your Mac before running anything in this doc:

1. **R >= 4.4** — check with `R --version`. Install from
   <https://cran.r-project.org/>.
2. **pandoc >= 2.x** — check with `pandoc --version`. Install via
   `brew install pandoc` if missing.
3. **Xcode Command Line Tools** (for compiling R packages from source) —
   `xcode-select --install` if not already installed.

All other packages (Bioconductor, `yamapData`, `conumee2`, etc.) install
automatically in step 1 below.

### Step 1 — Provision the project

From `/Users/qtran/MeQTrack_app` run:

```sh
Rscript setup.R
```

This will:

- Install `renv` if you don't have it.
- Activate `renv` in this project (creates `.Rprofile` + `renv/`).
- Install CRAN + Bioconductor packages pinned to Bioc 3.20 (R 4.4) or 3.21
  (R 4.5). First run takes ~5-15 min depending on network and CPU because
  several Bioc packages compile from source.
- Install `yamapData` from the bundled `pipeline/data/yamapData_0.0.3.tar.gz`.
- Write `renv.lock` so the environment is reproducible.

Re-running `Rscript setup.R` is safe and cheap — installed packages are
skipped.

### Step 2 — Run the example pipeline end-to-end

From the project root:

```sh
Rscript scripts/run_example.R
```

This invokes `pipeline/methylation_pipeline.R` with `--step all` against
`pipeline/data/example/samplesheet_epic.csv` and writes output to
`runs/example_<timestamp>/`.

Expected output tree:

```
runs/example_<timestamp>/
├── preprocess/
├── qc/
├── filtering/
├── dim_reduction/
├── cnv/
├── report/
│   └── meqtrack_*.html      ← open this in a browser
└── logs/
```

### Step 3 — (Optional) Exercise the callr bridge

`app/R/pipeline_bridge.R` is the thin wrapper the Shiny UI will use in
Wave 3 to launch the pipeline in a background R process. You can prove it
works today with:

```sh
Rscript scripts/test_bridge.R
```

This launches the same pipeline run via `callr::r_bg`, polls the log every
10 seconds, and reports the exit code at the end. If `run_example.R` works,
this will too — it's just a different launch path.

## Wave 1 acceptance checklist

Once steps 1 and 2 pass, walk through the checklist from `mvp-plan.md` →
Wave 1 → **W1-GATE**:

- [ ] `Rscript setup.R` completes without errors on my laptop.
- [ ] `Rscript scripts/run_example.R` produces a
      `runs/example_<id>/report/*.html` that opens in my browser.
- [ ] The report shows the expected sections: QC table, t-SNE, UMAP,
      dendrogram, CNV plots.
- [ ] I'm satisfied that the baseline analysis output is trustworthy before
      any UI work begins.

If all four boxes are checked, Wave 1 is approved and we move to Wave 2
(UI shell + samplesheet validation). If anything is off — package install
failures, pipeline errors, missing report sections — flag it and we fix
before moving on.

### Step 4 — Launch the app (dev mode)

Wave 2 introduces the Shiny UI shell. The pipeline itself is not yet wired
to the UI (that's Wave 3), so at this stage the app is a *pre-flight*
interface: pick a samplesheet, see per-row validation, see the detected
array type, preview optional metadata.

### Launch via double-click (recommended)

**macOS:** in Finder, double-click `meqtrack.command`. A Terminal window
opens, runs the server, and your default browser opens to the app.

**Windows:** in File Explorer, double-click `meqtrack.bat`. A Command
Prompt window opens, runs the server, and your default browser opens to
the app. (The Windows launcher is authored now but will not be smoke-tested
on a real Windows host until Wave 5 — if you hit issues before then, use
the manual fallback below.)

In both cases: **keep the terminal window open** while using the app.
Closing it stops the server.

### Launch manually (fallback)

From the project root:

```sh
R -e 'shiny::runApp("app", launch.browser = TRUE, host = "127.0.0.1")'
```

### First-launch workspace

On first launch the app creates `~/MeQTrack/` with subfolders
`samplesheets/`, `idats/`, and `runs/`. This is the default place to put
your own data; the app also exposes the project folder so you can pick the
bundled example samplesheet at
`pipeline/data/example/samplesheet_epic.csv`.

## Wave 2 acceptance checklist

Work through this against the running app (W2-GATE in `mvp-plan.md` §3):

- [ ] Double-clicking `meqtrack.command` (or `meqtrack.bat` on Windows)
      starts the server and opens the app in a browser.
- [ ] Loading the bundled example
      `pipeline/data/example/samplesheet_epic.csv` shows **4 OK rows**
      with green status and the "Samplesheet OK" badge lights up.
- [ ] Loading an intentionally broken samplesheet (e.g. delete or rename
      one of the IDAT files, or drop a `Sentrix_ID`) shows the offending
      row highlighted red/yellow with a plain-English reason in
      `StatusDetail`, and the overall badge flips to "Samplesheet has
      issues".
- [ ] Array type auto-detects on the example (should show `EPIC`). The
      dropdown override works — setting it to anything other than `auto`
      pins that value regardless of detection.
- [ ] Optional-metadata preview lists any non-required columns present in
      the samplesheet with a short value preview.
- [ ] You're happy with the overall look-and-feel (layout, spacing,
      colors, badge wording). Cosmetic tweaks are cheap to do now.

If all six boxes are checked, Wave 2 is approved and we move to Wave 3
(run controller + live logs + result ingestion).

## Troubleshooting

**`setup.R` fails installing a Bioconductor package.**
Most common cause on macOS is a missing system library (e.g. `libxml2`,
`libssl`). Check the error message; install via Homebrew and re-run.

**`run_example.R` fails at the CNV step.**
Check `runs/example_<id>/logs/` for details. The most common cause is a
missing `yamapData` install — verify
`/Users/qtran/MeQTrack_app/pipeline/data/yamapData_0.0.3.tar.gz` exists and
re-run `setup.R`.

**The report is missing.**
Confirm `pandoc` is installed (`pandoc --version`). The pipeline falls back
to a text-only output if pandoc is absent — you'll see a warning in the
pipeline log.

**Slow first run.**
Expected. Installing Bioconductor from source on a fresh machine is the
long pole. Subsequent runs reuse the `renv` library and start fast.

**Double-clicking `meqtrack.command` does nothing / opens a text editor.**
On macOS, Finder may have lost the executable bit. From a terminal in the
project root:

```sh
chmod +x meqtrack.command
```

Then try again. If macOS Gatekeeper blocks it the first time ("cannot be
opened because it is from an unidentified developer"), right-click the
file → Open → Open, then subsequent double-clicks will work.

**Browser opens but the page fails to load.**
Shiny picks a random free port on 127.0.0.1. Wait a few seconds for the
server to finish starting — the terminal window will print
`Listening on http://127.0.0.1:<port>` when ready. Reload the browser tab
once that line appears.
