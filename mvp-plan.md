# MeQTrack MVP — Specifications, Stack, and Plan

This document follows the three-part brief in `goals_v2.md` and is scoped to a **single-user web app** wrapping the existing R pipeline in `pipeline/` (see `pipeline/README.md`). The user story / feature groundwork is already captured in `meqtrack-mvp-requirements.md`; this plan builds on that and concretizes it.

**Deployment model.** One user, one deployment. The app runs as a browser-accessible service, either on the user's own machine (`http://localhost:<port>`) or on a single server/VM they control. It is not multi-tenant; there is no account system in the MVP.

**Integration approach (settled):** the UI is built in R with Shiny and installs locally on the user's machine as a plain app folder plus a double-clickable launcher script — no Docker, no server, no container runtime. The pipeline is already R, so the UI can call the existing `pipeline_modules/*.R` functions directly — no cross-language plumbing, no serializing Bioconductor objects across process boundaries.

---

## 1. App specifications

Specifications are grouped by surface area. Each item is phrased so it can be verified ("Given … When … Then …") and maps back to the feature IDs in `meqtrack-mvp-requirements.md`.

### 1.1 Install & run (F-1)

- **S-INST-1.** The app ships as a single folder (zip archive) containing the Shiny app, the pipeline, an `renv` lockfile and its library cache, and a launcher script (`meqtrack.command` on macOS, `meqtrack.bat` on Windows). Installation is: unzip the folder somewhere on disk, double-click the launcher, and a browser tab opens at the running app.
- **S-INST-2.** Double-clicking the launcher brings the app up within 10 seconds on a modern laptop (16 GB RAM) once R is installed. The first launch after a fresh install may take up to 5 minutes while `renv::restore()` compiles packages; that flow shows a terminal progress window and finishes without the user running any R command by hand.
- **S-INST-3.** The app does not require the user to install Bioconductor or pandoc manually. R ≥ 4.4 and pandoc ≥ 2.x are the only host prerequisites; both are documented in the quickstart. Everything else (Bioconductor, yamapData, keep-probe files) is bundled inside the app folder.
- **S-INST-4.** On startup the app verifies that `pipeline/data/yamapData_0.0.3.tar.gz` and `pipeline/data/keep.probes.*.txt` are present on disk. Missing assets produce an actionable error page ("CNV reference bundle not found at `<path>`") in the browser instead of a stack trace.
- **S-INST-5.** The app listens only on `127.0.0.1` (loopback). No authentication is required for the MVP because there is no network-exposed surface by construction.

### 1.2 Samplesheet input & validation (F-2, F-3)

Because the app runs locally, the Shiny server already has full access to the user's filesystem — there is no mount or upload step. The samplesheet and the IDAT files it references are read directly from disk.

- **S-IN-1.** The UI provides a file picker (via `shinyFiles`) rooted at the user's configured workspace (default `~/MeQTrack`) that they can re-root elsewhere in a settings panel. The user selects a CSV samplesheet. The app accepts the format documented in `pipeline/README.md`: required columns `Sentrix_ID`, `Sample_Name`, `Basename`; optional columns (e.g. `Gender`, `Sample_Group`, `diagnosis`) pass through as metadata.
- **S-IN-2.** `Basename` values may be absolute paths or paths relative to the samplesheet's directory. The app resolves them consistently and shows the resolved absolute path in the validation table.
- **S-IN-3.** Before any analysis, the UI displays a per-row validation table with status for each sample: `OK`, `Missing _Red.idat`, `Missing _Grn.idat`, `Duplicate Sentrix_ID`, or `Malformed row`. Rows with errors are visually distinct and prevent the "Run analysis" button from enabling until resolved.
- **S-IN-4.** Array type is auto-detected from IDAT manifest size but can be overridden from a dropdown (`450K`, `EPIC`, `EPICv2`, `auto`).
- **S-IN-5.** Optional samplesheet columns are offered as coloring/annotation variables in dimensionality reduction and clustering views.

### 1.3 Pipeline execution (F-4, F-5, F-12)

