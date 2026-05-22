# goals_v4 — v2.0.0 release scope

`goals_v3.md` was the v1.1.0 release scope (additive improvements to the
existing workflow: robustness, past-runs library, tunable parameters,
per-step execution, docs, UI polish). v1.1.0 shipped and has since been
superseded by v1.1.5.

This file targets **v2.0.0** — the next *major* release, reserved for
the reference-projection feature. v2.0.0 is one capability, not a
basket of small improvements. Resist the urge to fold unrelated work
into this scope.

**Status — SHIPPED.** v2.0.0 was released and tagged
(`MEQTRACK_VERSION = "2.0.0"` in `pipeline/methylation_pipeline.R`),
followed by the v2.0.1 patch. All five phases below (0–4) are complete.
v2.1 work has since continued on `main` — see *Scope discipline*.

---

## Reference projection

**Vision:** incorporate a curated reference methylome dataset —
**COMET**, a pediatric solid-tumor cohort (16 tumour groups) — into the
dimensionality-reduction views. Users upload their own IDATs as usual,
and their samples are *projected onto* the reference t-SNE embedding
instead of being clustered only against each other. A single sample is
then positioned against ~1,900 labelled tumour methylomes, surfacing
the nearest reference class(es) as a diagnostic hint.

The Capper et al. 2018 CNS classifier, named in the original vision, is
**not** in the data the user supplied — only COMET. Capper is a v2.1
candidate, not v2.0.0 scope.

This is a single marquee capability. The goal of v2.0.0 is to ship it
end-to-end (data acquisition → projection math → UI surface), not to
also bundle other improvements.

## Assets in hand — validated 2026-05-20

Two COMET reference cohorts were supplied. v2.0.0 ships the **1915-sample
primary-diagnostic** set; the 4685-sample set is deferred to v2.1.

| Asset | File (in `reference/`) | Status |
|---|---|---|
| 1915 embedding | `tSNE_embedding_1915sample_overlap_probesEPICv1andv2.RData` | committed (2 MB) |
| 1915 β-matrix | `beta_top10K_COMET_…1915samples2.csv` (345 MB) | gitignored — too large |
| 4685 embedding | `tSNE_embedding_4685samples_top10K_overlapProbes.RData` | committed (4.6 MB) |
| 4685 β-matrix | `beta_4685samples_top10K_overlapingProbes.csv` (845 MB) | gitignored — too large |
| metadata | `COMET_Labkey_August_12_2025.csv` (2.6 MB) | committed |

- **1915 set = COMET primary patient tumours only.** Embedding ↔
  β-matrix ↔ metadata all align (verified). The cleaner diagnostic
  reference — v2.0.0 scope.
- **4685 set = the entire COMET cohort** (adds xenografts, cell lines,
  normals, recurrences). Its embedding has **no rownames**; the user
  confirmed its row order matches the β-matrix column order, so it is
  recoverable — deferred to v2.1.
- Each embedding `.RData` holds one `snifter` object: 2-D coords + the
  trained openTSNE model (affinities, perplexity 30, hyperparameters).
- Metadata columns: Sentrix ID = `X850k Tumor File Name`, class label =
  `Tumor Group For Clustering` (16 groups), colour = `Col`.
- The β-matrices are far over GitHub's 100 MB limit (a compressed `.rds`
  of the 1915 set is still ~137 MB) — `reference/beta_*` is gitignored.
  Distribution is a Phase 0 / Phase 4 decision (Git LFS or download).

## Projection engine — how it works

`snifter::project(x, new, old, ...)` projects new samples onto a trained
embedding. It needs three things:

- `x` — the `snifter` embedding object.
- `new` — the user's β-matrix, reshaped to the reference probe set.
- `old` — the **original reference β-matrix** the embedding was trained
  on. Not inside the `.RData`; supplied as a separate file.

**Critical constraint:** `project()` recomputes the affinities of `old`
and checks them against the embedding's stored affinities — so `old`
must be the *complete, unmodified* reference β-matrix. Probe
harmonisation therefore happens on the **query side only**: the query is
reshaped to exactly the reference probe set, imputing any probes it
lacks with the reference per-probe mean. The query must also be
SWAN-normalised, matching how the reference β-matrix was built.

Nearest-class assignment is a k-NN lookup of each projected point
against the labeled reference coordinates (Phase 2).

Only t-SNE embeddings were provided. **UMAP reference projection is out
of scope for v2.0.0** — it would need a separately trained UMAP
reference. Deferred to v2.1.

## Progress

- **Phase 0 — COMPLETE.** Reference assets staged in `reference/` and
  validated (alignment confirmed; COMET identified). Distribution
  decided (P0-T3 / P0-T4): the compact `.rds` β-matrices are gitignored
  and bundled into the release zip by `build_release.sh`; embeddings and
  metadata are committed. Assets ship inside the zip — no separate
  workspace cache.
