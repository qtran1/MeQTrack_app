"""Run lifecycle: spawn the pipeline CLI, track it, report status, cancel.

The server owns the OS subprocess (it does NOT reuse the app's callr-based
``bridge_launch``, which is tied to a live R session). A ``run_manifest.json``
written into the run dir — same schema as ``app/R/pipeline_bridge.R`` — is the
durable record that both this server and the Shiny app can read.
"""

from __future__ import annotations

import json
import re
import subprocess
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from . import config

# Parse the pipeline's "Step N:" log lines (mirrors run_controller.R).
_STEP_LOG_RE = re.compile(r"Step\s+([1-5]):")
_STEP_NUM_TO_STAGE = {
    1: "preprocess",
    2: "qc",
    3: "dim_reduction",
    4: "cnv",
    5: "visualization",
}

# Minimal upstream-artifact prerequisites per step (mirrors STEP_PREREQS in
# run_controller.R). Each group is satisfied if ANY listed file exists.
_STEP_PREREQS = {
    "preprocess": [],
    "qc": [["processed_data/preprocessed_data.RData"]],
    "filtering": [["processed_data/preprocessed_data.RData"]],
    "dim_reduction": [
        [
            "processed_data/preprocessed_data.RData",
            "processed_data/filtered_beta_values.txt",
        ]
    ],
    "reference_projection": [],
    "cnv": [["processed_data/preprocessed_data.RData"]],
    "visualization": [
        [
            "qc/qc_results.RData",
            "dimensionality_reduction/dim_reduction_results.RData",
            "cnv/cnv_results.RData",
        ]
    ],
}


@dataclass
class Run:
    run_id: str
    output_dir: Path
    samplesheet: str
    steps: list
    array_type: str
    threads: int
    state: str = "pending"  # pending|running|completed|failed|cancelled
    current_step: Optional[str] = None
    error: Optional[str] = None
    config_path: Optional[str] = None
    proc: Optional[subprocess.Popen] = field(default=None, repr=False)
    thread: Optional[threading.Thread] = field(default=None, repr=False)
    cancelled: bool = False


_RUNS: dict[str, Run] = {}
_LOCK = threading.Lock()


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def _write_manifest(run: Run, **extra) -> None:
    manifest = {
        "run_id": run.run_id,
        "samplesheet": run.samplesheet,
        "output_dir": str(run.output_dir),
        "data_dir": str(config.DATA_DIR),
        "array_type": run.array_type,
        "threads": run.threads,
        "step": ",".join(run.steps),
        "status": run.state,
        "source": "mcp",
        **extra,
    }
    # Preserve started_at if a manifest already exists.
    mpath = run.output_dir / "run_manifest.json"
    if mpath.exists():
        try:
            prior = json.loads(mpath.read_text())
            manifest.setdefault("started_at", prior.get("started_at"))
        except Exception:
            pass
    manifest.setdefault("started_at", _now_iso())
    mpath.write_text(json.dumps(manifest, indent=2))


def _missing_prereqs(step: str, output_dir: Path) -> list:
    missing = []
    for group in _STEP_PREREQS.get(step, []):
        if not any((output_dir / rel).exists() for rel in group):
            missing.append(group)
    return missing


def start_run(
    samplesheet: str,
    steps: Optional[list] = None,
    array_type: str = "auto",
    threads: int = 4,
    params: Optional[dict] = None,
) -> dict:
    """Launch a pipeline run; returns immediately with the run_id."""
    ss = Path(samplesheet).expanduser()
    if not ss.is_file():
        raise FileNotFoundError(f"Samplesheet not found: {samplesheet}")
    steps = list(steps) if steps else ["all"]
    for s in steps:
        if s != "all" and s not in config.VALID_STEPS:
            raise ValueError(f"Unknown step '{s}'. Valid: all, {', '.join(config.VALID_STEPS)}")
    if array_type not in config.VALID_ARRAY_TYPES:
        raise ValueError(f"Unknown array_type '{array_type}'. Valid: {', '.join(config.VALID_ARRAY_TYPES)}")

    run_id = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}_{ss.stem}"
    output_dir = config.runs_dir() / run_id
    (output_dir / "logs").mkdir(parents=True, exist_ok=True)

    config_path = _write_run_config(output_dir, params) if params else None

    run = Run(
        run_id=run_id,
        output_dir=output_dir,
        samplesheet=str(ss.resolve()),
        steps=steps,
        array_type=array_type,
        threads=int(threads),
        config_path=config_path,
    )
    with _LOCK:
        _RUNS[run_id] = run
    _write_manifest(run, started_at=_now_iso())

    t = threading.Thread(target=_run_steps, args=(run,), daemon=True)
    run.thread = t
    t.start()
    return {"run_id": run_id, "output_dir": str(output_dir), "steps": steps, "state": run.state}