- **S-RUN-1.** A single "Run analysis" action executes the standardized pipeline end-to-end: preprocess → QC → filtering → dimensionality reduction → CNV → report. Users cannot select individual steps in the MVP; the pipeline is opinionated.
- **S-RUN-2.** The UI shows per-stage progress: each stage appears as a row with one of `pending`, `running`, `done`, or `failed`, plus elapsed time. The stage currently running displays a live log tail (last 20 lines).
- **S-RUN-3.** The pipeline runs in a background R process (via `callr::r_bg` or `future`) so the UI stays responsive. The user can cancel a run; cancellation terminates the child process and leaves no partial results marked as complete.
- **S-RUN-4.** On stage failure, the run stops. The UI shows the failing stage name, the error message, and a "View log" link. A partially-completed run does not produce a final report.
- **S-RUN-5.** Pipeline parameters (detection-p threshold, variable-probe count, perplexity, etc.) are locked to the pipeline defaults in the MVP. No settings surface in v1.
- **S-RUN-6.** Run outputs are written to the workspace's `runs/` folder (default `~/MeQTrack/runs/`, user-configurable in settings). Each run lives at `<workspace>/runs/<YYYYMMDD-HHMMSS>_<samplesheet-stem>/` with subfolders mirroring the pipeline structure (`preprocess/`, `qc/`, `filtering/`, `dim_reduction/`, `cnv/`, `report/`, `logs/`).

### 1.4 QC review (F-6)

- **S-QC-1.** A QC view shows a sortable table of per-sample metrics: detection-p pass rate, % failed probes, median methylated / unmethylated intensity, bisulfite conversion, and a pass/fail flag per the pipeline's thresholds.
- **S-QC-2.** Samples flagged by QC are visually distinct (marker shape or color) in all downstream plots in the UI, not just in the QC view.
- **S-QC-3.** The QC view links to the pipeline's existing QC plots (intensity histograms, detection-p distributions) rendered inline.

### 1.5 Dimensionality reduction & clustering (F-7, F-8)

- **S-DR-1.** The UI exposes three views that correspond to the pipeline's outputs: **t-SNE**, **UMAP**, and **hierarchical clustering dendrogram**. (Note: the existing pipeline does not compute PCA; the earlier requirements doc's PCA/UMAP wording is reconciled here to match `pipeline_modules/dim_reduction.R`.)
- **S-DR-2.** t-SNE and UMAP scatter plots are interactive: hover reveals sample name; metadata columns from the samplesheet are available as coloring variables via a dropdown.
- **S-DR-3.** The hierarchical clustering view shows the dendrogram with leaf labels annotated by `Sample_Group` when present.
- **S-DR-4.** When `run_tsne` removes duplicate samples, the UI surfaces the names of removed samples visibly on the view, not only in a log file.

### 1.6 CNV review (F-9)

- **S-CNV-1.** The CNV view includes a per-sample, genome-wide plot with segment calls overlaid, and a sample selector to move between samples without leaving the view.
- **S-CNV-2.** A summary CNV heatmap across all samples is available as a separate tab, mirroring the output of `cnv_heatmap.R`.

### 1.7 Reporting (F-10, F-11)

- **S-REP-1.** Every successful run produces a self-contained interactive HTML report at `<workspace>/runs/<run-id>/report/meqtrack_<YYYYMMDD>_<samplesheet-stem>.html`. The report opens in any modern browser on a machine without the app running and without internet access.
- **S-REP-2.** The UI provides two one-click actions on the completed report: "Open report in browser" (opens the file in a new tab) and "Show in Finder/Explorer" (reveals the file on disk so the user can copy it to a collaborator).
- **S-REP-3.** The report content matches the UI: QC table, t-SNE, UMAP, dendrogram, per-sample CNV plots.

### 1.8 Non-functional

- **S-NF-1.** Supported host OSes for the MVP are macOS 13+ and Windows 10+. Linux is best-effort. The only host prerequisites are R ≥ 4.4 and pandoc ≥ 2.x.
- **S-NF-2.** Sample-size envelope for the MVP: 1–96 samples per run. Runs up to 96 samples must complete on a 16 GB machine without swapping.
- **S-NF-3.** All logs for a run are captured to `<workspace>/runs/<run-id>/logs/<stage>.log` so a failed run can be reported without re-execution. The launcher's terminal window also stays open and shows server-level stdout/stderr for deeper debugging.
- **S-NF-4.** The app never silently discards samples. Any sample dropped by the pipeline (QC fail, duplicate in t-SNE, NA-heavy probes) is shown in the UI with the reason.
- **S-NF-5.** Only one pipeline run executes at a time; a second "Run analysis" click while a run is in progress is either disabled or queued with a clear banner. This avoids contention for memory and CPU on a single-user machine.

### 1.9 Out of scope for the MVP

