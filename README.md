# BlindSpot

BlindSpot turns your codebase's call structure into a Jac graph and walks it
to find functions with **untested lines that are still called by other
code**. That is real risk, not dead code. It is exposed as MCP tools that AI
coding assistants can call.

Built for JacHacks A2Tech, September 26 to 27, 2026.

## Architecture

```
   AI client: Claude Code, or any MCP client
              |  MCP over stdio, a private pipe, not the network
              v
     mcp_server.py   Python, MCP SDK
              |  in-process
              v
     ingest.py       Python: checks inputs, loads the Jac modules
              |
              v
     scanner.jac     Jac: reads the repo
              |
              v
     main.sv.jac     Jac: graph and walkers
              |  outgoing HTTPS, only for narration and triage
              v
     Gemini 2.5 Flash on Vertex AI
```

- **`scanner.jac`** reads a repo. It uses Python's `ast` module to find
  functions and calls, so the scanned code is never run. It reads
  `coverage.json` to see which lines the tests ran, and `git log` to find
  each file's last editor.
- **`main.sv.jac`** holds the graph: `Function` nodes and `Calls` edges,
  built in one pass by the `BuildGraph` walker. The `RiskyUncovered` walker
  finds untested code that other code actually depends on.
  `NarratedRiskReport` adds a Gemini review comment, and `TriageRisks` runs
  the Gemini triage agent described below.
- **`ingest.py`** is the thin Python loader and command line around the two
  Jac modules.
- **`mcp_server.py`** is a thin MCP server that exposes the scan as three
  tools, listed below.
- **`blindspot_tests.jac`** holds the unit tests. Run them with
  `jac test blindspot_tests.jac`. Gemini is replaced by `MockLLM` and
  `MockToolCall`, so no credentials are needed.

**No network server, no open port.** Your AI client launches
`mcp_server.py` itself and talks to it over stdio. The Jac graph runs inside
that same process, so nothing on your network can connect to it. The only
network traffic is outgoing, to Google's Gemini API, and only when you use
narration or triage.

## Requirements

**Python 3.12 or newer is required**, because Jac uses `typing.override`,
which was added in 3.12. Check with `python3 --version` before installing,
and use a 3.12 venv if your system Python is older.

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

That's all the core scan needs. To use Gemini narration and triage, you
also need:

- a Google account and a **Google Cloud project with billing enabled or
  credits**, with the **Vertex AI API** turned on
