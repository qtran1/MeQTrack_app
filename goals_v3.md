# goals_v3 — v1.1.0 release scope

`goals_v2.md` is complete — MVP shipped as **v1.0.0** through Wave 5
(zip with double-click launchers). Everything in this file targets
**v1.1.0** — additive improvements to the existing workflow (robustness,
past-runs library, tunable parameters, per-step execution, UI polish).
Bump `MEQTRACK_VERSION` in `pipeline/methylation_pipeline.R` to
`"1.1.0"` when this release ships.

**v2.0.0 is reserved** for the reference-projection feature — see the
"Next major release" section at the bottom of this doc.

The themes below are the scope of v1.1.0.

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

_Add v1.1.0-era goals below._

---

## Next major release — v2.0.0 (reference projection)

**Vision:** incorporate curated public reference methylome datasets —
**COMET** and **Capper et al. 2018** (central nervous system tumor
classifier, ~91 tumor classes) — into the dimensionality reduction
views. Users upload their own IDATs as usual, and their samples are
*projected onto* the reference t-SNE / UMAP embeddings instead of being
clustered only against each other. This lets a single user's sample be
positioned against thousands of labeled tumor methylomes, surfacing the
nearest reference class(es) as a diagnostic hint.

**Key implementation questions to resolve before committing to scope:**

- Data distribution. Both reference sets are too large to bundle in the
  release zip. Likely path: Bioconductor ExperimentHub (idiomatic) or
  GitHub Releases + lazy download-on-first-use (faster to ship).
- Projection math. UMAP has a native `transform()` for projecting new
  points onto a trained embedding. t-SNE is non-parametric by default;
  options are openTSNE (parametric t-SNE) or a k-NN-in-embedding
  approximation.
- UI. Reference points should be visually distinct from user samples
  (gray/neutral) with class labels on hover; user samples keep the
  teal/brown theme tokens. Probably a toggle for "show/hide reference"
  and a class-filter dropdown.
- Scope discipline. This is not a small feature — keep v2.0.0 focused
  on projection as the single marquee capability.
