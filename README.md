# BlindSpot

A Jac-native graph of your codebase's call structure, walked to find
functions that are **uncovered by tests but still reachable** (real risk,
not dead code) — exposed as an MCP tool any AI coding assistant can call.

Built for JacHacks A2Tech (Sept 26-27, 2026).

## Architecture

```
   AI client (Claude Code / Cursor / Baz)
              |  MCP over stdio (a private pipe, not the network)
              v
     mcp_server.py  (Python, MCP SDK)
              |  in-process: builds the graph and spawns Jac walkers
              v
     main.sv.jac  (Jac: node/edge/walker graph)
```

- **`main.sv.jac`** — the graph. `Function` nodes, `Calls` edges, and a
  `RiskyUncovered` walker that traverses the call graph to find untested
  code that other code actually depends on.
- **`ingest.py`** — reads a repo (Python `ast` for functions and calls,
  `coverage.json` for what's tested, `git log` for last editor), loads it
  into the Jac graph, and runs the walker.
- **`mcp_server.py`** — a thin MCP server that exposes the scan as tools.

**No server, no open port.** Your AI client launches `mcp_server.py` and
talks to it over stdio; the Jac graph runs inside that same process.
Nothing on your network can connect to it.

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

Verified end-to-end against a real repo (pallets/markupsafe): 53 functions,
38 call edges from real git history + a real pytest/coverage run;
correctly surfaced 6 functions with zero test coverage that are still
called from elsewhere (e.g. `Markup.escape`, called from 10 places,
untested) while excluding covered code and genuinely dead code.

**Known limitation:** call edges are matched by short function name, not
full scope resolution — a name collision (two unrelated functions both
called `escape`) can produce a false edge. Fine for a hackathon demo,
proper scope resolution would be the first thing to harden.

## Gemini narration (Vertex AI, for Best of Google)

`NarratedRiskReport` is the same graph walk as `RiskyUncovered`, but its
exit ability sends the findings to Gemini via Jac's `by llm()` and returns
a prioritized, human-readable code-review comment instead of bare JSON.
`RiskyUncovered` itself needs no credentials at all — this layer is opt-in
on top of it.

**Bring your own credentials.** No API key lives in this repo, ever.
Narration uses the Google Cloud login of whoever runs BlindSpot, on their
own machine, via Application Default Credentials — nothing is read from
source, committed, or shared. If that login isn't set up, you get a clear
"narration unavailable" message instead of a crash.

Note: this sends function names and file paths from the scanned repo to
Google's Gemini API. Keep that in mind before scanning private code.

```bash
# one-time: your own Google account + a GCP project with Vertex AI enabled
gcloud auth application-default login
pip install google-cloud-aiplatform   # Vertex AI SDK, needed only for narration

python ingest.py /path/to/target/repo /tmp/coverage.json --narrate
```

`glob llm` in `main.sv.jac` targets `vertex_ai/gemini-2.0-flash-001`.

## Status

- [x] Graph model (Function nodes, Calls edges) — verified working
- [x] RiskyUncovered walker — verified end-to-end
- [x] MCP server — verified with a real MCP client over stdio; no network ports opened
- [x] Real repo scanning (AST parse + git log + coverage.json → graph) — verified on pallets/markupsafe
- [x] Gemini narration layer (Vertex AI) — falls back cleanly without credentials; needs live `gcloud auth` to run for real
