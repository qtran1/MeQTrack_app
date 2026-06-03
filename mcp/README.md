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

---

## Configuration (env vars)

| Var | Default | Purpose |
|-----|---------|---------|
| `MEQTRACK_WORKSPACE` | `~/MeQTrack` | Where runs are written (shared with the app). |
| `MEQTRACK_RSCRIPT` | first `Rscript` on PATH | R interpreter to use. |

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