Multi-user access, user accounts and permissions, cloud execution, hosted report sharing, project/run library UI (beyond a simple list of past runs on disk), user-tunable pipeline parameters, HPC submission from the GUI (the existing `hpc.R` stays CLI-only), DMR / differential methylation analysis, and any modification to the pipeline's analytical methods.

---

## 2. Technical stack

The stack is chosen to minimize moving parts: the application is entirely R (pipeline + UI), packages are pinned with `renv`, and the whole thing runs as a local Shiny app that the user starts by double-clicking a launcher script.

### 2.1 Core

| Concern | Choice | Why |
|---|---|---|
| Language | R (≥ 4.4) | Pipeline is already R. |
| UI framework | **Shiny** + **bslib** (Bootstrap 5 theming) | Mature, well-documented, first-class R web framework. `bslib` gives a modern look without hand-writing CSS. |
| HTTP server | Shiny's built-in server (`httpuv`), bound to `127.0.0.1` | No reverse proxy, no TLS, no auth — single-user localhost removes the need for any of that. |
| Reactive orchestration for long jobs | **`ExtendedTask`** (Shiny ≥ 1.8.1) on top of **`promises`** + **`future`** | Keeps the UI responsive while the pipeline runs. Official Shiny pattern for long-running work. |
| Background process isolation | **`callr::r_bg()`** | Runs the pipeline in a fresh R process so a pipeline crash can't kill the UI, and memory is released between runs. Log file is tail-readable live. |
| File picker | **`shinyFiles`** rooted at the user's workspace (default `~/MeQTrack`) | Browses the user's real disk; workspace root is configurable in settings. |
| Tables | **`DT`** (already a pipeline dep) | Sortable, filterable QC and sample tables. |
| Interactive plots | **`plotly`** for t-SNE / UMAP scatter + hover; **`ggplot2`** (static → `plotly::ggplotly`) where acceptable | `plotly` handles hover/tooltips cleanly; most pipeline plots are already `ggplot2`. |
| Dendrogram | **`ggdendro`** + `plotly` | Interactive labels on the existing `hclust` object. |
| CNV karyotype plot | `conumee2`'s built-in `CNV.genomeplot`, wrapped with `plotly::ggplotly` or rendered as a static PNG served by the Shiny session | Keeps parity with the existing pipeline output. |
| Report rendering | **`rmarkdown`** + `pandoc` (already used by `visualization.R::generate_report`) with `self_contained: true` | The pipeline already produces the report; the UI serves the rendered HTML. |

### 2.2 Dependency & environment management

- **`renv`** with a committed `renv.lock`. Bioconductor packages are pinned by Bioconductor release (e.g. `BiocVersion 3.20`) via `BiocManager`.
- **`yamapData_0.0.3.tar.gz`** sits inside the app folder at `pipeline/data/yamapData_0.0.3.tar.gz`. The `renv.lock` references it as a local source so `renv::restore()` installs it from the bundled tarball — never fetched from the network.
- **First-launch provisioning** is handled by the launcher script: it checks for an activated `renv` library; if absent, it runs `renv::restore()` in a visible terminal window, then starts Shiny. On subsequent launches the restore step is a no-op and the app starts immediately.
- The target host environment is R ≥ 4.4 with pandoc ≥ 2.x. Everything else (Bioconductor packages, `yamapData`, `keep.probes` files) lives inside the app folder.

### 2.3 Packaging & distribution

A two-stage strategy — start with the absolute simplest thing, graduate only if needed.

- **Stage 1 (MVP).** Ship a zip archive of the app folder plus an OS-specific launcher:
  - **macOS:** `meqtrack.command` — a shell script that `cd`s into the app folder and runs `R -e 'shiny::runApp("app", launch.browser = TRUE, host = "127.0.0.1")'`. Double-clicking it opens Terminal and brings up the app.
  - **Windows:** `meqtrack.bat` — same idea, invokes `Rscript.exe` and opens the default browser.
  - The launcher runs `renv::restore()` on first launch if the library isn't already provisioned.
  - Install = unzip + double-click. Uninstall = delete folder.
- **Stage 2 (optional, post-MVP).** Wrap the Stage 1 launcher in a proper app bundle:
  - **macOS:** use `Platypus` to wrap `meqtrack.command` into a `.app` with an icon, producing a double-clickable `MeQTrack.app`.
  - **Windows:** use `electricShine` to produce a real `.exe` installer that also bundles a portable R runtime, removing the "R must be installed" prerequisite.
  - Pursue this only after the user confirms Stage 1 works for their day-to-day use.