- the **`gcloud` CLI**. See the [install guide](https://cloud.google.com/sdk/docs/install).
  On macOS you can run `brew install --cask google-cloud-sdk`.
- the Vertex AI SDK in the BlindSpot venv: `pip install google-cloud-aiplatform`

The setup steps are in [Gemini narration](#gemini-narration-on-vertex-ai) below.

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
  --src-glob "src/**/*.py"   # adjust the glob to the repo's layout
# Add --narrate or --triage for the Gemini features described below.
```

The scanned folder must be a git repo, and `--src-glob` must stay inside
it. It can't contain `..` or be an absolute path.

## Use it from an AI assistant over MCP

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

For Claude Code, you can register it for all your projects with:

```bash
claude mcp add --scope user blindspot -- \
  /path/to/blindspot/.venv/bin/python /path/to/blindspot/mcp_server.py
```

Then start a new chat so it picks up the tools.

Tools:
- `find_risky_uncovered_functions(repo_path, coverage_json_path, src_glob)`
  runs the scan.
- `get_narrated_risk_report(repo_path, coverage_json_path, src_glob)` adds a
  Gemini review comment.
- `triage_risky_functions(repo_path, coverage_json_path, src_glob)` has a
  Gemini agent investigate the top findings and rank them.

Each finding reports how much of the function is untested, as
`untested_lines` out of `total_lines`, counting only real code lines in the
body. It also says whether the function is `fully_untested`. Fully untested
functions are listed first, then the ones the most other code calls.

BlindSpot was verified end to end against real repos, and cross-checked
against an independent re-implementation of the same rules:

- **pallets/markupsafe**, with real git history and a real pytest and
  coverage run: 53 functions, 20 call edges and 3 findings. `Markup.join`
  and `Markup.replace` have no test coverage at all. `Markup.escape` is
  called from 10 places, but 1 of its 4 code lines never runs under the
  tests. Fully covered code and dead code are excluded.
- **pallets/click**, a larger repo: 534 functions, 1021 call edges and 99
  findings, scanned in about 2 seconds.

**How calls are matched:** by function name. `self.save()` inside a class
links to that class's own `save` method. Calls to special methods such as
`__init__` or `__repr__` are not matched by name, since a call such as
`super().__init__()` doesn't say which class's method runs. When a name is
defined more than once, as with `@overload` stubs, BlindSpot analyses the
last definition, which is the one Python actually uses.

**Known limitation:** other method calls are matched by name only, without
knowing the object's type. For example, `stream.write(x)` links to every
`write` method in the repo, so common method names can produce false edges.
Type-aware resolution would be the first thing to improve.

## Gemini narration on Vertex AI

`NarratedRiskReport` runs the same graph walk as `RiskyUncovered`, but its
exit ability sends the findings to Gemini through Jac's `by llm()` and
returns a prioritized, readable code-review comment instead of bare JSON.
`RiskyUncovered` itself needs no credentials at all. This layer is an
optional addition on top of it.

**Cost:** the core scan is free and needs no Google account. That covers
`find_risky_uncovered_functions` and `ingest.py` without flags. Narration
and triage call Gemini on Vertex AI, which needs a Google Cloud project with
**billing enabled or credits** attached. A scan costs a fraction of a cent.

**Bring your own credentials.** No API key lives in this repo, ever.
Narration and triage use the Google Cloud login of whoever runs BlindSpot,
on their own machine, through Application Default Credentials. Nothing is
read from source, committed or shared. If that login isn't set up, you get a
clear "unavailable" message instead of a crash, and the findings still come
back.

**Privacy:** narration sends function names, file paths and line counts
from the scanned repo to Google's Gemini API, and never people's names.
Triage also sends the **source code** of the functions it investigates.
Keep that in mind before scanning private code.

```bash
# One-time setup: your Google account and a Google Cloud project with Vertex AI enabled.
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
gcloud auth application-default set-quota-project YOUR_PROJECT_ID
gcloud services enable aiplatform.googleapis.com
pip install google-cloud-aiplatform   # needed only for narration and triage

python ingest.py /path/to/target/repo /tmp/coverage.json --narrate
```

`glob llm` in `main.sv.jac` targets `vertex_ai/gemini-2.5-flash`.

## Triage agent

`TriageRisks` goes a step further than narration. A Gemini agent
**investigates** the 10 most urgent findings before judging them. Through
Jac's `by llm(tools=[...])`, it can call two read-only tools:

- `read_function_source(name)` returns the function's source code.
- `list_callers(name)` returns the functions that call it, from the Jac graph.

The agent decides for itself which tools to call. It then returns a
priority of high, medium or low and a one-line reason for each function,
based on what the code actually does. For example, in our test run on
pallets/click it moved trivial `isatty` passthroughs down to low, even
though many places call them. Gemini's priorities and wording can vary
between runs, but the findings themselves don't.

If Gemini skips a function, BlindSpot sends just the missing ones back, for
up to 3 rounds, and it drops any function name Gemini made up.

**Safety:** the tools only read data BlindSpot already holds in memory,
namely the flagged functions and their callers. The agent never passes a
file path, so it can't read anything else, and it can't write files or run
commands. Each round is capped at 25 agent steps. If Gemini fails, you get
a clear "triage unavailable" message and the findings still come back.

**Only triage code you trust.** Because the agent reads the scanned code,
text inside that code, such as a comment, could try to steer Gemini's
answer, and that answer is passed back to your AI assistant. The agent
can't act on it, because its tools are read-only, but treat triage output on
untrusted repos with care.

```bash
python ingest.py /path/to/target/repo /tmp/coverage.json --triage
```

## Status

- [x] Graph model with `Function` nodes and `Calls` edges: verified working
- [x] `RiskyUncovered` walker: verified end to end
- [x] MCP server: verified with a real MCP client over stdio, with no network ports opened
- [x] Real repo scanning of AST, git log and coverage.json into the graph: verified on pallets/markupsafe and pallets/click
- [x] Gemini narration on Vertex AI with gemini-2.5-flash: verified live, including from Claude Code, and falls back cleanly without credentials
- [x] Triage agent with Gemini and read-only tools: verified live on markupsafe and click, including from Claude Code
- [x] Unit tests: `jac test blindspot_tests.jac`, with Gemini mocked by `MockLLM`, so no credentials are needed