def _write_run_config(output_dir: Path, params: dict) -> Optional[str]:
    """Reuse the app's flat->nested translation via mcp/r/write_run_config.R."""
    params_file = output_dir / ".mcp_params.json"
    params_file.write_text(json.dumps(params))
    res = subprocess.run(
        [config.rscript(), str(config.R_HELPERS / "write_run_config.R"),
         str(output_dir), str(params_file)],
        cwd=config.PROJECT_ROOT, env=config.r_env(),
        capture_output=True, text=True,
    )
    out = (res.stdout or "").strip()
    return out or None


def _run_steps(run: Run) -> None:
    log_path = run.output_dir / "logs" / "pipeline.log"
    for step in run.steps:
        if run.cancelled:
            break
        missing = _missing_prereqs(step, run.output_dir)
        if missing:
            run.state = "failed"
            run.error = (
                f"Cannot run '{step}' — missing upstream output(s): "
                + "; ".join("/".join(g) for g in missing)
                + ". Run earlier steps first (or use 'all')."
            )
            _write_manifest(run, ended_at=_now_iso(), exit_code=1)
            return
        run.current_step = step
        run.state = "running"
        _write_manifest(run)
        cmd = [
            config.rscript(), str(config.PIPELINE_SCRIPT),
            "--input", run.samplesheet,
            "--output", str(run.output_dir),
            "--data_dir", str(config.DATA_DIR),
            "--array_type", run.array_type,
            "--threads", str(run.threads),
            "--step", step,
        ]
        if run.config_path:
            cmd += ["--config", run.config_path]
        with open(log_path, "a") as lf:
            lf.write(f"\n=== [mcp] step={step} {_now_iso()} ===\n")
            lf.flush()
            run.proc = subprocess.Popen(
                cmd, cwd=config.PROJECT_ROOT, env=config.r_env(),
                stdout=lf, stderr=subprocess.STDOUT,
            )
            rc = run.proc.wait()
        if run.cancelled:
            run.state = "cancelled"
            _write_manifest(run, ended_at=_now_iso(), exit_code=rc)
            return
        if rc != 0:
            run.state = "failed"
            run.error = f"Step '{step}' exited with code {rc}. See {log_path}."
            _write_manifest(run, ended_at=_now_iso(), exit_code=rc)
            return
    run.current_step = None
    run.state = "completed"
    _write_manifest(run, ended_at=_now_iso(), exit_code=0)


def _stage_from_log(output_dir: Path) -> Optional[str]:
    log_path = output_dir / "logs" / "pipeline.log"
    if not log_path.exists():
        return None
    last = None
    try:
        for line in log_path.read_text(errors="replace").splitlines():
            m = _STEP_LOG_RE.search(line)
            if m:
                last = _STEP_NUM_TO_STAGE.get(int(m.group(1)))
    except Exception:
        return None
    return last


def status(run_id: str) -> dict:
    run = _RUNS.get(run_id)
    if run is not None:
        return {
            "run_id": run_id,
            "state": run.state,
            "current_step": run.current_step,
            "stage_from_log": _stage_from_log(run.output_dir),
            "error": run.error,
            "output_dir": str(run.output_dir),
        }
    # Not in this process's registry — fall back to the on-disk manifest.
    mpath = config.runs_dir() / run_id / "run_manifest.json"
    if mpath.exists():
        m = json.loads(mpath.read_text())
        return {
            "run_id": run_id,
            "state": m.get("status", "unknown"),
            "current_step": None,
            "stage_from_log": _stage_from_log(config.runs_dir() / run_id),
            "error": None,
            "output_dir": m.get("output_dir"),
        }
    raise KeyError(f"No run found with id '{run_id}'")


def list_runs() -> list:
    out = []
    for mpath in sorted(config.runs_dir().glob("*/run_manifest.json"), reverse=True):
        try:
            m = json.loads(mpath.read_text())
        except Exception:
            continue
        out.append({
            "run_id": m.get("run_id", mpath.parent.name),
            "state": m.get("status", "unknown"),
            "step": m.get("step"),
            "started_at": m.get("started_at"),
            "source": m.get("source", "app"),
        })
    return out


def cancel(run_id: str) -> dict:
    run = _RUNS.get(run_id)
    if run is None:
        raise KeyError(f"No active run with id '{run_id}' in this server.")
    run.cancelled = True
    if run.proc and run.proc.poll() is None:
        run.proc.terminate()
    return {"run_id": run_id, "state": "cancelling"}
