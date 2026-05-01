# goals_v4 — v2.0.0 release scope

`goals_v3.md` is the v1.1.0 release scope (additive improvements to the
existing workflow: robustness, past-runs library, tunable parameters,
per-step execution, docs, UI polish). When v1.1.0 ships, bump
`MEQTRACK_VERSION` in `pipeline/methylation_pipeline.R` to `"1.1.0"`.

This file targets **v2.0.0** — the next *major* release, reserved for
the reference-projection feature. v2.0.0 is one capability, not a
basket of small improvements. Resist the urge to fold unrelated work
into this scope.

When v2.0.0 ships, bump `MEQTRACK_VERSION` to `"2.0.0"`.

---

## Reference projection

**Vision:** incorporate curated public reference methylome datasets —
**COMET** and **Capper et al. 2018** (central nervous system tumor
classifier, ~91 tumor classes) — into the dimensionality reduction
views. Users upload their own IDATs as usual, and their samples are
*projected onto* the reference t-SNE / UMAP embeddings instead of being
clustered only against each other. A single sample is then positioned
against thousands of labeled tumor methylomes, surfacing the nearest
reference class(es) as a diagnostic hint.

This is a single marquee capability. The goal of v2.0.0 is to ship it
end-to-end (data acquisition → projection math → UI surface), not to
also bundle other improvements.

## Key implementation questions to resolve before committing to scope

- **Data distribution.** Both reference sets are too large to bundle in
  the release zip (Capper alone is ~2.8k samples worth of β-values).
  Likely paths: Bioconductor ExperimentHub (idiomatic, integrates with
  the existing Bioc dependency tree) or GitHub Releases + lazy
  download-on-first-use (faster to ship, less infrastructure).
  This decision affects the install path — pick early.
- **Projection math.** UMAP has a native `transform()` for projecting
  new points onto a trained embedding. t-SNE is non-parametric by
  default; options are openTSNE (parametric t-SNE) or a
  k-NN-in-embedding approximation. The trade-off is between an exact
  re-fit and a faster but approximate placement.
- **UI.** Reference points should be visually distinct from user
  samples (gray / neutral) with class labels on hover; user samples
  keep the teal/brown theme tokens already in use. Probably a toggle
  for "show / hide reference" and a class-filter dropdown so the
  embedding doesn't get drowned out by 2,800 reference points when the
  user only cares about, say, glioblastoma neighbors.
- **Scope discipline.** Reference projection is the only marquee
  capability of v2.0.0. Sub-features (additional reference datasets,
  alternate projection methods, batch correction) are v2.1+ candidates.

## Open questions / things to think about before scoping starts

- Probe-set alignment between user samples (any of 450K / EPIC / EPICv2)
  and reference (likely 450K + EPIC). Need an intersection step before
  projection; how aggressive should the harmonization be?
- Confidence / uncertainty visualization. A user sample landing exactly
  on the boundary between two reference classes should surface that
  ambiguity, not just emit the single nearest label.
- Caching. Re-downloading and re-fitting reference embeddings on every
  launch is unacceptable; need a cache layout in the workspace
  (probably `~/MeQTrack/reference/<dataset>_<version>/`).
