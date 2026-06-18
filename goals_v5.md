# goals_v5 — v2.3.0 release scope: sesame sample/experiment QC

`goals_v4.md` was the v2.0.0 → v2.1.0 release scope (the reference-projection
marquee capability plus the Capper and sarcoma reference datasets). It shipped
and has since been superseded by v2.2.x (pandoc auto-provisioning, renv
notice suppression, reference-projection docs, COMET dataset relabelling).
Current state: `MEQTRACK_VERSION = "2.2.2"` in
`pipeline/methylation_pipeline.R`.

This file targets **v2.3.0** — the next *minor* release, reserved for
**sesame-based sample/experiment QC**: the **GCT bisulfite-conversion control
score** (the anchor capability, which gates `Pass_QC`) plus two informational
sample-integrity inferences — **predicted sex** and **Horvath epigenetic age**
— for sample-swap detection. All three come from the sesame beta/SigDF path.
Resist folding unrelated work into this scope.

**Status — Phase 1 IMPLEMENTED, not yet released.** Work is on branch
`preprocess-sesame-migration`. Phase 1 (EPIC/450k support) is code-complete and
unit-verified; Phases 2–3 (EPICv2 coverage, packaging/release) remain.

---

## Bisulfite-conversion QC

**Vision:** report a per-sample **GCT score** (Zhou et al. 2017) so users can
judge how complete bisulfite conversion was on each array. Infinium platforms
are intrinsically robust to *incomplete* conversion — non-converted probes fail
to hybridize — but residual incomplete conversion can be *quantified* from the
Infinium-I C/T-extension probes. A score near **1.0** means complete
conversion; **higher** values indicate more residual incomplete conversion.

This is the specific QC metric **sesame provides that minfi does not**, and the
reason preprocessing reads IDATs through sesame at all. The pipeline already
derived betas and pOOBAH detection-p via `sesame::openSesame()`; this capability
adds `sesame::bisConversionControl()` alongside them.

The metric **gates `Pass_QC`**: a sample whose GCT exceeds
`config$qc$max_gct_score` (default **1.3**) **fails** QC, with a
`Failure_Reason` and a dedicated `Flag_GCT` column, exactly like the
detection-p and failed-probe checks — so it also triggers sample removal when
`filter_failed_samples` is on. Samples with an **NA** GCT (e.g. EPICv2 in
Phase 1, where GCT is not yet computed) are **never** failed on it — an
unmeasured score is not a failing score.

## What this is NOT

This is **not** a normalization-method change. Investigation during planning
confirmed the `normalization` parameter (`raw`/`illumina`/`functional`/
`quantile`/`swan`/`sesame`) was already completely inert end-to-end: the app
never set it, the pipeline hardcoded `prep = "QCDB"` for betas regardless, and
the returned `result$normalization` was never read. Betas already come from
sesame. v2.3.0 leaves the beta and minfi paths untouched and *adds* the GCT
output. (The stale `normalization`-options claims in the README and the inert
parameter itself are candidates for a later cleanup, not v2.3.0 scope.)

## API facts — validated against installed sesame 1.30.0

- `bisConversionControl(sdf, extR = NULL, extA = NULL, verbose = FALSE)` takes a
  sesame **SigDF** and returns one numeric GCT score per sample.
- Internally it reads `InfIR(sdf)` (Infinium-I probes), so the SigDF must have
  its Infinium-I channel inferred first → the minimal prep is **`prep = "C"`**
  (`inferInfiniumIChannel`). Heavier prep (noob/dyebias) would distort the raw
  extension-probe signal and is wrong here.
- For `platform %in% c("EPICplus", "EPIC", "HM450")` it **auto-fetches** the
  extension probes via `sesameDataGet(paste0(platform, ".probeInfo"))`.
- For any other platform (EPICv2, MSA, HM27) it hits
  `stopifnot(!is.null(extR) && !is.null(extA))` and **errors** unless extR/extA
  are supplied manually. This is the EPICv2 gap that splits Phase 1 from
  Phase 2.
- `openSesame(idats, prep = "C", func = bisConversionControl, BPPARAM = ...)`
  returns the per-sample score vector directly — reusing the same IDAT
  discovery and the LSF-safe `bpparam` already built in `preprocess.R`.
- GCT is **not** part of `sesameQC` / `sesameQC_calcStats`; it must be called
  directly.

## Outputs — standalone table + QC gate

GCT surfaces in two places:

1. **Standalone `qc/conversion_qc.csv`** (`Sample_ID, GCT_Score, Array_Type,
   Note`), written by the preprocess step. It is computed on a different
   (sesame SigDF) code path than the main QC table, and EPICv2 rows are
   explicitly `NA` + note, which reads cleanly in a dedicated table. The app
   surfaces it as a "Conversion QC" tab next to "Sample metrics".
