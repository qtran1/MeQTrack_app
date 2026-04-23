# MeQTrack Desktop MVP — Requirements

## 1. Context

MeQTrack is an existing DNA methylation analysis pipeline that processes raw Illumina methylation array data (paired Red/Green IDAT files) and produces preprocessing, QC, dimensionality reduction (PCA/UMAP), unsupervised clustering, and copy number variation (CNV) results. The pipeline currently lives at `/Volumes/qtran/MeQTrack` and requires command-line expertise to use.

The goal of this MVP is to wrap that pipeline in a user-friendly desktop application so that researchers can run a complete analysis end-to-end without touching a terminal. A user installs the app locally, points it at a CSV samplesheet that lists `Sentrix_ID` and `Basename` columns, and the system runs the standardized pipeline and produces an interactive HTML report covering QC, sample relationships, clustering, and genome-wide CNV. The product is closely modeled on [mepylome](https://mepylome.readthedocs.io/en/latest/).

Scope for this MVP is the single-machine, single-user case: one researcher analyzing one batch of samples on their own desktop. Multi-user collaboration, cloud execution, hosted result sharing, and modifications to the underlying analytical methods are out of scope.

## 2. User roles

| Role | What they're trying to accomplish in the system |
|------|-------------------------------------------------|
| Researcher | Take a batch of methylation array samples from raw IDATs to interpretable QC, clustering, and CNV results without writing code or running a CLI. |

Clinicians are named in the goals document as a downstream beneficiary of the analysis but the spec also states the app is "used internally by researchers" — the MVP treats clinician as a non-user. See Open Questions Q1.

## 3. User stories

All stories below are for the Researcher role (prefix `RES`).

```
**US-RES-1: Install and launch the app locally**
As a researcher,
I want to install MeQTrack on my desktop and launch it without configuring a Python environment or editing config files,
so that I can start analyzing data without IT support.

Acceptance criteria:
- Given I have downloaded the installer for my OS, when I run it, then the app installs and a launcher icon is created.
- Given the app is installed, when I launch it, then the main interface opens within 30 seconds without any required terminal interaction.
- Given the app cannot find a required dependency (e.g., the underlying MeQTrack tool), when I launch it, then I see a clear, actionable error message rather than a stack trace.

Priority: Must-have
```

```
**US-RES-2: Provide a samplesheet and IDAT files**
As a researcher,
I want to point the app at a CSV samplesheet (with Sentrix_ID and Basename columns) and have it locate the matching Red/Green IDAT pairs,
so that I don't have to upload or rename files manually.

Acceptance criteria:
- Given a valid samplesheet whose Basename paths resolve to existing `_Red.idat` and `_Grn.idat` files, when I select the CSV in the app, then the app shows a confirmation listing each sample with status "OK".
- Given the samplesheet is missing a required column or references a file that does not exist, when I select the CSV, then the app surfaces a per-row error indicating which samples are unusable, before any analysis starts.
- Given an optional metadata column (e.g., diagnosis, batch) is present in the samplesheet, when the analysis runs, then those columns are available for annotation in downstream plots.

Priority: Must-have
```

```
**US-RES-3: Run the standardized pipeline with a single action**
As a researcher,
I want to start the full preprocessing → QC → dimensionality reduction → clustering → CNV pipeline with one button,
so that I get a complete analysis without choosing or sequencing steps myself.

Acceptance criteria:
- Given a validated samplesheet, when I click "Run analysis", then the pipeline executes end-to-end and reports progress per stage.
- Given the pipeline is running, when I look at the app, then I see which stage is in progress and a rough estimate or elapsed time.
- Given a stage fails, when the failure occurs, then the app stops, surfaces the failing stage and error, and does not silently produce partial results.

Priority: Must-have
```

```
**US-RES-4: Inspect QC results before trusting downstream analysis**
As a researcher,
I want to see per-sample QC metrics (detection p-values, signal intensity, outlier flags) clearly presented,
so that I can decide whether the data is good enough to interpret.

Acceptance criteria:
- Given the pipeline has completed, when I open the QC section of the report, then I see a per-sample table of QC metrics with thresholds applied and outliers visibly flagged.
- Given a sample fails QC thresholds, when I view the sample in any downstream plot, then it is visually distinguishable (e.g., marker shape or color) from passing samples.

Priority: Must-have
```

```
**US-RES-5: Explore sample relationships through interactive PCA/UMAP**
As a researcher,
I want to view PCA and UMAP plots of my samples and color/annotate them by metadata fields,
so that I can spot batch effects, clusters, and outliers.

Acceptance criteria:
- Given the pipeline has produced a dimensionality reduction, when I open the PCA/UMAP view, then I see an interactive plot (hover tooltips identifying samples).
- Given metadata columns were provided in the samplesheet, when I select a metadata column, then plot points are recolored by that column.

Priority: Must-have
```

```
**US-RES-6: Review unsupervised clustering with metadata annotations**
As a researcher,
I want to see the clustering result alongside any metadata I provided,
so that I can judge whether clusters correspond to biologically meaningful groups.

Acceptance criteria:
- Given the pipeline has produced clusters, when I open the clustering view, then I see each sample's assigned cluster and a visual summary (e.g., dendrogram or annotated heatmap).
- Given metadata is provided, when I view clustering, then cluster assignments are shown alongside metadata columns to allow visual concordance checks.

Priority: Must-have
```

```
**US-RES-7: Inspect CNV results genome-wide and per-sample**
As a researcher,
I want to view genome-wide CNV plots with segmentation for each sample,
so that I can identify chromosomal gains and losses.

Acceptance criteria:
- Given CNV inference has completed, when I select a sample, then I see a genome-wide CNV plot with segment calls overlaid.
- Given multiple samples have been analyzed, when I navigate the CNV section, then I can move between samples without leaving the report.

Priority: Must-have
```

```
**US-RES-8: Save and share the report**
As a researcher,
I want the final report saved as a self-contained interactive HTML file,
so that I can archive it, share it with collaborators by email, or open it later without the app installed.

Acceptance criteria:
- Given the pipeline has completed, when I open the report file outside the app in any modern browser, then all interactive views (QC table, PCA/UMAP, clustering, CNV plots) work without an internet connection or running server.
- Given I want to keep multiple analyses, when I save a report, then it is written to a location I choose with a filename that identifies the run (date and samplesheet name at minimum).

Priority: Should-have
```

## 4. User journeys

```
**UJ-RES-1: First end-to-end analysis on a fresh install**
Role: Researcher
Trigger: A new batch of IDAT files has finished sequencing and the researcher needs QC, clustering, and CNV results.
Outcome: A saved interactive HTML report covering QC, PCA/UMAP, clustering, and CNV for the batch, viewable independently of the app.

| Phase | User action | System response | Pain points / emotions |
|-------|-------------|-----------------|------------------------|
| 1. Install | Downloads installer, runs it, launches app | App installs and opens to a "Start new analysis" screen | Wary — has been burned by tools that need conda/Python wrangling |
| 2. Provide input | Selects the samplesheet CSV; confirms it lists the right IDAT files | Validates samplesheet, lists each sample with OK/error, blocks continuation if any rows are unusable | Mildly anxious — worried about path mistakes |
| 3. Run | Clicks "Run analysis" | Runs preprocessing, QC, PCA/UMAP, clustering, CNV; shows per-stage progress and elapsed time | Impatient if no progress is visible; relieved when stages tick off |
| 4. Review QC | Opens QC tab in the report | Shows per-sample metrics with thresholds; flags outliers | Critical — needs to trust the data before interpreting downstream |
| 5. Explore results | Switches between PCA/UMAP, clustering, and CNV views; recolors plots by metadata | Updates plots interactively | Curious, exploratory — wants fast iteration without re-running |
| 6. Save & share | Saves the HTML report to a project folder; emails it to a collaborator | Writes a self-contained HTML file with a descriptive filename | Wants confidence the file will open for someone without the app |

Supporting stories: US-RES-1, US-RES-2, US-RES-3, US-RES-4, US-RES-5, US-RES-6, US-RES-7, US-RES-8
```

```
**UJ-RES-2: Diagnosing a failed run and recovering**
Role: Researcher
Trigger: A pipeline stage failed during a run (e.g., a sample's IDAT file is corrupt, or the underlying MeQTrack tool errored on one stage).
Outcome: The researcher understands what failed, fixes the underlying input or environment issue, and successfully re-runs.

| Phase | User action | System response | Pain points / emotions |
|-------|-------------|-----------------|------------------------|
| 1. Notice | Sees the run stop part-way through | Surfaces the failing stage and a human-readable error; does not produce a partial report that could be misread as complete | Frustrated, especially if the error is opaque |
| 2. Diagnose | Reads the error and any sample-level detail | Identifies the offending sample(s) or stage clearly; offers a way to view a log | Wants specifics — not "pipeline failed" but "sample 203467 IDAT pair Red is unreadable" |
| 3. Fix | Edits the samplesheet to drop or correct the bad sample | n/a | Wants to fix once and not re-validate everything by hand |
| 4. Re-run | Re-selects the samplesheet and runs again | Re-validates and re-runs cleanly | Wants the second run to "just work" |

Supporting stories: US-RES-2, US-RES-3
```

## 5. Features

Grouped into three areas: Setup & Input, Analysis Pipeline, and Reporting & Visualization.

### Setup & Input

```
**F-1: Local desktop installation and launch**
Description: Provide an installer (per supported OS) that sets up the app, the underlying MeQTrack tool, and all dependencies so the researcher can launch from a desktop icon without using a terminal.
Supports stories: US-RES-1
Supports journeys: UJ-RES-1
Priority: Must-have
Notes: Depends on packaging strategy for MeQTrack (library vs. bundled binary). See Open Questions Q3.
```

```
**F-2: Samplesheet ingestion and validation**
Description: Read a CSV samplesheet with required columns `Sentrix_ID` and `Basename`, plus optional metadata columns; resolve Basename paths to Red/Green IDAT pairs and report per-row validity before any analysis runs.
Supports stories: US-RES-2
Supports journeys: UJ-RES-1, UJ-RES-2
Priority: Must-have
Notes: Reference input format `samplesheet_epic_10.csv`. Define behavior for relative paths vs absolute (spec says absolute) — see Open Questions Q4.
```

```
**F-3: Optional metadata integration**
Description: Carry any extra samplesheet columns through the pipeline so they can be used as annotations and color/grouping variables in downstream plots.
Supports stories: US-RES-2, US-RES-5, US-RES-6
Supports journeys: UJ-RES-1
Priority: Should-have
Notes: Need to define which column types are allowed (categorical vs continuous) for plot recoloring.
```

### Analysis Pipeline

```
**F-4: Pipeline orchestration with progress reporting**
Description: Run the standardized pipeline (preprocessing → QC → dim reduction → clustering → CNV) end-to-end on a single user action, report per-stage progress, and stop cleanly with actionable errors on failure.
Supports stories: US-RES-3
Supports journeys: UJ-RES-1, UJ-RES-2
Priority: Must-have
Notes: Wraps the existing MeQTrack pipeline rather than reimplementing it.
```

```
**F-5: Preprocessing and normalization**
Description: Standardized preprocessing of raw IDAT pairs (e.g., normalization of Red/Green channels) consistent with the existing MeQTrack pipeline.
Supports stories: US-RES-3
Supports journeys: UJ-RES-1
Priority: Must-have
Notes: Defaults locked for MVP — no user-tunable parameters in v1. See Open Questions Q5.
```

```
**F-6: QC metrics computation**
Description: Compute per-sample QC metrics (detection p-values, signal intensity, outlier detection) and apply thresholds so passing/failing samples are clearly distinguishable downstream.
Supports stories: US-RES-4
Supports journeys: UJ-RES-1
Priority: Must-have
```

```
**F-7: Dimensionality reduction (PCA & UMAP)**
Description: Compute PCA and UMAP embeddings over the methylation matrix.
Supports stories: US-RES-5
Supports journeys: UJ-RES-1
Priority: Must-have
```

```
**F-8: Unsupervised clustering**
Description: Cluster samples without using metadata labels and emit cluster assignments and a structural visualization (e.g., dendrogram or annotated heatmap).
Supports stories: US-RES-6
Supports journeys: UJ-RES-1
Priority: Must-have
Notes: Choice of clustering method (e.g., hierarchical, k-means, leiden) inherited from existing pipeline; not user-selectable in MVP.
```

```
**F-9: CNV inference and segmentation**
Description: Infer copy number variation from methylation intensities and produce per-sample, genome-wide CNV plots with segment calls.
Supports stories: US-RES-7
Supports journeys: UJ-RES-1
Priority: Must-have
```

### Reporting & Visualization

```
**F-10: Interactive, self-contained HTML report**
Description: Bundle all results (QC table, PCA/UMAP, clustering, CNV plots) into a single self-contained interactive HTML file that opens in any modern browser without the app installed and without an internet connection.
Supports stories: US-RES-4, US-RES-5, US-RES-6, US-RES-7, US-RES-8
Supports journeys: UJ-RES-1
Priority: Must-have
Notes: "Self-contained" implies inlined assets (JS/CSS/data) so reports can be archived or emailed.
```

```
**F-11: Report saving and naming**
Description: Save the report to a user-chosen location with a filename that identifies the run (e.g., date + samplesheet name).
Supports stories: US-RES-8
Supports journeys: UJ-RES-1
Priority: Should-have
```

```
**F-12: Failure surfacing and logs**
Description: When a pipeline stage fails, present a human-readable error identifying the failing stage and (where possible) the offending sample(s); provide access to a log file for deeper diagnosis.
Supports stories: US-RES-3
Supports journeys: UJ-RES-2
Priority: Must-have
```

## 6. Traceability matrix

| Story | Features | Journeys |
|-------|----------|----------|
| US-RES-1 Install & launch | F-1 | UJ-RES-1 |
| US-RES-2 Provide samplesheet & IDATs | F-2, F-3 | UJ-RES-1, UJ-RES-2 |
| US-RES-3 Run pipeline with one action | F-4, F-5, F-12 | UJ-RES-1, UJ-RES-2 |
| US-RES-4 Inspect QC | F-6, F-10 | UJ-RES-1 |
| US-RES-5 Explore PCA/UMAP | F-3, F-7, F-10 | UJ-RES-1 |
| US-RES-6 Review clustering | F-3, F-8, F-10 | UJ-RES-1 |
| US-RES-7 Inspect CNV | F-9, F-10 | UJ-RES-1 |
| US-RES-8 Save and share report | F-10, F-11 | UJ-RES-1 |

Every story maps to at least one feature, and every feature is referenced by at least one story.

## 7. Open questions

1. **Are clinicians a user role for this MVP?** The goals document mentions clinicians as beneficiaries but also says the app is "used internally by researchers." If clinicians are intended users (even read-only consumers of reports), several stories around report comprehensibility, glossary, and clinical-grade interpretive language would need to be added.

2. **Single analysis or multiple managed analyses?** The MVP as drafted assumes the researcher runs one analysis at a time and saves the resulting HTML report wherever they want. If the app should manage a library of past analyses (list previous runs, re-open, compare), that's a substantial extra feature area (project/run management) not currently captured.

3. **How is the existing MeQTrack tool at `/Volumes/qtran/MeQTrack` invoked?** Is it imported as a Python library, called as a CLI subprocess, or run via a separate runtime? This drives both packaging (F-1) and how errors propagate to the UI (F-12).

4. **Path resolution rules for the samplesheet `Basename` column.** The spec says "absolute path." Should the app reject relative paths outright, or resolve them relative to the samplesheet's own directory as a usability courtesy?

5. **Are pipeline parameters user-tunable in the MVP?** The current draft assumes a single locked default configuration (true to "standardized pipeline"). If researchers need to adjust, e.g., normalization method or clustering parameters, that adds a settings surface and many parameter-validation stories.

6. **OS coverage.** "Local desktop" is unspecified — macOS only? macOS + Linux? Windows? Each adds installer and packaging work to F-1.

7. **Sample size assumptions.** The example samplesheet is 10 samples. Are there expected upper bounds (100? 1000? more)? This affects whether memory, run time, and progress UX are adequate as scoped.

8. **What does "outlier" mean for QC?** F-6 and US-RES-4 reference outlier flagging, but the threshold logic and definitions should come from the existing pipeline rather than be reinvented — confirm those definitions are documented and stable.
