# goals_v5 — v2.3.0 release scope: sesame bisulfite-conversion QC (GCT)

`goals_v4.md` was the v2.0.0 → v2.1.0 release scope (the reference-projection
marquee capability plus the Capper and sarcoma reference datasets). It shipped
and has since been superseded by v2.2.x (pandoc auto-provisioning, renv
notice suppression, reference-projection docs, COMET dataset relabelling).
Current state: `MEQTRACK_VERSION = "2.2.2"` in
`pipeline/methylation_pipeline.R`.

This file targets **v2.3.0** — the next *minor* release, reserved for one
capability: surfacing the **GCT bisulfite-conversion control score** (sesame)
in the QC outputs. v2.3.0 is one capability, not a basket of small
improvements. Resist the urge to fold unrelated work into this scope.

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

The metric is **informational only** — it does **not** gate `Pass_QC`. This
mirrors how the existing low-intensity note behaves: surfaced for the user's
judgement, never an automatic failure. GCT-based pass/fail gating is explicitly
out of scope (see *Scope discipline*).

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

## Output — its own table

Rather than wedging GCT into the minfi-based `sample_qc_report.csv`, it is
emitted as a standalone **`qc/conversion_qc.csv`** with columns
`Sample_ID, GCT_Score, Array_Type, Note`. Reasons: it is computed on a
different (sesame SigDF) code path than the main QC table; EPICv2 rows are
explicitly `NA` + note, which reads cleanly in a dedicated table; and it is
purely additive — zero risk to the validated Pass/Fail logic. The app surfaces
it as a "Conversion QC" tab next to "Sample metrics".

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

The GCT bisulfite-conversion score is the only marquee capability of v2.3.0.
Phase 1 ships EPIC/450k; Phase 2 extends to EPICv2.

**Explicitly out of scope:**
- GCT-based gating of `Pass_QC` — kept informational, matching the low-intensity
  note. A future release may add an opt-in threshold.
- Removing/repairing the inert `normalization` parameter and its stale
  user-facing strings — a separate cleanup, not this capability.
- Any other sesame QC metric (e.g. `sesameQC_calcStats` intensity/detection
  stats) — the main QC table already covers detection-p and intensity via minfi.

## Open questions still to resolve

- **Threshold:** is there a defensible GCT cutoff (literature or cohort-derived)
  we'd eventually flag on? Phase 1 reports the raw value only; gating is
  deferred until a cutoff is justified.
- **EPICv2 ext probes:** does `sesameData`'s `EPICv2.probeInfo` actually expose
  `typeI.extC` / `typeI.extT`? If not, Phase 2 must derive them from the
  manifest — decide the source before starting P2-T1.
- **Report surfacing (P3-T2):** include the conversion table in the shareable
  HTML report, or keep it app-only? Leaning toward including it for parity with
  the main QC table.