- **Phase 1 — COMPLETE.** `pipeline/pipeline_modules/reference_projection.R`
  written and wired into `methylation_pipeline.R` as
  `--step reference_projection`, with `config$reference_projection$*`
  (enabled / dataset / reference_dir / perplexity) in `config.R`.
  Verified end-to-end both standalone and through the pipeline driver
  (example EPIC run: 4 samples, 100% probe match, ~60 s). Outputs land
  in `<run>/reference_projection/`. The step is self-contained (reads
  IDATs + SWAN itself) and tryCatch-wrapped so a failure doesn't abort
  the run. The basilisk Python env provisions on first use.

- **Phase 3 — projection view done** (built before Phase 2, by request).
  A "Reference projection" panel in the Dim. reduction tab
  (`dimred_module.R`): a plotly scatter of the reference cloud — coloured
  by tumour group, faded — with the user's samples overlaid as dark
  diamonds, plus a show/hide-reference toggle and a tumour-group filter
  (P3-T1 / T2 / T3). `reference_projection.R` now saves the reference
  cloud metadata (`ref_meta`) to the run folder; `results_loader.R` feeds
  it to the UI. **Not done:** P3-T4 (class-hint table — needs Phase 2)
  and P3-T5 (Settings knobs). Pipeline CLI fix along the way: `--input` /
  `--output` now resolve relative to the invocation directory rather than
  the internal `pipeline/` `setwd()`.

- **Phase 2 — nearest-class diagnostic done.** `nearest_reference_class()`
  in `reference_projection.R` runs a k-NN vote (k = 25, configurable via
  `config$reference_projection$knn_k`) of each projected query sample
  against the labelled reference cloud — emitting the nearest class with a
  confidence, a runner-up, an `ambiguous` flag (no majority / close top
  two), a `distant_from_reference` flag (sample unlike anything in the
  reference), and a `top_classes` summary string. The orchestrator writes
  `reference_projection_class_hints_<dataset>.csv` and carries
  `class_hints` in the saved `rp_result` (P2-T1 / T2 / T3). Not done:
  recording the reference dataset/version in `run_manifest.json` — better
  handled in the bridge (Phase 4).

- **P3-T4 — class-hint table in the UI done.** A per-sample DT table
  under the projection scatter (`dimred_module.R`) lists every query
  sample with coordinates, nearest class, confidence, top classes and
  ambiguous/distant flags — so all samples stay visible even when
  near-identical methylomes (e.g. replicates) overlap to one marker.
  Also done: `reference_projection` is now an independently-runnable
  per-step Run button in the Run tab.

  **EPICv2 harmonisation fixed:** `.normalize_probe_ids()` strips the
  EPICv2 manifest suffix and averages replicate probes — the example
  EPICv2 query went from 0% to 94% reference-probe match. (Also fixed:
  `--output` now resolves to an absolute path even for a new directory.)

- **P3-T5 — Settings knobs done.** The Run-tab Settings card now has a
  Reference projection section — Nearest-class k and Projection
  perplexity — flowing through `run_config.R` like the QC / dim-reduction
  knobs. **Phase 3 is now complete.**

  The class-hint table is now also in the HTML report — a "Reference
  Projection" section with the Class Hints table and the projection
  plot (P3-T4 fully done).

- **Phase 4 — COMPLETE.** `build_release.sh` bundles `reference/` into
  the zip (the compact `.rds` β-matrix + embeddings + metadata; the
  multi-hundred-MB source CSVs excluded), with a preflight check
  mirroring yamapData's. `MEQTRACK_VERSION` is `2.0.0`; the Help tab and
  QUICKSTART document the feature. P4-GATE passed: the
  `v2.0.0-reference-projection` branch was merged to `main` and tagged
  **v2.0.0**. A **v2.0.1** patch followed.

---

## Phased plan

Each phase ends with a demo-and-approval gate, following the
rolling-wave convention in `mvp-plan.md`.

### Phase 0 — Reference data acquisition & staging

**Outcome:** every input the projection needs is located, validated,
and staged in a defined layout.

- P0-T1. Collect from the user and add to the repo: the two reference
  β-matrices (the `old` data) matching the two embeddings, and the
  `Sentrix_ID → tumor_class` metadata table.
- P0-T2. Validate alignment for each reference set — embedding rownames
  ⊆ β-matrix columns ⊆ metadata Sentrix IDs.
- P0-T3. Decide distribution per asset by size: embeddings + metadata
  bundle in the release zip; β-matrices bundle if small, otherwise
  Git LFS or lazy download-on-first-use (mirror the `yamapData`
  tarball pattern in `pipeline/data/`).
- P0-T4. Define the on-disk reference layout — bundled assets vs a
  workspace cache at `~/MeQTrack/reference/<dataset>_<version>/`.
- P0-T5. Document which embedding corresponds to which published cohort
  (COMET / Capper / other) and the exact probe set behind each.
