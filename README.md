# BlindSpot

BlindSpot turns your codebase's call structure into a Jac graph and walks it to find functions with untested lines that are still called by other code. Untested code that nothing calls is skipped. It is exposed as MCP tools for AI coding assistants.

Built for **JacHacks A2Tech**, September 26 to 27, 2026.

---

## Architecture

```
AI client: Claude Code, or any MCP client
   │  MCP over stdio, a private pipe, not the network
   ▼
mcp_server.py   Python, MCP SDK
   │  in-process
   ▼
ingest.py       checks inputs, loads the Jac modules
   ▼
scanner.jac     reads the repo: AST, coverage.json, git log
   ▼
main.sv.jac     the graph and walkers
   │  outgoing HTTPS, only for narration and triage
   ▼
Gemini 2.5 Flash on Vertex AI
```

- **`scanner.jac`** uses Python's `ast` module to find functions and calls, so the scanned code is never run. It reads `coverage.json` for tested lines and `git log` for each file's last editor.
- **`main.sv.jac`** holds the `Function` nodes and `Calls` edges, built by the `BuildGraph` walker. `RiskyUncovered` finds untested code that other code depends on. `NarratedRiskReport` adds a Gemini comment, and `TriageRisks` runs the Gemini triage agent.
- **`ingest.py`** is the thin command line and loader for the two Jac modules.
- **`mcp_server.py`** exposes the scan as three MCP tools.
- **`blindspot_tests.jac`** holds the unit tests. Run them with `jac test blindspot_tests.jac`. Gemini is mocked, so no credentials are needed.

> 🔒 **Network:** BlindSpot opens no ports. Your AI client launches `mcp_server.py` itself and talks to it over stdio, so nothing can connect in. The only outgoing traffic is to Gemini, and only for narration and triage.

---

## Requirements

**Python 3.12 or newer** is required, because Jac uses `typing.override`, which was added in 3.12.

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

