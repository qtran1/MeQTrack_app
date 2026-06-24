"""FastMCP server exposing MeQTrack pipeline tools to an MCP client.

Run with:  meqtrack-mcp              (stdio — Claude Desktop/Code)
       or:  meqtrack-mcp --http      (streamable HTTP — ChatGPT desktop connector)
       or:  python -m meqtrack_mcp.server

Transport defaults to stdio. HTTP mode is selected with `--http`/`--sse` or
the MEQTRACK_MCP_TRANSPORT env var; host/port come from MEQTRACK_MCP_HOST /
MEQTRACK_MCP_PORT (default 127.0.0.1:8000, path /mcp).
"""

from __future__ import annotations

import hmac
import os
import sys
from typing import Optional

from mcp.server.fastmcp import FastMCP

from . import config, pipeline, results

mcp = FastMCP(
    "meqtrack",
    host=os.environ.get("MEQTRACK_MCP_HOST", "127.0.0.1"),
    port=int(os.environ.get("MEQTRACK_MCP_PORT", "8000")),
)


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


_HEALTH_BODY = b'{"status":"ok","service":"meqtrack-mcp"}'


async def _send_json(send, status: int, body: bytes, extra_headers=()) -> None:
    await send({
        "type": "http.response.start",
        "status": status,
        "headers": [(b"content-type", b"application/json"), *extra_headers],
    })
    await send({"type": "http.response.body", "body": body})


class _HttpGate:
    """Pure-ASGI gate in front of the MCP HTTP app.

    - ``GET /healthz`` is always unauthenticated and returns 200 (handy for
      tunnel/load-balancer health checks).
    - Every other HTTP request requires ``Authorization: Bearer <token>`` when a
      token is configured; missing/wrong -> 401.

    Pure ASGI (not Starlette BaseHTTPMiddleware) so it does not buffer the
    transport's streaming responses; only HTTP scopes are gated, lifespan
    events pass straight through.
    """

    def __init__(self, app, token: Optional[str]):
        self.app = app
        self._expected = f"Bearer {token}".encode() if token else None

    async def __call__(self, scope, receive, send):
        if scope.get("type") == "http":
            if scope.get("path", "") == "/healthz":
                await _send_json(send, 200, _HEALTH_BODY)
                return
            if self._expected is not None:
                headers = dict(scope.get("headers") or [])
                provided = headers.get(b"authorization", b"")
                if not hmac.compare_digest(provided, self._expected):
                    await _send_json(
                        send, 401, b'{"error":"unauthorized"}',
                        [(b"www-authenticate", b"Bearer")],
                    )
                    return
        await self.app(scope, receive, send)


def _serve_http() -> None:
    """Serve the streamable-HTTP transport behind a bearer-token gate.

    Refuses to start without a token unless MEQTRACK_MCP_ALLOW_NO_AUTH=1, so a
    server can't be tunnelled to the internet wide open by accident.
    """
    import uvicorn

    host, port = mcp.settings.host, mcp.settings.port
    path = mcp.settings.streamable_http_path
    token = os.environ.get("MEQTRACK_MCP_TOKEN")
    allow_no_auth = os.environ.get("MEQTRACK_MCP_ALLOW_NO_AUTH") == "1"

    if not token and not allow_no_auth:
        print(
            "meqtrack-mcp: refusing to start HTTP mode without auth.\n"
            "  Set MEQTRACK_MCP_TOKEN=<secret> — clients must then send\n"
            "  'Authorization: Bearer <secret>'.\n"
            "  Or set MEQTRACK_MCP_ALLOW_NO_AUTH=1 for a trusted localhost-only test.",
            file=sys.stderr,
        )
        sys.exit(2)

    app = _HttpGate(mcp.streamable_http_app(), token)
    auth_note = "bearer token required" if token else "NO AUTH — localhost test only"

    print(
        f"meqtrack-mcp: streamable-http on http://{host}:{port}{path}  [{auth_note}]; "
        f"health: http://{host}:{port}/healthz",
        file=sys.stderr,
    )
    uvicorn.run(app, host=host, port=port, log_level="info")


def main() -> None:
    transport = os.environ.get("MEQTRACK_MCP_TRANSPORT", "stdio").lower()
    if "--http" in sys.argv:
        transport = "streamable-http"
    elif "--sse" in sys.argv:
        transport = "sse"
    if transport in ("http", "streamable-http"):
        _serve_http()
    elif transport == "sse":
        mcp.run(transport="sse")
    else:
        mcp.run()


if __name__ == "__main__":
    main()
