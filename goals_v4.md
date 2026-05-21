# goals_v4 — v2.0.0 release scope

`goals_v3.md` was the v1.1.0 release scope (additive improvements to the
existing workflow: robustness, past-runs library, tunable parameters,
per-step execution, docs, UI polish). v1.1.0 shipped and has since been
superseded by v1.1.5.

This file targets **v2.0.0** — the next *major* release, reserved for
the reference-projection feature. v2.0.0 is one capability, not a
basket of small improvements. Resist the urge to fold unrelated work
into this scope.

When v2.0.0 ships, bump `MEQTRACK_VERSION` in
`pipeline/methylation_pipeline.R` to `"2.0.0"`.

Work happens on the `v2.0.0-reference-projection` branch; `main` stays
free for v1.1.x patches. Merge `main` into the branch periodically to
absorb those patches.

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

- **Phase 0** — mostly done. Reference assets staged in `reference/` and
  validated (alignment confirmed; COMET identified). Open: the β-matrix
  distribution decision (P0-T3) and the workspace cache layout (P0-T4).
- **Phase 1 — COMPLETE.** `pipeline/pipeline_modules/reference_projection.R`
  written and wired into `methylation_pipeline.R` as
  `--step reference_projection`, with `config$reference_projection$*`
  (enabled / dataset / reference_dir / perplexity) in `config.R`.
  Verified end-to-end both standalone and through the pipeline driver
  (example EPIC run: 4 samples, 100% probe match, ~60 s). Outputs land
  in `<run>/reference_projection/`. The step is self-contained (reads
  IDATs + SWAN itself) and tryCatch-wrapped so a failure doesn't abort
  the run. The basilisk Python env provisions on first use.
  **Next: P1-GATE** (user demo), then Phase 2 (nearest-class diagnostic).

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

Reference projection is the only marquee capability of v2.0.0.
Deferred to v2.1+: UMAP reference projection, additional reference
datasets, alternate projection methods, batch correction.

## Open questions still to resolve

- Probe-set harmonization aggressiveness when the user array is EPICv2
  and the reference is an EPICv1/EPIC overlap set — how many missing
  probes before a projection is untrustworthy and should be refused.
- Confidence visualization in the UI beyond the hint table (e.g.
  shading projected points by k-NN distance).
- Whether the 4685-sample COMET set is added in v2.1 as a second
  selectable reference (its embedding's rownames must first be restored
  from the β-matrix column order).
- `snifter` pulls in a `basilisk`-managed Python env (openTSNE) that
  provisions on first use — needs network and several minutes. Its
  impact on the release install path must be handled in Phase 4 (echoes
  the v1.1.x install-hardening pain).