2. **`sample_qc_report.csv` gate**: the preprocess GCT table is passed into
   `perform_qc()`, which merges `GCT_Score` and a `Flag_GCT` column into the
   main QC table and folds `Flag_GCT` into `Pass_QC` / `Failure_Reason`. The
   threshold is `config$qc$max_gct_score` (default 1.3, exposed in the Settings
   UI). NA scores never fail.

## Sample-integrity inferences (sex + age + leukocyte fraction)

Three informational columns in `sample_qc_report.csv`, computed in
`perform_qc()` from the beta matrix (so no preprocess threading), for
sample-swap detection and tumour-purity gauging:

- **`Sesame_Sex`** — sesame `inferSex(betas)` → MALE/FEMALE (curated X/Y probe
  model, auto-detects platform). Complements the existing minfi `getSex`
  prediction; a mismatch flags a likely swap.
- **`Horvath_Age`** — Horvath 353-CpG epigenetic age (Horvath 2013) via the
  proper sesame `predictAge(betas, model)`. The model is **vendored** at
  `Anno/HM450/Clock_Horvath353.rds` (from the Zhou Lab InfiniumAnnotation repo)
  in `predictAge()`-compatible form (`intercept`/`param$slope`/`response2age`).
  **Why vendored:** the `age.inference` data shipped in the pinned sesameData
  1.30.0 is the *legacy* coefficient table, incompatible with the installed
  `predictAge()` — so we supply the structured model file instead. The HM450
  clock (base `cg` IDs) is used for all array types, matching our collapsed
  beta matrices. `load_horvath_model()` resolves the path robustly from the
  pipeline working dir.
- **`Leukocyte_Fraction`** — sesame `estimateLeukocyte(betas, platform)` (0–1),
  its reference (`leukocyte.betas`) from sesameData (already cached, no Anno
  file needed). EPIC/450k only; **NA for EPICv2** (no leukocyte reference in
  this sesame version).

All three are **informational only** — none affects `Pass_QC`. **Not available
in sesame 1.30.0:** `inferSexKaryotypes` (XaY-style karyotype) and
`inferEthnicity`; they would require a sesame upgrade (deferred, see *Open
questions*).

### Vendored annotation — `Anno/`

