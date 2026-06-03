"""FastMCP server exposing MeQTrack pipeline tools to an MCP client.

Run with:  meqtrack-mcp        (console script)
       or:  python -m meqtrack_mcp.server
Transport: stdio (the default an MCP client like Claude Desktop/Code expects).
"""

from __future__ import annotations

from typing import Optional

from mcp.server.fastmcp import FastMCP

from . import config, pipeline, results

mcp = FastMCP("meqtrack")


@mcp.tool()
def list_reference_datasets() -> dict:
    """List the reference methylome datasets available for projection
    (key, label, class column). Use a key as `params.refproj.dataset`."""
    return results.list_reference_datasets()


@mcp.tool()
def validate_samplesheet(path: str) -> dict:
    """Validate a samplesheet CSV before running. Checks required columns
    (Sentrix_ID, Sample_Name, Basename), that each sample's _Red/_Grn IDATs
    exist and are well-formed, and auto-detects the array type.
    Returns per-row status plus the detected array type."""
    return results.validate_samplesheet(path)


@mcp.tool()
def run_pipeline(
    samplesheet: str,
    steps: Optional[list[str]] = None,
    array_type: str = "auto",
    threads: int = 4,
    params: Optional[dict] = None,
) -> dict:
    """Launch a pipeline run and return immediately with a run_id.

    steps: ordered list from {preprocess, qc, filtering, dim_reduction,
        reference_projection, cnv, visualization} or ["all"] (default).
        Steps run sequentially against one run dir; upstream prerequisites
        are enforced.
    array_type: auto | 450k | EPIC | EPICv2.
    params: optional tuning overrides, flat keys e.g.
        {"qc.detection_p_threshold": 0.01, "dim.tsne_perplexity": 5,
         "refproj.dataset": "Capper_GSE90496", "refproj.knn_k": 25}.

    Poll get_run_status(run_id) for progress (runs take minutes)."""
    return pipeline.start_run(samplesheet, steps, array_type, threads, params)


@mcp.tool()
def get_run_status(run_id: str) -> dict:
    """Get a run's state (pending/running/completed/failed/cancelled),
    the current step, and the latest stage parsed from the log."""
    return pipeline.status(run_id)


@mcp.tool()
def list_runs() -> dict:
    """List all runs in the workspace (newest first) with their state."""
    return {"runs": pipeline.list_runs()}


@mcp.tool()
def cancel_run(run_id: str) -> dict:
    """Cancel an in-progress run started by this server."""
    return pipeline.cancel(run_id)


@mcp.tool()
def get_qc_summary(run_id: str) -> dict:
    """Per-sample QC results: pass/fail counts and reasons."""
    return results.get_qc_summary(run_id)


@mcp.tool()
def get_reference_class_hints(run_id: str) -> dict:
    """Nearest reference tumour class per sample (with confidence and the
    ambiguous / distant-from-reference flags) from reference projection."""
    return results.get_reference_class_hints(run_id)


@mcp.tool()
def get_cnv_summary(run_id: str) -> dict:
    """Best-effort per-sample CNV gain/loss summary."""
    return results.get_cnv_summary(run_id)


@mcp.tool()
def get_report(run_id: str) -> dict:
    """Locate the run's HTML report; returns its file path and file:// URI."""
    return results.get_report(run_id)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
