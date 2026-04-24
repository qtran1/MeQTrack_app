# goals_v3 — post-MVP

`goals_v2.md` is complete (MVP shipped through Wave 5). This file
captures the next round of work.

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
- **UI refresh Phase B.** Sidebar layout switch (`page_navbar` →
  `page_sidebar`), unified `status_pill()` component across modules,
  `shinycssloaders` skeleton spinners on every plot/table.
- **UI refresh Phase C.** Tooltips / `?` icons for technical terms,
  plotly style harmonization across all plot types, tighter DT
  styling.

## New themes (placeholder — fill in)

_Add v3-era goals below._
