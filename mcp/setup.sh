#!/usr/bin/env bash
# Install the MeQTrack MCP server venv (run once from repo root or mcp/).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/mcp"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. Install Python ≥ 3.10 first." >&2
  exit 1
fi

if ! python3 -m venv .venv 2>/dev/null; then
  echo "Could not create venv. On Debian/Ubuntu try: sudo apt install python3-venv" >&2
  exit 1
fi

.venv/bin/pip install -e ".[dev]"
echo ""
echo "Installed: $ROOT/mcp/.venv/bin/meqtrack-mcp"
echo "Next: restart Cursor — the project .cursor/mcp.json will launch this server."
echo "Sanity check: .venv/bin/meqtrack-mcp   (Ctrl-C to stop; waits for MCP client)"
