"""Load a real Python repo into BlindSpot's Jac graph and walk it.

Walks .py files with the ast module to find functions and their call
sites, cross-references coverage.json for per-function coverage, uses
`git log` for last-editor, then builds the graph and runs the walkers
from main.sv.jac -- all in this one process. There is no server and no
network port involved.

Usage (prints the findings as JSON):
    python ingest.py <repo_path> <coverage_json_path> [--src-glob GLOB] [--narrate]
"""
import argparse
import ast
import contextlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Where the caller started us, so relative paths they pass still work
# after we switch into the BlindSpot folder (see _load_graph).
ORIGINAL_CWD = Path.cwd()


def clean_name(name: str) -> str:
    # Git author names are free text anyone can set, and they flow back to
    # the AI assistant (and Gemini). Keep only name-like characters and cap
    # the length so a repo can't smuggle instructions in through them.
    cleaned = re.sub(r"[^\w .'-]", "", name)[:40].strip()
    return cleaned or "unknown"


def last_editor(repo: Path, file_path: Path) -> str:
    try:
        out = subprocess.run(
            # The -c flags stop a scanned repo's own .git/config from
            # running commands (fsmonitor/hooks) when we call git.
            ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
             "-C", str(repo), "log", "-1", "--format=%an", "--", str(file_path)],
            capture_output=True, text=True, timeout=5,
        )
        return clean_name(out.stdout)
    except Exception:
        return "unknown"


class FunctionInfo:
    def __init__(self, qualified_name, file_path, lineno, end_lineno, calls):
        self.qualified_name = qualified_name
        self.file_path = file_path
        self.lineno = lineno
        self.end_lineno = end_lineno
        self.calls = calls  # list of plain callee names referenced in the body


def extract_functions(py_file: Path, module_qualifier: str) -> list[FunctionInfo]:
    try:
        tree = ast.parse(py_file.read_text(), filename=str(py_file))
    except (SyntaxError, RecursionError, ValueError):
        # Broken, absurdly nested, or non-UTF-8 file: skip it rather than
        # letting one bad file crash the whole scan.
        return []

    functions = []

    def visit(node, prefix):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                qname = f"{prefix}.{child.name}" if prefix else f"{module_qualifier}.{child.name}"
                calls = []
                for sub in ast.walk(child):
                    if isinstance(sub, ast.Call):
                        f = sub.func
                        if isinstance(f, ast.Name):
                            calls.append(f.id)
                        elif isinstance(f, ast.Attribute):
                            calls.append(f.attr)
                functions.append(FunctionInfo(
                    qualified_name=qname,
                    file_path=str(py_file),
                    lineno=child.lineno,
                    end_lineno=child.end_lineno or child.lineno,
                    calls=calls,
                ))
                visit(child, qname)  # nested functions/methods
            elif isinstance(child, ast.ClassDef):
                cname = f"{prefix}.{child.name}" if prefix else f"{module_qualifier}.{child.name}"
                visit(child, cname)

    visit(tree, "")
    return functions


def is_covered(func: FunctionInfo, missing_lines: set[int]) -> bool:
    func_lines = set(range(func.lineno, func.end_lineno + 1))
    return len(func_lines & missing_lines) == 0


def collect(repo: Path, coverage_data: dict, src_glob: str):
    """Return (function records, call edges) for every function in the repo."""
    all_functions: list[FunctionInfo] = []
    for py_file in sorted(repo.glob(src_glob)):
        if not py_file.resolve().is_relative_to(repo):
            continue  # e.g. a symlink pointing outside the repo
        rel = py_file.relative_to(repo)
        module_qualifier = str(rel).replace("/", ".").removesuffix(".py")
        all_functions.extend(extract_functions(py_file, module_qualifier))

    short_name_index: dict[str, list[FunctionInfo]] = {}
    for f in all_functions:
        short = f.qualified_name.rsplit(".", 1)[-1]
        short_name_index.setdefault(short, []).append(f)

    editor_cache: dict[str, str] = {}
    records = []
    for f in all_functions:
        rel_path = str(Path(f.file_path).relative_to(repo))
        cov_entry = coverage_data.get("files", {}).get(rel_path)
        missing = set(cov_entry["missing_lines"]) if cov_entry else set()
        covered = is_covered(f, missing) if cov_entry else False

        if f.file_path not in editor_cache:
            editor_cache[f.file_path] = last_editor(repo, Path(f.file_path))

        records.append({
            "qualified_name": f.qualified_name,
            "file_path": rel_path,
            "covered": covered,
            "last_editor": editor_cache[f.file_path],
        })

    edges = []
    for f in all_functions:
        for callee_short in set(f.calls):
            for target in short_name_index.get(callee_short, []):
                if target.qualified_name != f.qualified_name:
                    edges.append((f.qualified_name, target.qualified_name))

    return records, edges


_graph = None


def _load_graph():
    """Import main.sv.jac in-process (once) and return the Jac runtime pieces."""
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
            from jaclang.lib import destroy, refs, root, spawn
            import main as graph  # main.sv.jac
        _graph = (graph, root, spawn, destroy, refs)
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

    coverage_data = json.loads(coverage_path.read_text())
    records, edges = collect(repo, coverage_data, src_glob)

    graph, root, spawn, destroy, refs = _load_graph()
    # Jac prints reports to stdout; send that to stderr so stdout stays
    # clean (the MCP protocol uses stdout).
    with contextlib.redirect_stdout(sys.stderr):
        r = root()
        old = [n for n in refs(r) if isinstance(n, graph.Function)]
        if old:
            destroy(old)  # start every scan from an empty graph
        for rec in records:
            spawn(graph.AddFunction(**rec), r)
        for caller, callee in edges:
            spawn(graph.AddCallEdge(caller=caller, callee=callee), r)
        walker = graph.NarratedRiskReport() if narrate else graph.RiskyUncovered()
        reports = spawn(walker, r).reports

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