### 2.4 Repository layout

```
MeQTrack_app/
├── app/
│   ├── app.R                    shiny entrypoint (ui + server)
│   ├── R/
│   │   ├── ui/                  modules: samplesheet_input, qc, dimred, cnv, report, run_controller
│   │   ├── server/              server-side logic mirroring the ui modules
│   │   └── pipeline_bridge.R    thin wrapper around pipeline_modules/* via callr
│   ├── renv.lock
│   └── renv/                    activated via .Rprofile
├── pipeline/                    unchanged copy of the existing pipeline/
│                                (includes data/yamapData_0.0.3.tar.gz, keep.probes.*.txt)
├── meqtrack.command             macOS launcher
└── meqtrack.bat                 Windows launcher
```

The user's workspace (`~/MeQTrack/` by default) is separate from the app folder and holds their data:

```
~/MeQTrack/
├── samplesheets/                user's CSV files (paths they point the app at)
├── idats/                       user's raw IDAT files
└── runs/                        pipeline outputs, one subfolder per run
```

The UI does **not** fork the pipeline code. `pipeline_bridge.R` sources the existing `pipeline/pipeline_modules/*.R` inside the `callr` child so any fix to the pipeline flows through without a UI change.

### 2.5 Observability

- Per-stage log files: `<workspace>/runs/<run-id>/logs/<stage>.log`, produced by redirecting the child process's stdout/stderr.
- A tiny `run_manifest.json` per run records: samplesheet path, array type, start/end timestamps, stage outcomes, package versions (`sessionInfo()`), and the app's git commit. This makes old runs reproducible and debuggable.
- The launcher's terminal window stays open for the app's lifetime and shows Shiny-side stdout/stderr — useful when something fails before a run-specific log exists.

---

## 3. Rolling-wave implementation plan

The plan follows the rolling-wave convention: near-term work is sized to concrete tasks; mid-term work is listed at feature-level; long-term work is phrased as themes and decisions.

**Approval gates.** Every wave ends with a demo-and-approval step: the developer walks the user through the wave's outcome against a short acceptance checklist, the user tries it hands-on, and the next wave does not start until the user signs off. If the user wants changes, those become scoped work at the top of the next wave. The gates are listed explicitly as the last item in each wave below.

### Wave 1 — Foundation (weeks 1–2)

**Outcome:** the pipeline runs end-to-end on the example samplesheet from a clean R session on the user's own machine, using the same `renv`-managed library the eventual app will ship. No UI yet.

- W1-T1. Initialize `renv` at the project root; restore Bioconductor deps pinned to a single release.
- W1-T2. Add `yamapData_0.0.3.tar.gz` to `pipeline/data/` and wire its installation through `renv` (local source entry in `renv.lock`). **This is currently blocking an end-to-end run** (see `pipeline/README.md` caveats).
- W1-T3. Run the pipeline on `pipeline/data/example/samplesheet_epic_8.csv` with `--step all` from a plain R session on the user's machine and confirm the expected output tree.
- W1-T4. Write `pipeline_bridge.R` that runs the pipeline via `callr::r_bg` and streams logs to disk; prove it works from a plain R script.
- W1-T5. Decide report approach for MVP: keep the existing `generate_report()` rmarkdown path, or replace with a Shiny-rendered flat HTML. Default: keep existing, revisit in Wave 3 if it feels rigid.
- **W1-GATE. Demo + approval.** The user runs `Rscript` on the example samplesheet from their own machine and opens the resulting HTML report.
  - [ ] `renv::restore()` completes without errors on the user's laptop.
  - [ ] The pipeline produces a `runs/<id>/report/*.html` that opens in a browser.
  - [ ] The report shows the expected sections (QC table, t-SNE, UMAP, dendrogram, CNV plots).
  - [ ] The user is satisfied that the baseline analysis output is trustworthy before any UI work begins.

### Wave 2 — UI shell + input validation (weeks 3–4)

**Outcome:** a Shiny app the user can launch locally, pick a samplesheet with, and see a per-sample validation table. No pipeline execution yet.

