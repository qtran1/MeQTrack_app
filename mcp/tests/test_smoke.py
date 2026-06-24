"""Smoke tests for the MeQTrack MCP server.

Fast tests need only R + the repo. The end-to-end pipeline test is slow
(downloads/preprocessing) and opt-in:  MEQTRACK_RUN_SLOW=1 pytest
"""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from meqtrack_mcp import config, pipeline, results


def test_paths_exist():
    assert config.PIPELINE_SCRIPT.is_file()
    assert config.EXAMPLE_SAMPLESHEET.is_file()
    for helper in ("datasets.R", "validate.R", "write_run_config.R", "summarize.R"):
        assert (config.R_HELPERS / helper).is_file()


def test_list_reference_datasets():
    out = results.list_reference_datasets()
    keys = {d["key"] for d in out.get("datasets", [])}
    assert {"COMET_1915", "Capper_GSE90496", "Sarcoma_GSE140686"} <= keys, out


def test_validate_example_samplesheet():
    out = results.validate_samplesheet(str(config.EXAMPLE_SAMPLESHEET))
    assert out.get("ok") is True, out
    assert out.get("array_type") in ("EPIC", "450k", "EPICv2"), out
    assert out["n_ok"] == out["n_total"], out


@pytest.mark.skipif(
    not os.environ.get("MEQTRACK_RUN_SLOW"),
    reason="slow end-to-end run; set MEQTRACK_RUN_SLOW=1 to enable",
)
def test_run_preprocess_end_to_end():
    r = pipeline.start_run(
        str(config.EXAMPLE_SAMPLESHEET), steps=["preprocess"], array_type="EPIC"
    )
    rid = r["run_id"]
    deadline = time.time() + 1800
    while time.time() < deadline:
        st = pipeline.status(rid)
        if st["state"] in ("completed", "failed", "cancelled"):
            break
        time.sleep(3)
    st = pipeline.status(rid)
    assert st["state"] == "completed", st
    out = Path(st["output_dir"]) / "processed_data" / "preprocessed_data.RData"
    assert out.exists(), f"missing {out}"
