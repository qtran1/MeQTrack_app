"""Read structured run outputs and summarize them for chat.

CSV/HTML outputs are read directly in Python. The one place R is unavoidable
(``.RData`` CNV results) shells out to ``mcp/r/summarize.R``, which reuses the
app's ``load_results_bundle()``.
"""

from __future__ import annotations

import csv
import glob
import json
import subprocess
from pathlib import Path
from typing import Optional

from . import config

_TRUE = {"TRUE", "YES", "1", "T", "PASS"}


def _run_dir(run_id: str) -> Path:
    return config.runs_dir() / run_id


def get_qc_summary(run_id: str) -> dict:
    p = _run_dir(run_id) / "qc" / "sample_qc_report.csv"
    if not p.exists():
        return {"available": False, "message": "No QC report yet — run the 'qc' step."}
    with open(p, newline="") as fh:
        rows = list(csv.DictReader(fh))
    samples = []
    n_pass = 0
    for r in rows:
        passed = str(r.get("Pass_QC", "")).strip().upper() in _TRUE
        n_pass += passed
        samples.append({
            "sample": r.get("Sample_ID"),
            "pass_qc": passed,
            "failure_reason": r.get("Failure_Reason") or None,
            "failed_probes_pct": r.get("Failed_Probes_Percent"),
            "mean_detection_p": r.get("Mean_Detection_P"),
        })
    return {
        "available": True,
        "n_samples": len(rows),
        "n_pass": n_pass,
        "n_fail": len(rows) - n_pass,
        "samples": samples,
    }


def get_reference_class_hints(run_id: str) -> dict:
    pattern = str(_run_dir(run_id) / "reference_projection" / "reference_projection_class_hints_*.csv")
    matches = sorted(glob.glob(pattern))
    if not matches:
        return {"available": False, "message": "No class hints yet — run 'reference_projection'."}
    path = matches[0]
    dataset = Path(path).stem.replace("reference_projection_class_hints_", "")
    with open(path, newline="") as fh:
        rows = list(csv.DictReader(fh))
    return {"available": True, "dataset": dataset, "n_samples": len(rows), "samples": rows}


def get_report(run_id: str) -> dict:
    rdir = _run_dir(run_id) / "reports"
    cands = sorted(rdir.glob("*.html")) if rdir.exists() else []
    if not cands:
        return {"available": False, "message": "No HTML report yet — run 'visualization' (needs pandoc)."}
    preferred = [c for c in cands if "methylation_analysis_report" in c.name]
    path = (preferred or cands)[0]
    return {"available": True, "path": str(path), "uri": path.as_uri()}


def get_cnv_summary(run_id: str) -> dict:
    """Best-effort CNV gain/loss summary via the R summarizer."""
    res = subprocess.run(
        [config.rscript(), str(config.R_HELPERS / "summarize.R"), str(_run_dir(run_id)), "cnv"],
        cwd=config.PROJECT_ROOT, env=config.r_env(),
        capture_output=True, text=True,
    )
    out = (res.stdout or "").strip()
    try:
        return json.loads(out)
    except Exception:
        return {"available": False, "message": "Could not summarize CNV results.",
                "detail": (res.stderr or out)[-500:]}


def list_reference_datasets() -> dict:
    res = subprocess.run(
        [config.rscript(), str(config.R_HELPERS / "datasets.R")],
        cwd=config.PROJECT_ROOT, env=config.r_env(),
        capture_output=True, text=True,
    )
    out = (res.stdout or "").strip()
    try:
        return {"datasets": json.loads(out)}
    except Exception:
        return {"datasets": [], "error": (res.stderr or out)[-500:]}


def validate_samplesheet(path: str) -> dict:
    res = subprocess.run(
        [config.rscript(), str(config.R_HELPERS / "validate.R"), str(Path(path).expanduser())],
        cwd=config.PROJECT_ROOT, env=config.r_env(),
        capture_output=True, text=True,
    )
    out = (res.stdout or "").strip()
    try:
        return json.loads(out)
    except Exception:
        return {"ok": False, "error": (res.stderr or out)[-800:]}