`Anno/` mirrors the upstream `zhou-lab/InfiniumAnnotationV1/Anno` layout and
holds small (~6 KB) sesame annotation assets committed to the repo (they're
tiny, unlike the gitignored 345 MB reference β-matrices). Currently:
`HM450/Clock_Horvath353.rds` (used) and `EPICv2/Clock_Horvath353.EPICv2.345.rds`
(kept for a future EPICv2-native age path — unused now because its suffixed
probe IDs don't match our collapsed betas). `Anno/README.md` records provenance.
`build_release.sh` stages `Anno/` into the release zip.

## Progress

- **Phase 1 — IMPLEMENTED (EPIC/450k), unit-verified, not yet released.**
  - P1-T1. `compute_gct_scores()` helper added to
    `pipeline/pipeline_modules/preprocess.R`: guards on array type (EPIC/450k
    only), calls `openSesame(prep = "C", func = bisConversionControl)`, maps
    scores back to `Sample_ID`, returns the four-column data frame. EPICv2/other
    → `NA` + Phase-2 note. `tryCatch`-wrapped so GCT failure never aborts
    preprocessing. Threaded into `result$gct`. Resolves the concrete array type
    once (the param may be `"auto"`). Also fixed the stale `CDPB`→`QCDB`
    prep-code comment.
  - P1-T2. `methylation_pipeline.R` writes `result$gct` to
    `qc/conversion_qc.csv` in the preprocess step.
  - P1-T3. `app/R/results_loader.R` loads `conversion_qc.csv` into the results
    bundle (`RESULTS_PATHS$conversion_qc` + bundle slot + NULL-guard +
    contract doc).
  - P1-T4. `app/R/qc_module.R` adds the "Conversion QC" nav tab, a generic
    `DT::datatable` render reading `results()$conversion_qc`, and
    `QC_CONVERSION_TOOLTIPS` column help.
  - P1-T5. Docs — `pipeline/README.md` documents the GCT output and corrects
    the misleading "normalization is configurable" claim.
  - P1-T6. QC gating — `qc.R` `perform_qc()` gains `gct` / `max_gct_score`
    params, merges `GCT_Score` + `Flag_GCT` into `sample_qc`, folds `Flag_GCT`
    into `Pass_QC` and `Failure_Reason`, and exposes `gct_failed_samples`.
    `methylation_pipeline.R` threads `result$gct` (from both the fresh-preprocess
    and reload-from-RData branches) and reads `config$qc$max_gct_score`;
    `config.R` defaults it to 1.3. NA GCT never fails; old preprocessed data
    without `$gct` degrades gracefully (gating disabled).
  - P1-T7. Settings UI — `app/R/settings_module.R` adds a "Max GCT" numeric
    input (default 1.3) wired through the param bag, past-run restore, and
    `pipeline_bridge.R` `.write_run_config` (`config$qc$max_gct_score`).
  - P1-T8. Sample-integrity inferences — `qc.R` `compute_sample_inferences()`
    (sesame `inferSex` + Horvath age + leukocyte fraction), called in
    `perform_qc()` to add `Sesame_Sex` / `Horvath_Age` / `Leukocyte_Fraction`
    columns; `qc_module.R` tooltips. Informational, never gates `Pass_QC`.
  - P1-T9. Vendored clock model + proper `predictAge()` — committed
    `Anno/HM450/Clock_Horvath353.rds` (+ EPICv2 variant, unused) from the Zhou
    Lab repo; `load_horvath_model()` reads it and age now uses
    `sesame::predictAge()` (replacing the earlier manual Horvath math, which
    matched: 84.1y). Added leukocyte fraction via `estimateLeukocyte()`
    (EPIC/450k; NA EPICv2). `build_release.sh` bundles `Anno/`. Verified end-to-
    end from the pipeline working dir: model loads, age 84.1y, leukocyte 0.20.
  - **Verified:** on the bundled example IDATs, GCT = 1.481 (HM450) and 1.11
    (EPIC); EPICv2 → `NA` + note, no error. All four edited R files parse.
  - **P1-GATE — PENDING.** Full pipeline run on an EPIC/450k example through the
    app, confirming the "Conversion QC" tab renders with scores and tooltips,
    and a regression check that `sample_qc_report.csv` / `Pass_QC` are unchanged.

- **Phase 2 — EPICv2 coverage (NOT STARTED).**
  - P2-T1. Source the EPICv2 (and ideally MSA) Infinium-I C/T-extension probe
    IDs — from `sesameData` `EPICv2.probeInfo` if it carries `typeI.extC` /
    `typeI.extT`, or derive them from the EPICv2 manifest.
  - P2-T2. Pass `extR`/`extA` through `compute_gct_scores()` for EPICv2 so v2
    samples get real scores instead of `NA`; collapse replicate probes
    consistently with the beta path.
  - P2-T3. Verify on the EPICv2 example IDATs already in
    `pipeline/data/example/` (the `209*` prefixes).
  - **P2-GATE.** EPICv2 run produces finite GCT scores; the Phase-2 note
    disappears for v2.

- **Phase 3 — Packaging & release (NOT STARTED).**
  - P3-T1. In-app Help tab + QUICKSTART: explain the GCT score and the
    near-1.0 interpretation.
  - P3-T2. Optionally surface `conversion_qc.csv` in the HTML report
    (`visualization.R`) alongside the QC table.
  - P3-T3. Bump `MEQTRACK_VERSION` to `2.3.0`; build and smoke-test the release
    zip; merge `preprocess-sesame-migration` → `main`.
  - **P3-GATE.** Fresh-install smoke test passes with the Conversion QC tab
    working.

---

## Scope discipline

The GCT bisulfite-conversion score is the anchor capability of v2.3.0 (it gates
`Pass_QC`); sesame sex + Horvath age ride along as informational
sample-integrity columns. Phase 1 ships EPIC/450k GCT; Phase 2 extends GCT to
EPICv2.

**Explicitly out of scope:**
- **Sex karyotype (`inferSexKaryotypes`) and ethnicity (`inferEthnicity`)** —
  not present in the pinned sesame 1.30.0; they need a sesame/sesameData
  upgrade. Deferred (see *Open questions*). We ship plain `inferSex`
  (MALE/FEMALE) instead.
- Removing/repairing the inert `normalization` parameter and its stale
  user-facing strings — a separate cleanup, not this capability.
- Any other sesame QC metric (e.g. `sesameQC_calcStats` intensity/detection
  stats) — the main QC table already covers detection-p and intensity via minfi.

## Open questions still to resolve

- **Threshold:** the GCT fail cutoff is `config$qc$max_gct_score`, default
  **1.3** (a pragmatic middle ground — ~1.0 is ideal, and the bundled HM450
  example at 1.48 fails while the EPIC example at 1.11 passes). Open: validate
  this default against a real cohort / literature and adjust if warranted.
- **EPICv2 ext probes:** does `sesameData`'s `EPICv2.probeInfo` actually expose
  `typeI.extC` / `typeI.extT`? If not, Phase 2 must derive them from the
  manifest — decide the source before starting P2-T1.
- **Report surfacing (P3-T2):** include the conversion table in the shareable
  HTML report, or keep it app-only? Leaning toward including it for parity with
  the main QC table.
- **sesame upgrade for karyotype/ethnicity:** a newer sesame/sesameData would
  restore `inferSexKaryotypes` (XaY/XaXi), `inferEthnicity`, and a `predictAge`
  compatible with the bundled clock models. Worth it only if those signals are
  wanted — weigh against `renv.lock` churn and pipeline-wide compatibility
  (minfi interop, the basilisk/snifter stack). Not v2.3.0.
