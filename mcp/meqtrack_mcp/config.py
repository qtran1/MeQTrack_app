"""Paths, environment, and constants for the MeQTrack MCP server.

All run output lands in the same workspace the Shiny app uses
(``~/MeQTrack/runs`` by default), so a chat-driven run is visible in the
GUI's Past-runs tab and vice versa. Override the workspace with the
``MEQTRACK_WORKSPACE`` env var and the R interpreter with ``MEQTRACK_RSCRIPT``.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

# mcp/meqtrack_mcp/config.py -> repo root is two parents up from the package.
PROJECT_ROOT = Path(__file__).resolve().parents[2]
PIPELINE_SCRIPT = PROJECT_ROOT / "pipeline" / "methylation_pipeline.R"
DATA_DIR = PROJECT_ROOT / "pipeline" / "data"
R_HELPERS = PROJECT_ROOT / "mcp" / "r"
EXAMPLE_SAMPLESHEET = DATA_DIR / "example" / "samplesheet_epic.csv"

# Pipeline contract (mirrors methylation_pipeline.R optparse + run_controller).
VALID_STEPS = [
    "preprocess",
    "qc",
    "filtering",
    "dim_reduction",
    "reference_projection",
    "cnv",
    "visualization",
]
VALID_ARRAY_TYPES = ["auto", "450k", "EPIC", "EPICv2"]


def workspace() -> Path:
    """The MeQTrack workspace dir (shared with the Shiny app)."""
    override = os.environ.get("MEQTRACK_WORKSPACE")
    return Path(override).expanduser() if override else Path.home() / "MeQTrack"


def runs_dir() -> Path:
    d = workspace() / "runs"
    d.mkdir(parents=True, exist_ok=True)
    return d


def rscript() -> str:
    """Resolve the Rscript executable."""
    return os.environ.get("MEQTRACK_RSCRIPT") or shutil.which("Rscript") or "Rscript"


def r_env() -> dict:
    """Environment for child R processes.

    Run with cwd=PROJECT_ROOT so the project ``.Rprofile`` activates the renv
    library; suppress renv's cosmetic out-of-sync notice (matches the launchers).
    """
    env = dict(os.environ)
    env["RENV_CONFIG_SYNCHRONIZED_CHECK"] = "FALSE"
    return env