- W2-T1. `app.R` skeleton with `bslib` theme and a three-pane layout (sidebar = inputs, main = tabs, footer = status/log).
- W2-T2. Samplesheet ingestion module: `shinyFiles` picker rooted at the workspace, CSV parser, validator for required columns and IDAT pair existence, per-row status table.
- W2-T3. Array type auto-detect + override dropdown.
- W2-T4. Optional-metadata detection and preview.
- W2-T5. Minimal launcher (`meqtrack.command` on macOS) so the user starts the app the same way they will in production, not via an IDE.
- **W2-GATE. Demo + approval.** The user launches the app themselves and tries both a valid and an intentionally broken samplesheet.
  - [ ] Double-clicking the launcher opens the app in a browser without manual R commands.
  - [ ] Given the bundled example samplesheet, the validation table shows 8 rows all `OK` and the Run button is enabled.
  - [ ] Given a samplesheet with a missing IDAT path, the bad row is visibly flagged and the Run button stays disabled.
  - [ ] The array-type override and optional-metadata preview behave as the user expects.
  - [ ] The user is happy with the look-and-feel of the shell before investing in content tabs.

### Wave 3 — End-to-end run + progress + error surfacing (weeks 5–6)

**Outcome:** clicking Run executes the full pipeline on the example data and produces the existing HTML report, with live progress and error surfacing in the UI.

- W3-T1. Run controller module using `ExtendedTask` + `callr::r_bg`. Emits stage-transition events consumed by the reactive UI.
- W3-T2. Stage progress panel: per-stage state + elapsed time + last-20-lines log tail.
- W3-T3. Cancellation: terminate child process cleanly, mark the run as cancelled, keep partial artifacts only in a `runs/<id>/_cancelled/` subfolder.
- W3-T4. Failure surfacing: pull the last error from the child's stderr, show stage + message + "Open log" link.
- W3-T5. Post-run: "Open report in browser" and "Show in Finder/Explorer" actions on the completed run.
- **W3-GATE. Demo + approval.** The user runs the example samplesheet end-to-end from the UI, and also runs an intentionally failing case.
  - [ ] The Run button triggers a visible per-stage progress panel that updates live without freezing the UI.
  - [ ] A healthy run completes and the user can open the report in one click.
  - [ ] Cancelling mid-run stops the pipeline within a few seconds and does not produce a misleading "done" state.
  - [ ] A forced failure (e.g. corrupt IDAT) shows a clear error with the failing stage and a working "View log" link.
  - [ ] The user is happy with the pace, clarity, and feel of the run experience.

### Wave 4 — In-app result views (weeks 7–9)

**Outcome:** the UI renders QC, dim-reduction, and CNV views natively — the report becomes a shareable artifact, but day-to-day inspection happens in the app.

- W4-T1. QC view: DT table of per-sample metrics, with pass/fail flag column and drill-in to QC plots.
- W4-T2. Dim-reduction views: t-SNE and UMAP scatter via `plotly`, metadata coloring dropdown, hover tooltips with sample name.
- W4-T3. Dendrogram view for hierarchical clustering with metadata-annotated labels.
- W4-T4. CNV view: per-sample genome-wide plot with sample selector, plus a heatmap tab fed by `cnv_heatmap.R` logic.
- W4-T5. QC-fail samples are styled distinctly across all views.
- **W4-GATE. Demo + approval.** The user reviews a full example run inside the app only (no report-in-browser).
  - [ ] QC, t-SNE, UMAP, dendrogram, and CNV views all load from a completed run and match the report's content.
  - [ ] Metadata coloring on t-SNE / UMAP responds correctly to samplesheet columns.
  - [ ] Sample navigation in the CNV view is smooth and doesn't require re-running anything.
  - [ ] The user can judge whether the in-app experience is enough for day-to-day use, or whether the HTML report is still preferred — answer logged as a decision.
  - [ ] **Decision point:** the user confirms whether any pipeline parameter (detection-p threshold, n_variable_probes, perplexity) needs to be tunable. If yes, a settings surface is scoped into Wave 6.

### Wave 5 — Packaging & distribution (weeks 10–11)

**Outcome:** a zip the user downloads, unzips, and double-clicks — no IDE, no `Rscript` incantations, no terminal-only steps.

