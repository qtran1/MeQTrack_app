# MeQTrack MCP server

Chat-driven control of the MeQTrack methylation pipeline. This is an
[MCP](https://modelcontextprotocol.io) server that exposes MeQTrack's pipeline
as tools an AI assistant (Claude Desktop, Claude Code, …) can call — so you can
*ask* it to validate a samplesheet, run QC/CNV/reference-projection, and read
back the results, instead of clicking through the GUI.

It is a thin adapter over the existing `pipeline/methylation_pipeline.R` CLI and
the run-output files. It does **not** reimplement any pipeline logic, and it
writes runs into the same workspace (`~/MeQTrack/runs`) the Shiny app uses — so
a chat-driven run also shows up in the app's **Past runs** tab.

> See [`DESIGN.md`](DESIGN.md) for the architecture and how it maps onto the
> pipeline contract.

---

## Prerequisites

1. **A working MeQTrack install.** Run the app once (`./meqtrack.command` /
   `meqtrack.bat`, or `Rscript setup.R`) so the renv library, Bioconductor
   packages, yamapData, and the sesame data cache are all provisioned. The MCP
   server reuses that exact R environment.
2. **R on your PATH** (`Rscript`). Same R you use for the app.
3. **Python ≥ 3.10.**

---

## Install

From the repo root:

```bash
cd mcp
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
```

This installs the `meqtrack-mcp` console script into `mcp/.venv/bin/`.

Verify it works against your install:

```bash
.venv/bin/pytest -q          # fast checks (R helpers, samplesheet validation)
```

---

## Start the server

The server speaks MCP over **stdio** — you normally don't run it by hand; your
MCP client launches it. To sanity-check it starts:

```bash
.venv/bin/meqtrack-mcp        # Ctrl-C to stop (it waits for an MCP client)
```

### Connect from Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS)
or `%APPDATA%\Claude\claude_desktop_config.json` (Windows) and add:

```json
{
  "mcpServers": {
    "meqtrack": {
      "command": "/ABSOLUTE/PATH/TO/MeQTrack_app/mcp/.venv/bin/meqtrack-mcp"
    }
  }
}
```

Restart Claude Desktop. "meqtrack" appears in the tools (plug) menu.

### Connect from Claude Code

```bash
claude mcp add meqtrack /ABSOLUTE/PATH/TO/MeQTrack_app/mcp/.venv/bin/meqtrack-mcp
```

(Windows: point `command` at `mcp\.venv\Scripts\meqtrack-mcp.exe`.)

### Connect from Cursor

This repo ships a project-level config at `.cursor/mcp.json`. One-time setup:

```bash
# From the repo root — provisions mcp/.venv and the meqtrack-mcp command
bash mcp/setup.sh
```

Then **restart Cursor** (MCP servers load at startup). In **Settings → Tools & MCP**
you should see **meqtrack** with tools like `validate_samplesheet`, `run_pipeline`,
and `get_qc_summary`.

If the server shows disconnected:

1. Confirm MeQTrack setup has run at least once (`./meqtrack.command` or `Rscript setup.R`)
   so `Rscript` and the renv library work.
2. Run `mcp/.venv/bin/meqtrack-mcp` in a terminal — it should start and wait (no error).
3. On Windows, edit `.cursor/mcp.json` and point `command` at
   `${workspaceFolder}${/}mcp${/}.venv${/}Scripts${/}meqtrack-mcp.exe`.

Optional overrides go in the `env` block of `.cursor/mcp.json`:

```json
"env": {
  "MEQTRACK_WORKSPACE": "${userHome}/MeQTrack",
  "MEQTRACK_RSCRIPT": "/usr/local/bin/Rscript"
}
```

### Connect from ChatGPT desktop (HTTP connector)

Unlike Claude Desktop/Code, **ChatGPT does not launch a local command** — it
adds MCP servers as *connectors that point to a URL*, and the calls are brokered
through OpenAI's cloud. So a `localhost` URL is **not reachable**; the server
must run over HTTP and be exposed publicly behind auth.

> ⚠️ **Security:** this server runs the local pipeline (reads IDATs, spawns
> processes). HTTP mode has a **built-in bearer-token gate** and refuses to
> start without a token, but a token is not a substitute for caution: still
> **don't point a public tunnel at a clinical/PHI workstation**, keep the tunnel
> private, and prefer Claude Desktop/Code (stdio) for day-to-day local use.

1. **Run in HTTP mode with a token** (required — the server won't start in HTTP
   mode without `MEQTRACK_MCP_TOKEN`):
   ```bash
   export MEQTRACK_MCP_TOKEN="$(openssl rand -hex 24)"   # your shared secret
   echo "$MEQTRACK_MCP_TOKEN"                             # note it for step 3
   .venv/bin/meqtrack-mcp --http                          # http://127.0.0.1:8000/mcp
   ```
   Clients must send `Authorization: Bearer <token>`; anything else gets `401`.
   An unauthenticated `GET /healthz` returns `200 {"status":"ok"}` for
   tunnel/load-balancer health checks. (Override host/port with
   `MEQTRACK_MCP_HOST` / `MEQTRACK_MCP_PORT`. For a purely localhost test with
   no auth, set `MEQTRACK_MCP_ALLOW_NO_AUTH=1`.)
2. **Expose it** with a tunnel so ChatGPT's cloud can reach it, e.g.
   `cloudflared tunnel --url http://127.0.0.1:8000` or `ngrok http 8000` →
   gives a public `https://…` URL (keep it private).
3. **Add the connector** in the ChatGPT desktop app: Settings → Connectors
   (developer/advanced mode) → add a custom MCP connector pointing at
   `https://…/mcp`, with the auth header `Authorization: Bearer <token>`.
4. The exact menu, plan requirements, and supported tool shapes change often —
   check OpenAI's current connector/MCP docs.

### Use a GPT model locally (OpenAI Agents SDK) — no connector needed

If ChatGPT's custom connectors aren't available on your account (they're gated to
certain plans / a "developer mode" toggle), you can still chat-drive MeQTrack with
a GPT model — **locally, over stdio, no tunnel**. This is the GPT equivalent of
using Claude Code.

```bash
.venv/bin/pip install -e ".[openai]"        # installs openai-agents
export OPENAI_API_KEY=sk-...                 # see note below
.venv/bin/meqtrack-chat                       # terminal chat; 'exit' to quit
```

> ⚠️ `OPENAI_API_KEY` is an OpenAI **API** key (platform.openai.com) and is billed
> through the API — **separate from a ChatGPT Plus/Pro subscription**, which does
> not include API usage.

The agent launches the MCP server itself (stdio), discovers the tools, and runs
everything on your machine. Pick the model with `MEQTRACK_OPENAI_MODEL` (default
`gpt-4.1`). Example: *"Validate `pipeline/data/example/samplesheet_epic.csv`,
then run preprocess and tell me the QC summary."*

---

## Configuration (env vars)

| Var | Default | Purpose |
|-----|---------|---------|
| `MEQTRACK_WORKSPACE` | `~/MeQTrack` | Where runs are written (shared with the app). |
| `MEQTRACK_RSCRIPT` | first `Rscript` on PATH | R interpreter to use. |
| `MEQTRACK_MCP_TRANSPORT` | `stdio` | `stdio` \| `streamable-http` \| `sse` (or pass `--http`). |
| `MEQTRACK_MCP_HOST` / `MEQTRACK_MCP_PORT` | `127.0.0.1` / `8000` | Bind address for HTTP mode. |
| `MEQTRACK_MCP_TOKEN` | _(unset)_ | Bearer token required in HTTP mode; clients send `Authorization: Bearer <token>`. |
| `MEQTRACK_MCP_ALLOW_NO_AUTH` | _(unset)_ | Set `1` to allow HTTP mode without a token (localhost-only testing). |
| `OPENAI_API_KEY` | _(unset)_ | Required by `meqtrack-chat` (the local GPT client). API-billed, not the ChatGPT subscription. |
| `MEQTRACK_OPENAI_MODEL` | `gpt-4.1` | Model used by `meqtrack-chat`. |

Set these in the client's server config `env` block if you need to override them.

---

## Tools

| Tool | What it does |
|------|--------------|
| `list_reference_datasets` | List reference datasets for projection (COMET / Capper / sarcoma). |
| `validate_samplesheet(path)` | Validate columns + IDATs, auto-detect array type. |
| `run_pipeline(samplesheet, steps, array_type, threads, params)` | Launch a run; returns a `run_id` immediately. |
| `get_run_status(run_id)` | State + current step + stage parsed from the log. |
| `list_runs()` | All runs in the workspace (newest first). |
| `cancel_run(run_id)` | Cancel an in-progress run. |
| `get_qc_summary(run_id)` | Per-sample QC pass/fail + reasons. |
| `get_reference_class_hints(run_id)` | Nearest reference tumour class per sample. |
| `get_cnv_summary(run_id)` | Per-sample CNV gain/loss counts. |
| `get_report(run_id)` | Path / `file://` URI of the HTML report. |

### `steps`

`preprocess, qc, filtering, dim_reduction, reference_projection, cnv,
visualization`, or `["all"]` (default). A list runs sequentially in one run
dir, with upstream prerequisites enforced.

### `params` (tuning overrides — flat keys)

```jsonc
{
  "qc.detection_p_threshold": 0.01,
  "qc.failed_probe_percent_threshold": 25,
  "dim.variable_probes": 10000,
  "dim.tsne_perplexity": 5,
  "dim.umap_n_neighbors": 15,
  "cnv.gain_threshold": 0.18,
  "cnv.loss_threshold": -0.20,
  "refproj.dataset": "Capper_GSE90496",
  "refproj.knn_k": 25,
  "refproj.perplexity": 5
}
```

---

## Example chat session

> **You:** Validate `~/data/run12/samplesheet.csv`.
> **Assistant:** *(calls `validate_samplesheet`)* All 8 samples OK; array
> detected as EPICv2.
>
> **You:** Run the full pipeline on it, projecting onto the Capper reference.
> **Assistant:** *(calls `run_pipeline(..., params={"refproj.dataset":"Capper_GSE90496"})`)*
> Started run `20260603-101500_samplesheet` — I'll check on it.
> *(polls `get_run_status`)* … done.
>
> **You:** Any QC failures? What's the nearest class for each sample?
> **Assistant:** *(calls `get_qc_summary` + `get_reference_class_hints`)* …
> *(calls `get_report` for the HTML link)*

---

## Troubleshooting

- **"No run found" / tools error on R:** make sure `Rscript` is on PATH and the
  app's setup has been run (the server uses the project's renv library).
- **HTML report missing:** the `visualization` step needs pandoc; a fresh
  `setup.R` provisions one automatically (MeQTrack ≥ v2.2.2).
- **Slow first run:** the pipeline provisions a basilisk Python env for
  reference projection and caches sesame data on first use.
- **End-to-end test:** `MEQTRACK_RUN_SLOW=1 .venv/bin/pytest -q` runs an actual
  preprocess on the bundled example (minutes).
