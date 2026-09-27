"""Load a real Python repo into BlindSpot's Jac graph and walk it.

The scanning itself (finding functions and calls, matching coverage,
`git log` for last editor) lives in scanner.jac; the graph and walkers
live in main.sv.jac. This file is the thin Python loader around them:
it checks the inputs, runs both in this one process, and provides the
CLI. There is no server and no network port involved.

Usage (prints the findings as JSON):
    python ingest.py <repo_path> <coverage_json_path> [--src-glob GLOB] [--narrate]
"""
import argparse
import contextlib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Where the caller started us, so relative paths they pass still work
# after we switch into the BlindSpot folder (see _load_graph).
ORIGINAL_CWD = Path.cwd()

_graph = None


def _load_graph():
    """Import the Jac modules in-process (once) and return the runtime pieces."""
    global _graph
    if _graph is None:
        # Jac keeps a small local cache/database in a .jac/ folder in the
        # current directory. Run from the BlindSpot folder so that lands
        # here (it's gitignored) rather than in whatever repo you scan.
        os.chdir(HERE)
        if str(HERE) not in sys.path:
            sys.path.insert(0, str(HERE))
        with contextlib.redirect_stdout(sys.stderr):
            import jaclang  # noqa: F401  (lets Python import .jac files)
            # Load Jac's serializer BEFORE our .jac modules: it registers
            # node/edge classes as they're created, and an unregistered
            # class can't be read back from Jac's store ("Refused to
            # deserialize unregistered class: main.Function").
            import jaclang.runtimelib.serializer  # noqa: F401
            from jaclang.lib import destroy, refs, root, spawn
            import main as graph  # main.sv.jac
            import scanner  # scanner.jac
        _graph = (graph, scanner, root, spawn, destroy, refs)
    return _graph


def scan(repo_path: str, coverage_json: str, src_glob: str = "src/**/*.py",
         narrate: bool = False) -> dict:
    """Build a fresh graph for one repo and return the walker's report."""
    repo = (ORIGINAL_CWD / repo_path).resolve()
    coverage_path = (ORIGINAL_CWD / coverage_json).resolve()
    if not repo.is_dir():
        raise ValueError(f"Repo folder not found: {repo}")
    if not coverage_path.is_file():
        raise ValueError(f"coverage.json not found: {coverage_path}")
    # Only scan real git repos (blocks pointing it at / or your home folder),
    # and keep the glob inside the repo.
    if not (repo / ".git").exists():
        raise ValueError(f"Not a git repo: {repo}")
    if Path(src_glob).is_absolute() or ".." in Path(src_glob).parts:
        raise ValueError("src_glob must stay inside the repo (no '..' or absolute paths)")

    try:
        coverage_data = json.loads(coverage_path.read_text())
    except (ValueError, UnicodeDecodeError):
        raise ValueError(f"Not a valid coverage JSON file: {coverage_path}") from None
    if not isinstance(coverage_data, dict) or not isinstance(coverage_data.get("files"), dict):
        raise ValueError(f"Not a coverage.py JSON report (run `coverage json`): {coverage_path}")
    graph, scanner, root, spawn, destroy, refs = _load_graph()
    records, edges = scanner.collect(repo, coverage_data, src_glob)

    # Jac prints reports to stdout; send that to stderr so stdout stays
    # clean (the MCP protocol uses stdout).
    with contextlib.redirect_stdout(sys.stderr):
        r = root()
        old = [n for n in refs(r) if isinstance(n, graph.Function)]
        if old:
            destroy(old)  # start every scan from an empty graph
        spawn(graph.BuildGraph(functions=records, calls=edges), r)
        walker = graph.NarratedRiskReport() if narrate else graph.RiskyUncovered()
        reports = spawn(walker, r).reports
        # Delete the graph once we have the report, so Jac's store in
        # .jac/data doesn't keep every old scan around.
        destroy([n for n in refs(r) if isinstance(n, graph.Function)])

    result = dict(reports[0]) if reports else {"findings": []}
    result["functions_scanned"] = len(records)
    result["call_edges"] = len(edges)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repo_path")
    parser.add_argument("coverage_json")
    parser.add_argument("--src-glob", default="src/**/*.py",
                        help="glob (relative to repo) for files to scan")
    parser.add_argument("--narrate", action="store_true",
                        help="also ask Gemini for a review comment (needs your own gcloud auth)")
    args = parser.parse_args()
    print(json.dumps(scan(args.repo_path, args.coverage_json, args.src_glob, args.narrate), indent=2))


if __name__ == "__main__":
    main()
