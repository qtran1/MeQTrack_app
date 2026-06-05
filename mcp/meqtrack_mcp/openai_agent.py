"""Local terminal chat client: a GPT agent that drives the MeQTrack MCP server.

Uses the OpenAI Agents SDK and connects to the MCP server over **stdio**, so the
whole thing runs on your machine — no tunnel, no public URL, no data leaving the
host. This is the GPT equivalent of using Claude Code with the stdio server.

Requirements:
  * `pip install -e ".[openai]"`  (installs openai-agents)
  * `OPENAI_API_KEY` — an OpenAI *API* key from platform.openai.com. NOTE: this
    is billed through the API, **separate from a ChatGPT Plus/Pro subscription**.

Run:  meqtrack-chat        (console script)
  or: python -m meqtrack_mcp.openai_agent
Model: set MEQTRACK_OPENAI_MODEL (default "gpt-4.1").
"""

from __future__ import annotations

import asyncio
import os
import sys

INSTRUCTIONS = """\
You are a lab assistant for MeQTrack, a DNA-methylation QC and analysis pipeline.
Use the provided tools to validate samplesheets, run pipeline steps, check run
status, and summarize results.

Guidelines:
- Before running, validate the samplesheet (validate_samplesheet) and report the
  detected array type and any bad rows.
- Pipeline runs take minutes. After run_pipeline returns a run_id, poll
  get_run_status until the state is completed/failed/cancelled before reading
  results. Tell the user the run_id.
- Read results with get_qc_summary, get_reference_class_hints, get_cnv_summary,
  get_report. Summarize clearly: QC pass/fail counts, nearest reference class per
  sample, and the report path.
- File paths refer to the machine running this server. Don't invent paths.
- Be concise and factual; never fabricate results — only report what the tools return.
"""


def _server_command() -> str:
    """The meqtrack-mcp console script installed alongside this interpreter."""
    candidate = os.path.join(os.path.dirname(sys.executable), "meqtrack-mcp")
    return candidate if os.path.exists(candidate) else "meqtrack-mcp"


async def _amain() -> None:
    if not os.environ.get("OPENAI_API_KEY"):
        print(
            "OPENAI_API_KEY is not set.\n"
            "  Create an API key at https://platform.openai.com/api-keys and export it:\n"
            "    export OPENAI_API_KEY=sk-...\n"
            "  NOTE: the API is billed separately from a ChatGPT Plus/Pro subscription.",
            file=sys.stderr,
        )
        sys.exit(2)

    try:
        from agents import Agent, Runner
        from agents.mcp import MCPServerStdio
    except ImportError:
        print(
            "The OpenAI Agents SDK isn't installed. From the mcp/ dir:\n"
            "    .venv/bin/pip install -e \".[openai]\"",
            file=sys.stderr,
        )
        sys.exit(2)

    model = os.environ.get("MEQTRACK_OPENAI_MODEL", "gpt-4.1")

    async with MCPServerStdio(
        name="meqtrack",
        params={"command": _server_command(), "args": []},
        client_session_timeout_seconds=120,
        cache_tools_list=True,
    ) as server:
        agent = Agent(
            name="MeQTrack assistant",
            instructions=INSTRUCTIONS,
            model=model,
            mcp_servers=[server],
        )
        print(
            f"MeQTrack chat (model={model}). Drives the pipeline locally via MCP.\n"
            "Type a request; 'exit' or Ctrl-D to quit.\n"
        )
        history: list = []
        while True:
            try:
                user = input("you> ").strip()
            except EOFError:
                print()
                break
            if user.lower() in ("exit", "quit"):
                break
            if not user:
                continue
            history.append({"role": "user", "content": user})
            try:
                result = await Runner.run(agent, history, max_turns=24)
            except Exception as exc:  # keep the REPL alive on a model/tool error
                print(f"\n[error] {exc}\n", file=sys.stderr)
                history.pop()
                continue
            print(f"\nmeqtrack> {result.final_output}\n")
            history = result.to_input_list()


def main() -> None:
    try:
        asyncio.run(_amain())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
