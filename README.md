# BlindSpot

A Jac-native graph of your codebase's call structure, walked to find
functions with **untested lines that are still called by other code**
(real risk, not dead code) — exposed as an MCP tool any AI coding assistant can call.

Built for JacHacks A2Tech (Sept 26-27, 2026).

## Architecture

```
   AI client (Claude Code, or any MCP client)
              |  MCP over stdio (a private pipe, not the network)
              v
     mcp_server.py  (Python, MCP SDK)
              |  in-process
              v
     ingest.py  (Python: checks inputs, loads the Jac modules)
              |
              v
     scanner.jac  (Jac: reads the repo)  -->  main.sv.jac  (Jac: graph + walkers)
```

- **`scanner.jac`** — reads a repo: Python `ast` for functions and calls
  (the scanned code is never run), `coverage.json` for which lines tests
  ran, `git log` for each file's last editor.
- **`main.sv.jac`** — the graph. `Function` nodes and `Calls` edges, built
  in one pass by the `BuildGraph` walker; the `RiskyUncovered` walker
  finds untested code that other code actually depends on,
  `NarratedRiskReport` adds a Gemini review comment, and `TriageRisks`
  runs the Gemini triage agent (see below).
- **`ingest.py`** — the thin Python loader and CLI around the two Jac
  modules.
- **`mcp_server.py`** — a thin MCP server that exposes the scan as tools.
- **`blindspot_tests.jac`** — unit tests (`jac test blindspot_tests.jac`);
  Gemini is replaced by `MockLLM`, so no credentials are needed.

**No network server, no open port.** Your AI client launches
`mcp_server.py` itself and talks to it over stdio; the Jac graph runs
inside that same process. Nothing on your network can connect to it.

## Requirements

**Python 3.12+ is required** (Jac uses `typing.override`, added in 3.12).
Check with `python3 --version` before installing; use a 3.12+ venv if your
system Python is older.

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Scan a repo

```bash
# 1. run the target repo's own tests with coverage, in a venv WITHOUT jaclang
#    (jaclang's import hook conflicts with pytest's assertion rewriter)
cd /path/to/target/repo
python -m coverage run -m pytest -q
python -m coverage json -o /tmp/coverage.json

# 2. scan it (from the BlindSpot venv)
python ingest.py /path/to/target/repo /tmp/coverage.json \
  --src-glob "src/**/*.py"   # adjust glob to the repo's layout
```

## Use it from an AI assistant (MCP)

Add BlindSpot to your MCP client's config, using the Python from the
BlindSpot venv:

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

Tools:
- `find_risky_uncovered_functions(repo_path, coverage_json_path, src_glob)`
- `get_narrated_risk_report(repo_path, coverage_json_path, src_glob)` — adds a Gemini review comment (see below)
- `triage_risky_functions(repo_path, coverage_json_path, src_glob)` — a Gemini agent investigates the top findings and ranks them (see below)

Each finding reports how much of the function is untested
(`untested_lines` of `total_lines`, counting only real code lines in the
body) and whether it is `fully_untested`. Fully untested functions are
listed first, then the ones the most other code calls.

Verified end-to-end against real repos, and cross-checked against an
independent re-implementation of the same rules:

- **pallets/markupsafe** (real git history + a real pytest/coverage run):
  53 functions, 20 call edges, 3 findings: `Markup.join` and
  `Markup.replace` have no test coverage at all, and `Markup.escape` is
  called from 10 places but 1 of its 4 code lines never runs under the
  tests. Fully covered code and dead code are excluded.
- **pallets/click** (a larger repo): 534 functions, 1021 call edges,
  99 findings, scanned in about 2 seconds.

**How calls are matched:** by function name. `self.save()` inside a class
links to that class's own `save` method. Calls to special methods like
`__init__` or `__repr__` are not matched by name, since a call such as
`super().__init__()` doesn't say which class's method runs. When a name is
defined more than once (e.g. `@overload` stubs), the last definition — the
one Python actually uses — is the one analysed.

**Known limitation:** other method calls are matched by name only, without
knowing the object's type — e.g. `stream.write(x)` links to every `write`
method in the repo. Common method names can therefore produce false
edges. Proper type-aware resolution would be the first thing to harden.

## Gemini narration (Vertex AI, for Best of Google)

`NarratedRiskReport` is the same graph walk as `RiskyUncovered`, but its
exit ability sends the findings to Gemini via Jac's `by llm()` and returns
a prioritized, human-readable code-review comment instead of bare JSON.
`RiskyUncovered` itself needs no credentials at all — this layer is opt-in
on top of it.

**Cost:** the core scan (`find_risky_uncovered_functions`, and `ingest.py`
without flags) is free and needs no Google account. Narration and triage
call Gemini on Vertex AI, which needs a Google Cloud project with **billing
enabled or credits** attached. A scan costs a fraction of a cent.

**Bring your own credentials.** No API key lives in this repo, ever.
Narration uses the Google Cloud login of whoever runs BlindSpot, on their
own machine, via Application Default Credentials — nothing is read from
source, committed, or shared. If that login isn't set up, you get a clear
"narration unavailable" message instead of a crash.

Note: narration sends function names, file paths and line counts from
the scanned repo to Google's Gemini API (never people's names). Triage
(below) also sends the **source code** of the functions it investigates.
Keep that in mind before scanning private code.

```bash
# one-time: your own Google account + a GCP project with Vertex AI enabled
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default set-quota-project YOUR_PROJECT_ID
gcloud services enable aiplatform.googleapis.com
pip install google-cloud-aiplatform   # Vertex AI SDK, needed only for narration / triage

python ingest.py /path/to/target/repo /tmp/coverage.json --narrate
```

`glob llm` in `main.sv.jac` targets `vertex_ai/gemini-2.5-flash`.

## Triage agent (Gemini with tools)

`TriageRisks` goes a step further than narration: a Gemini agent
**investigates** the 10 most urgent findings before judging them. Through
Jac's `by llm(tools=[...])` it can call two read-only tools:

- `read_function_source(name)` — the function's source code
- `list_callers(name)` — which functions call it (from the Jac graph)

It decides for itself which tools to call, then returns a priority
(high / medium / low) and a one-line reason per function, grounded in what
the code actually does. For example, in our test run on pallets/click it
moved trivial `isatty` passthroughs down to low even though many places
call them. (Gemini's priorities and wording can vary between runs; the
findings themselves don't.)
If Gemini skips a function, BlindSpot sends just the missing ones back
(up to 3 rounds), and it drops any function name Gemini made up.

**Safety:** the tools only read from data BlindSpot already holds in
memory — the flagged functions and their callers. The agent never passes
a file path, so it can't read anything else, and it can't write files or
run commands. Each round is capped at 25 agent steps. If Gemini
fails, you get a clear "triage unavailable" message and the findings still
come back.

```bash
python ingest.py /path/to/target/repo /tmp/coverage.json --triage
```

## Status

- [x] Graph model (Function nodes, Calls edges) — verified working
- [x] RiskyUncovered walker — verified end-to-end
- [x] MCP server — verified with a real MCP client over stdio; no network ports opened
- [x] Real repo scanning (AST parse + git log + coverage.json → graph) — verified on pallets/markupsafe
- [x] Gemini narration layer (Vertex AI, gemini-2.5-flash) — verified live, including from Claude Code; falls back cleanly without credentials
- [x] Triage agent (Gemini + read-only tools) — verified live on markupsafe and click, including from Claude Code
- [x] Unit tests — `jac test blindspot_tests.jac` (Gemini mocked with MockLLM, no credentials needed)
