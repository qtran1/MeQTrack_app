# MeQTrack

**Me**thylation **Q**uality control and analysis **Track**ing — a
single-user desktop app for Illumina methylation arrays (450K, EPIC,
EPICv2). MeQTrack runs the analysis (QC, dimensionality reduction,
copy-number variation, self-contained HTML report) **and tracks every
run**: each invocation writes a timestamped folder with its samplesheet,
parameters, logs, and outputs, so any past run is reproducible and
re-openable.

The app runs entirely on your machine. No cloud, no upload, no account.
Your data never leaves your laptop.

## What it does

Drop a CSV samplesheet pointing at your IDAT files into the app. One
click runs a six-stage pipeline:

| Stage | What happens |
|---|---|
| **Preprocess** | Reads IDATs (auto-detects 450K / EPIC / EPICv2), applies SWAN normalization (or Sesame-based for EPICv2), produces β-values. |
| **QC** | Per-sample detection-p, failed-probe percentage, intensity medians, bisulfite conversion. Flags samples that fall outside thresholds. |
| **Filtering** | Removes probes failing detection-p, sex-chromosome probes, SNP-affected probes, cross-reactive probes, and applies array-specific keep-lists. |
| **Dimensionality reduction** | t-SNE, UMAP, hierarchical clustering on the most variable probes. |
| **CNV** | Copy-number profile per sample (via conumee2), genome-wide segment calls, frequency plot, and a sample-vs-segment heatmap. |
| **Report** | A self-contained HTML report you can open in any browser or share by email. |

The Shiny UI surfaces every stage interactively:

- **Samplesheet tab** — pick a CSV, see per-row validation (missing
  IDATs, duplicate IDs, malformed rows) before running anything.
- **Run tab** — Run / Cancel, live per-stage progress, log tail,
  post-run actions (open report, reveal in Finder/Explorer).
- **QC tab** — sortable per-sample metrics table, embedded interactive
  density and MDS plots; QC-fail samples are styled distinctly across
  every downstream view.
- **Dim. reduction tab** — interactive plotly t-SNE, UMAP, and
  dendrogram. Color points by any metadata column from your samplesheet
  (Sample_Group, Diagnosis, Batch, etc.).
- **CNV tab** — per-sample genome-wide CNV profile (PDF embed),
  population frequency plot, and an in-browser segment heatmap with a
  tunable color-scale cap.
- **Report tab** — in-app preview of the generated HTML report, plus
  one-click "Open in new tab" and "Show in Finder/Explorer".

## Installing & running

End-user install is **unzip + double-click**. Full instructions in
[QUICKSTART.md](QUICKSTART.md).

Prerequisites: **R ≥ 4.4** and **pandoc ≥ 2.x**. Everything else
(Bioconductor, conumee2, yamapData, sesame) installs automatically on
first launch.

Supported hosts: macOS 13+ and Windows 10+. Linux is best-effort.

## Workflow at a glance

```
Your IDATs  ─►  samplesheet.csv  ─►  Samplesheet tab (validate)
                                          │
                                          ▼
                                    Run tab (analyze)
                                          │
                                          ▼
            QC ── Dim. red. ── CNV ── Report (review in app)
                                          │
                                          ▼
                            self-contained HTML report
                            (shareable; opens offline)
```

The pipeline writes everything to your workspace folder
(`~/MeQTrack/runs/<timestamp>_<samplesheet>/` by default), so every run
is reproducible and you keep your raw data alongside its outputs.

## For developers / CLI users

- **CLI usage** of the underlying R pipeline (no UI required): see
  [`pipeline/README.md`](pipeline/README.md).
- **Per-sample feature catalog** (what every metric / plot represents,
  with feature IDs F-1 through F-12): see
  [`meqtrack-mvp-requirements.md`](meqtrack-mvp-requirements.md).
- **Working from a clone** (instead of the release zip): the
  "Developer setup" section of [QUICKSTART.md](QUICKSTART.md) walks
  through `Rscript setup.R` and the manual launch path.

## Limits & caveats

- One run at a time. The MVP doesn't queue concurrent runs.
- Sample-size envelope: 1–96 samples per run; tested up to 96 on a
  16 GB machine.
- Pipeline parameters (detection-p threshold, n_variable_probes, t-SNE
  perplexity, etc.) are fixed at sensible defaults in the MVP. A
  Settings UI to tune them is on the roadmap.
- The app listens only on `127.0.0.1` (loopback). It is not
  network-accessible, by construction.
