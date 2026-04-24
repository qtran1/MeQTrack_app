# goals_v3 — next release

`goals_v2.md` is complete — MVP shipped as **v1.0.0** through Wave 5
(zip with double-click launchers). Everything in this file targets the
**next release version** of the app; current thinking is **v2.0.0** but
a minor bump (v1.1.0) is also defensible if the changes end up being
purely additive. Update `MEQTRACK_VERSION` in
`pipeline/methylation_pipeline.R` when the new release ships.

The themes below are the scope of that release.

## Carried over from the v2 plan (already scoped, not yet built)

These are queued from the existing `mvp-plan.md` Wave 6 themes and the
UI design refresh, ready to pick up when prioritized:

- **Wave 6 Theme 6a — Robustness.** Mid-run disk-full, corrupt IDAT
  pair, OOM on large runs, partial pipeline failures the existing
  modules don't already catch.
- **Wave 6 Theme 6b — Past runs library.** Surface the timestamped
  `runs/<id>/run_manifest.json` history as a "Past runs" tab so a user
  can re-open any prior report without navigating the filesystem.
- **Wave 6 Theme 6c — Documentation.** A short in-app "Getting started"
  page; refresh the external quickstart against the v5 install path.
- **Wave 6 Theme 6d — Tunable parameters.** Settings UI for the
  pipeline parameters inventoried during Wave 4 sign-off. Memory entry
  `project_tunable_parameters.md` has the full candidate list and the
  decision to start with detection-p, n_variable_probes, and
  perplexity. Persist user choices in `run_manifest.json` for
  reproducibility.
- **Wave 6 Theme 6e — Stage-2 packaging.** macOS `.app` bundle (via
  Platypus) and Windows `.exe` installer (via electricShine) — only if
  the v5 unzip + double-click flow turns out to be inadequate in
  practice.
- **Wave 6 Theme 6f — Per-step execution + incremental results.** Let
  users click an individual pipeline step (preprocess / QC / filtering /
  dim_reduction / CNV / visualization) and run only that step, instead
  of `--step all` every time. As each step finishes, its result tab
  populates immediately — e.g. QC tab shows QC results the moment QC
  completes, without waiting for CNV + report. Requires: per-step Run
  buttons in run_controller, partial-bundle emission in results_loader
  (poll for files that exist rather than gating on COMPLETED), and
  dependency guards (block running QC before preprocess exists, etc.).
  Past-runs browser (Theme 6b) pairs well — users can re-open a past
  run just to re-do one stage against it.
- **UI refresh Phase B.** Sidebar layout switch (`page_navbar` →
  `page_sidebar`), unified `status_pill()` component across modules,
  `shinycssloaders` skeleton spinners on every plot/table.
- **UI refresh Phase C.** Tooltips / `?` icons for technical terms,
  plotly style harmonization across all plot types, tighter DT
  styling.

## New themes (placeholder — fill in)

_Add v3-era goals below._
