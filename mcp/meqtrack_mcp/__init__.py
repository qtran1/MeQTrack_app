"""MeQTrack MCP server — chat-driven control of the methylation pipeline.

A thin adapter over the existing `pipeline/methylation_pipeline.R` CLI and its
structured run outputs. The server never reimplements pipeline logic; where R
is unavoidable it shells out to small helpers under ``mcp/r/`` that reuse the
app's own R functions.
"""

__version__ = "0.1.0"