- W5-T1. Finalize `meqtrack.command` (macOS) and `meqtrack.bat` (Windows). Each launcher checks for R + pandoc, runs `renv::restore()` if needed with visible progress, and starts Shiny with `launch.browser = TRUE, host = "127.0.0.1"`.
- W5-T2. First-launch provisioning UX: a visible terminal window shows `renv::restore()` progress; if R or pandoc is missing, the launcher prints a short explainer pointing to the install docs rather than crashing.
- W5-T3. Build the distributable zip (app folder + pipeline + `renv.lock` + launchers + quickstart.md). Document a two-paragraph install guide.
- W5-T4. Smoke-test the zip on a clean macOS machine and a clean Windows 11 machine using the example samplesheet.
- **W5-GATE. Demo + approval.** The user performs a fresh install from the zip on a machine that has never run MeQTrack.
  - [ ] Unzip + double-click produces a working app within one first-run provisioning cycle (≤ 10 min on a modern laptop with network).
  - [ ] The example samplesheet runs end-to-end from the installed app.
  - [ ] The install doc is understandable to the user without developer help.
  - [ ] The user signs off on v1 being shippable as-is for their own use.

### Wave 6 — Hardening & usability (weeks 12+)

Scoped at a theme level; tasks will be sharpened as Wave 5 completes. Each theme that proceeds ends with its own approval gate before moving on.

- Theme 6a. Robustness: handle mid-run disk-full, corrupt IDAT pair, OOM on large runs, partial pipeline failures that the existing modules don't already catch.
- Theme 6b. Run library: a minimal "Past runs" tab listing `runs/*/run_manifest.json` so the user can re-open a report without navigating the filesystem.
- Theme 6c. Documentation: a short in-app "Getting started" page and a two-page external quickstart.
- Theme 6d. Tunable parameters (**confirmed needed at W4-GATE, 2026-04-23**): build a minimal Settings surface covering at least detection-p threshold, `n_variable_probes`, and t-SNE perplexity — plus any additional pipeline parameters identified during Wave 6 scoping. Defaults stay at the pipeline's current values; the Settings surface persists per-run (recorded in `run_manifest.json`) so re-runs are reproducible.
- Theme 6e. Stage 2 packaging: wrap the Stage 1 launcher in a `Platypus` .app bundle (macOS) and/or an `electricShine` installer (Windows), only if Stage 1 is not adequate.

### Cross-cutting risks & watch items

These aren't tasks but things to keep eyes on throughout the waves.

- **Bioconductor pinning drift.** Pin everything via `renv` + `BiocVersion`, and re-run `renv::restore()` on a clean machine per wave to catch drift early.
- **`yamapData` distribution.** The 257 MB tarball ships inside the app folder at `pipeline/data/`. Watch zip size as a result (target < 500 MB excluding the `renv` library; first-run `renv::restore()` pulls the rest).
- **First-run package compile time.** `renv::restore()` against Bioconductor sources can take 5–15 minutes on a fresh machine. The launcher must show progress, not appear hung.
- **Browser-upload temptation.** Resist letting users upload IDATs through the browser — the app has direct filesystem access, so the samplesheet's `Basename` paths are the right handle. Keep the input model path-based.
- **Report rigidity.** The existing `generate_report()` builds its Rmd on the fly. If future report changes become painful, move to a Shiny-rendered flat HTML (Wave 4 side-output) rather than fighting the Rmd generator.
- **Commented-out `rmSNPandCH` calls** in `pipeline_modules/filtering.R`. Decide before MVP release whether `remove_snps` / `remove_cross_reactive` are claimed features; if yes, uncomment and validate; if no, hide those flags from the UI.
- **Shadowed `select_variable_probes`.** The duplicate definition in `dim_reduction.R` overrides the one in `filtering.R`. Harmless today but confusing; consolidate during Wave 4.

---

## 4. Traceability back to requirements

| Requirement feature | Spec items | Waves |
|---|---|---|
| F-1 Install & launch | S-INST-1..5 | W1, W5 |
| F-2 Samplesheet ingestion | S-IN-1..4 | W2 |
| F-3 Optional metadata | S-IN-5, S-DR-2 | W2, W4 |
| F-4 Pipeline orchestration | S-RUN-1..4 | W3 |
| F-5 Preprocessing | S-RUN-1, S-RUN-5 | W1, W3 |
| F-6 QC metrics | S-QC-1..3 | W4 |
| F-7 Dim reduction | S-DR-1..4 | W4 |
| F-8 Clustering | S-DR-3 | W4 |
| F-9 CNV | S-CNV-1..2 | W4 |
| F-10 Interactive report | S-REP-1, S-REP-3 | W3 |
| F-11 Report saving | S-REP-2 | W3 |
| F-12 Failure surfacing | S-RUN-4, S-NF-3 | W3 |