That covers the core scan. For Gemini narration and triage, you also need:
- a Google Cloud project with **billing enabled or credits**, and the Vertex AI API turned on
- the [gcloud CLI](https://cloud.google.com/sdk/docs/install). On macOS: `brew install --cask google-cloud-sdk`
- the Vertex AI SDK: `pip install google-cloud-aiplatform`

Setup steps are in [Gemini narration](#gemini-narration-on-vertex-ai) below.

---

## Scan a repo

```bash
# 1. Run the target repo's own tests with coverage, in a venv WITHOUT jaclang.
#    jaclang's import hook conflicts with pytest's assertion rewriter.
cd /path/to/target/repo
pip install coverage pytest   # in the target repo's venv
python -m coverage run -m pytest -q
python -m coverage json -o /tmp/coverage.json

# 2. Scan it from the BlindSpot venv.
python ingest.py /path/to/target/repo /tmp/coverage.json \
  --src-glob "src/**/*.py"   # adjust to the repo's layout
# Add --narrate or --triage for the Gemini features.
```

> ⚠️ The target must be a git repo, and `--src-glob` must stay inside it. It can't contain `..` or be an absolute path.

---

## Use it from an AI assistant over MCP

Add BlindSpot to your MCP client's config, using the Python from the BlindSpot venv:

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

For Claude Code, you can register it for all your projects:
```bash
claude mcp add --scope user blindspot -- \
  /path/to/blindspot/.venv/bin/python /path/to/blindspot/mcp_server.py
```
Then start a new chat so it picks up the tools.

### Tools

| Tool | What it does |
|---|---|
| `find_risky_uncovered_functions(repo_path, coverage_json_path, src_glob)` | Runs the scan |
| `get_narrated_risk_report(repo_path, coverage_json_path, src_glob)` | Adds a Gemini review comment |
| `triage_risky_functions(repo_path, coverage_json_path, src_glob)` | A Gemini agent investigates and ranks the top findings |

Each finding shows `untested_lines` out of `total_lines`, counting only real code lines, and whether the function is `fully_untested`. Fully untested functions rank first, then by how many places call them.

### Verified against real repos

Results were cross-checked against an independent re-implementation of the same rules.

- **pallets/markupsafe**: 53 functions, 20 call edges, 3 findings. `Markup.join` and `Markup.replace` are fully untested. `Markup.escape` has 10 callers and 1 of its 4 lines is untested.
- **pallets/click**: 534 functions, 1021 call edges, 99 findings, scanned in about 2 seconds.

### How calls are matched

Calls are matched by **function name**. `self.save()` links to that class's own `save`. Special methods such as `__init__` and `__repr__` are not matched by name, because a call like `super().__init__()` doesn't say which class's method runs. When a name is defined more than once, as with `@overload` stubs, the last definition wins, which matches Python's own behavior.

> ⚠️ **Known limitation:** other method calls are matched by name only, not by object type. For example, `stream.write(x)` links to every `write` in the repo, which can create false edges. Type-aware resolution is the top improvement to make.

---

## Gemini narration on Vertex AI

`NarratedRiskReport` runs the same walk as `RiskyUncovered`, then sends the findings to Gemini through Jac's `by llm()` for a readable, prioritized review comment instead of raw JSON. This layer is optional: `RiskyUncovered` itself needs no credentials.

- **Cost:** the core scan is free and needs no Google account. Narration and triage need a Google Cloud project with billing enabled or credits. A scan costs a fraction of a cent.
- **Your own credentials:** no API keys are stored in this repo. BlindSpot uses your local Application Default Credentials. Without them, you get a clear "unavailable" message and the findings still come back.
- **Privacy:** narration sends function names, file paths and line counts, never people's names. Triage also sends the source code of the functions it investigates, so keep that in mind for private code.

```bash
# One-time setup
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default set-quota-project YOUR_PROJECT_ID
gcloud services enable aiplatform.googleapis.com
pip install google-cloud-aiplatform

python ingest.py /path/to/target/repo /tmp/coverage.json --narrate
```

`glob llm` in `main.sv.jac` targets `vertex_ai/gemini-2.5-flash`.

---

## Triage agent

`TriageRisks` has a Gemini agent investigate the top 10 findings before judging them, using two read-only tools:
- `read_function_source(name)` returns the function's source code.
- `list_callers(name)` returns the functions that call it, from the Jac graph.

The agent chooses its own tool calls, then returns a priority of high, medium or low and a one-line reason for each function. For example, in our test run on `pallets/click`, trivial `isatty` passthroughs were moved down to low even though many places call them. Priorities and wording can vary between runs, but the findings themselves don't. Functions Gemini skips are sent again, for up to 3 rounds, and any names it makes up are dropped.

> 🛡️ **Safety:** the tools only read data already in memory, namely the flagged functions and their callers. There are no file paths, no writes and no commands. Each round is capped at 25 steps. If Gemini fails, you get a clear "triage unavailable" message and the findings still come back.

> ⚠️ **Only triage code you trust.** Comments in the scanned code could try to steer Gemini's answer. The agent can't act on them, because its tools are read-only, but treat output on untrusted repos with care.

```bash
python ingest.py /path/to/target/repo /tmp/coverage.json --triage
```

---

## Status

- ✅ Graph model with `Function` nodes and `Calls` edges: verified
- ✅ `RiskyUncovered` walker: verified end to end
- ✅ MCP server: verified over stdio, with no open ports
- ✅ Real repo scanning of AST, git log and coverage.json: verified on `markupsafe` and `click`
- ✅ Gemini narration with `gemini-2.5-flash`: verified live, including from Claude Code, with a clean fallback without credentials
- ✅ Triage agent: verified live on `markupsafe` and `click`, including from Claude Code
- ✅ Unit tests with `jac test blindspot_tests.jac`: Gemini mocked, no credentials needed