- **P0-GATE.** All reference inputs validated and staged; the
  distribution decision is recorded.

### Phase 1 — Projection pipeline module

**Outcome:** a runnable pipeline step that projects a user run's
β-matrix onto a chosen reference embedding.

- P1-T1. Rewrite the prototype into
  `pipeline_modules/reference_projection.R`, documented and styled like
  `dim_reduction.R`. Delete the prototype file.
- P1-T2. `load_reference(dataset)` — load embedding + β-matrix +
  metadata for a named reference set.
- P1-T3. `harmonize_probes(user_beta, ref_probes)` — intersect the user
  β-matrix (450K / EPIC / EPICv2) down to the reference probe set;
  report how many probes matched.
- P1-T4. `project_onto_reference(embedding, user_beta, ref_beta)` —
  wrap `snifter::project()`; return projected coordinates.
- P1-T5. Wire into `methylation_pipeline.R` as a step
  (`--step reference_projection`) with a dependency guard (needs the
  preprocess β-matrix output). Add `config$reference_projection$*` to
  `config.R` / `default_config()`.
- **P1-GATE.** The example 8-sample run projects onto a reference
  embedding from the CLI; projected coordinates land in the run folder.

### Phase 2 — Nearest-class diagnostic

**Outcome:** each user sample gets a nearest-reference-class hint with
an ambiguity signal.

- P2-T1. k-NN of each projected point against the labeled reference
  coordinates; emit the top-N classes with distances.
- P2-T2. Ambiguity handling — a sample landing between two classes
  surfaces both, not a single forced label.
- P2-T3. Write a per-sample class-hint table into the run outputs;
  record the reference dataset + version in `run_manifest.json`.
- **P2-GATE.** Class hints for the example run reviewed and judged
  sensible.

### Phase 3 — UI surface

**Outcome:** the projection and class hints are visible and
controllable in the app.

- P3-T1. Reference-projection view (extend the t-SNE tab): reference
  points neutral/gray, user samples in the existing teal/brown theme
  tokens, class labels on hover.
- P3-T2. Controls — reference-dataset selector (1915 vs 4685),
  show/hide-reference toggle, class-filter dropdown so 2,800+
  reference points don't drown out the user's samples.
- P3-T3. Hover — class label on reference points, sample name on user
  points.
- P3-T4. Class-hint table surfaced in the UI and the HTML report.
- P3-T5. Settings — expose reference-projection knobs (k for k-NN,
  `project()` perplexity).
- **P3-GATE.** User reviews a full run with projection inside the app.

### Phase 4 — Packaging, caching & release

**Outcome:** v2.0.0 ships.

- P4-T1. Wire reference-asset provisioning into `setup.R` / the
  launchers per the Phase 0 distribution decision; implement the cache
  layout.
- P4-T2. Docs — in-app Help tab + quickstart updates for the feature.
- P4-T3. Bump `MEQTRACK_VERSION` to `2.0.0`; build and smoke-test the
  release zip; merge `v2.0.0-reference-projection` → `main`.
- **P4-GATE.** Fresh-install smoke test passes with projection working.

---

## Scope discipline

Reference projection is the only marquee capability of v2.0.0, shipping
the single 1915-sample COMET reference.

**v2.1 — done since v2.0.0:** the UI **reference-dataset selector**
(skipped in Phase 3 while only one dataset existed) and two additional
reference datasets — the **Capper** CNS-tumour classifier (GSE90496,
2801 samples) and a **sarcoma** classifier (GSE140686, 1077 samples).
Each was registered in the `.REFERENCE_DATASETS` table in
`reference_projection.R`, which needs three artefacts per reference:
1. a trained `snifter` t-SNE embedding (`.RData`);
2. the training β-matrix it was built on (the `old` data for projection);
3. a `Sentrix_ID → tumour-class` metadata table.

Still deferred to v2.1+: the 4685-sample full-COMET set (its embedding's
rownames must first be restored from the β-matrix column order). Also
deferred: UMAP reference projection, alternate projection methods, batch
correction.

## Open questions still to resolve

- Probe-set harmonisation: EPICv2 suffix-stripping is done. Remaining
  judgement call — `harmonize_query()` only *warns* below 80% probe
  match; should a very low match instead hard-refuse the projection?
- Confidence visualization in the UI beyond the hint table (e.g.
  shading projected points by k-NN distance).
- Whether the 4685-sample COMET set is still worth adding as a
  selectable reference (its embedding's rownames must first be restored
  from the β-matrix column order) — v2.1 added Capper and sarcoma but
  not this one.
- `snifter` pulls in a `basilisk`-managed Python env (openTSNE) that
  provisions on first use — needs network and several minutes. Resolved
  for v2.0.0: the env provisions on first run and the Help tab warns the
  first projection is slow (echoes the v1.1.x install-hardening pain).
