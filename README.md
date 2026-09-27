# 🕳️ BlindSpot

BlindSpot turns your codebase's call structure into a Jac graph and walks it to find functions with untested lines that are still called by other code. That's real risk not dead code. Exposed as MCP tools for AI coding assistants.

Built for **JacHacks A2Tech**, Sep 26–27, 2026.

---

## 🏗️ Architecture

```
AI client (Claude Code, any MCP client)
   │  MCP over stdio  a private pipe, not the network
   ▼
mcp_server.py   Python, MCP SDK
   │  in-process
   ▼
ingest.py       validates inputs, loads Jac modules
   ▼
scanner.jac     reads the repo (AST, coverage.json, git log)
   ▼
main.sv.jac     the graph + walkers
   │  outgoing HTTPS only for narration/triage
   ▼
Gemini 2.5 Flash on Vertex AI
```

- **`scanner.jac`** — uses Python's `ast` to find functions/calls (never runs the code). Reads `coverage.json` for tested lines, `git log` for last editor.
- **`main.sv.jac`** — `Function` nodes + `Calls` edges, built by `BuildGraph`. `RiskyUncovered` finds untested-but-depended-on code. `NarratedRiskReport` adds a Gemini comment. `TriageRisks` runs the Gemini triage agent.
- **`ingest.py`** — thin CLI/loader for the two Jac modules.
- **`mcp_server.py`** — exposes the scan as 3 MCP tools.
- **`blindspot_tests.jac`** — unit tests (`jac test blindspot_tests.jac`), Gemini mocked, no credentials needed.

> 🔒 **No network server, no open port.** Your AI client launches `mcp_server.py` itself over stdio — nothing can connect in. Only outgoing traffic is to Gemini, and only for narration/triage.

---

## ⚙️ Requirements

**Python 3.12+** required (Jac uses `typing.override`, added in 3.12).

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

That covers the core scan. For Gemini narration/triage, you'll also need:
- 🔑 a Google Cloud project (billing/credits) with Vertex AI enabled
- 🛠️ the [gcloud CLI](https://cloud.google.com/sdk/docs/install) (`brew install --cask google-cloud-sdk` on macOS)
- 📦 `pip install google-cloud-aiplatform`

Setup details in [Gemini narration](#-gemini-narration-on-vertex-ai) below.

---

## 🔍 Scan a repo

```bash
# 1. Run the target repo's own tests with coverage (venv WITHOUT jaclang —
#    jaclang's import hook conflicts with pytest's assertion rewriter)
cd /path/to/target/repo
pip install coverage pytest
python -m coverage run -m pytest -q
python -m coverage json -o /tmp/coverage.json

# 2. Scan it from the BlindSpot venv
python ingest.py /path/to/target/repo /tmp/coverage.json \
  --src-glob "src/**/*.py"   # adjust to repo layout
# add --narrate or --triage for Gemini features
```

> ⚠️ Target must be a git repo; `--src-glob` must stay inside it (no `..`, no absolute paths).

---

## 🤖 Use it from an AI assistant (MCP)

```json
{
  "mcpServers": {
    "blindspot": {
      "command": "/path/to/blindspot/.venv/bin/python",
      "args": ["/path/to/blindspot/mcp_server.py"]
    }
  }
}
```

Claude Code shortcut:
```bash
claude mcp add --scope user blindspot -- \
  /path/to/blindspot/.venv/bin/python /path/to/blindspot/mcp_server.py
```
Then start a new chat to pick up the tools.

### 🧰 Tools

| Tool | Does |
|---|---|
| `find_risky_uncovered_functions(repo_path, coverage_json_path, src_glob)` | Runs the scan |
| `get_narrated_risk_report(...)` | Adds a Gemini review comment |
| `triage_risky_functions(...)` | Gemini agent investigates + ranks top findings |

Each finding shows `untested_lines`/`total_lines` (real code lines only) and `fully_untested`. Fully-untested functions rank first, then by call count.

### ✅ Verified against real repos

- **pallets/markupsafe**: 53 functions, 20 edges, 3 findings. `Markup.join`/`Markup.replace` fully untested; `Markup.escape` (10 callers) has 1/4 lines uncovered.
- **pallets/click**: 534 functions, 1021 edges, 99 findings — scanned in ~2s.

### 🔗 How calls are matched

By **function name**. `self.save()` links to that class's own `save`. Special methods (`__init__`, `__repr__`) aren't matched — `super().__init__()` doesn't say which class runs. Duplicate defs (e.g. `@overload`) → last definition wins (matches Python's own behavior).

> ⚠️ **Known limitation:** method calls match by name only, not object type — `stream.write(x)` links to *every* `write` in the repo, risking false edges. Type-aware resolution is the top improvement candidate.

---

## 🗣️ Gemini narration on Vertex AI

`NarratedRiskReport` runs the same walk as `RiskyUncovered`, then sends findings to Gemini (via Jac's `by llm()`) for a readable, prioritized review comment instead of raw JSON. Optional layer — `RiskyUncovered` itself needs zero credentials.

- 💸 **Cost:** core scan is free, no Google account needed. Narration/triage need Vertex AI billing — a scan costs a fraction of a cent.
- 🔐 **Your own creds:** no API key in this repo, ever. Uses your local Application Default Credentials. No setup → clean "unavailable" message, findings still returned.
- 🕵️ **Privacy:** narration sends function names, paths, line counts (never people's names). Triage also sends source code of investigated functions — mind this on private code.

```bash
# one-time setup
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default set-quota-project YOUR_PROJECT_ID
gcloud services enable aiplatform.googleapis.com
pip install google-cloud-aiplatform

python ingest.py /path/to/target/repo /tmp/coverage.json --narrate
```

`glob llm` in `main.sv.jac` targets `vertex_ai/gemini-2.5-flash`.

---

## 🕵️ Triage agent

`TriageRisks` has a Gemini agent investigate the top 10 findings before judging, using two read-only tools:
- `read_function_source(name)`
- `list_callers(name)`

The agent picks its own tool calls, then returns `high`/`medium`/`low` priority + a one-line reason per function. E.g. on `pallets/click`, trivial `isatty` passthroughs got bumped to `low` despite many callers. Priorities/wording vary by run; findings themselves don't. Skipped functions get re-sent for up to 3 rounds; hallucinated names are dropped.

> 🛡️ **Safety:** tools only read data already in memory (flagged functions + callers) — no file paths, no writes, no commands. Capped at 25 steps/round. Failure → clean "triage unavailable" message, findings still returned.

> ⚠️ **Only triage code you trust.** Comments in scanned code could try to steer Gemini's answer. The agent can't *act* on it (read-only tools), but treat output on untrusted repos with care.

```bash
python ingest.py /path/to/target/repo /tmp/coverage.json --triage
```

---

## 📊 Status

- ✅ Graph model (`Function` nodes, `Calls` edges) — verified
- ✅ `RiskyUncovered` walker — verified end to end
- ✅ MCP server — verified over stdio, no open ports
- ✅ Real repo scanning (AST + git log + coverage.json) — verified on `markupsafe` & `click`
- ✅ Gemini narration (`gemini-2.5-flash`) — verified live incl. Claude Code, clean fallback w/o creds
- ✅ Triage agent — verified live on `markupsafe` & `click`, incl. Claude Code
- ✅ Unit tests (`jac test blindspot_tests.jac`) — Gemini mocked, no creds needed