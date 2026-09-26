"""BlindSpot scanner.

Reads a Python repo and turns it into plain records for the graph in
main.sv.jac: which functions exist, whether tests cover them, who last
edited each file, and which functions call which. The scanned code is
only read (parsed with `ast`), never run.
"""
import ast;
import re;
import subprocess;
import from pathlib { Path }


"""One function found in the repo, before it becomes a graph node."""
obj FunctionInfo {
    has qualified_name: str,
        file_path: str,
        lineno: int,
        end_lineno: int,
        calls: list[str];  # plain names of functions called in the body
}


"""Git author names are free text anyone can set, and they flow back to
the AI assistant. Keep only name-like characters and cap the length so a
repo can't smuggle instructions in through them."""
def clean_name(name: str) -> str {
    cleaned = re.sub(r"[^\w .'-]", "", name)[:40].strip();
    return cleaned or "unknown";
}


"""Who last edited this file, according to git."""
def last_editor(repo: Path, file_path: Path) -> str {
    try {
        # The -c flags stop a scanned repo's own .git/config from
        # running commands (fsmonitor/hooks) when we call git.
        out = subprocess.run(
            ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
             "-C", str(repo), "log", "-1", "--format=%an", "--", str(file_path)],
            capture_output=True, text=True, timeout=5
        );
        return clean_name(out.stdout);
    } except Exception {
        return "unknown";
    }
}


"""Names of everything a function calls, e.g. `escape(x)` or
`self.escape(x)` both give "escape"."""
def called_names(func: ast.FunctionDef | ast.AsyncFunctionDef) -> list[str] {
    calls: list[str] = [];
    for sub in ast.walk(func) {
        if isinstance(sub, ast.Call) {
            target = sub.func;
            if isinstance(target, ast.Name) {
                calls.append(target.id);
            } elif isinstance(target, ast.Attribute) {
                calls.append(target.attr);
            }
        }
    }
    return calls;
}


"""Walk one level of the syntax tree, recording functions and going
inside classes and functions to find methods and nested functions."""
def visit_defs(parent: ast.AST, prefix: str, py_file: Path, found: list[FunctionInfo]) {
    for child in ast.iter_child_nodes(parent) {
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) {
            qname = f"{prefix}.{child.name}";
            found.append(FunctionInfo(
                qualified_name=qname,
                file_path=str(py_file),
                lineno=child.lineno,
                end_lineno=child.end_lineno or child.lineno,
                calls=called_names(child),
            ));
            visit_defs(child, qname, py_file, found);
        } elif isinstance(child, ast.ClassDef) {
            visit_defs(child, f"{prefix}.{child.name}", py_file, found);
        }
    }
}


"""Every function defined in one .py file."""
def extract_functions(py_file: Path, module_qualifier: str) -> list[FunctionInfo] {
    try {
        tree = ast.parse(py_file.read_text(), filename=str(py_file));
    } except (SyntaxError, RecursionError, ValueError) {
        # Broken, absurdly nested, or non-UTF-8 file: skip it rather than
        # letting one bad file crash the whole scan.
        return [];
    }
    found: list[FunctionInfo] = [];
    visit_defs(tree, module_qualifier, py_file, found);
    return found;
}


"""A function counts as covered only if tests ran every one of its lines."""
def is_covered(func: FunctionInfo, missing_lines: set[int]) -> bool {
    func_lines = set(range(func.lineno, func.end_lineno + 1));
    return len(func_lines & missing_lines) == 0;
}


"""Scan the repo: return one record per function (for AddFunction) and
one (caller, callee) pair per call (for AddCallEdge)."""
def collect(
    repo: Path, coverage_data: dict[str, any], src_glob: str
) -> tuple[list[dict[str, str | bool]], list[tuple[str, str]]] {
    all_functions: list[FunctionInfo] = [];
    for py_file in sorted(repo.glob(src_glob)) {
        if not py_file.resolve().is_relative_to(repo) {
            continue;  # e.g. a symlink pointing outside the repo
        }
        rel = py_file.relative_to(repo);
        module_qualifier = str(rel).replace("/", ".").removesuffix(".py");
        all_functions.extend(extract_functions(py_file, module_qualifier));
    }

    # Calls are matched by short name ("escape"), so index functions by it.
    by_short_name: dict[str, list[FunctionInfo]] = {};
    for f in all_functions {
        short = f.qualified_name.rsplit(".", 1)[-1];
        by_short_name.setdefault(short, []).append(f);
    }

    editor_cache: dict[str, str] = {};
    records: list[dict[str, str | bool]] = [];
    for f in all_functions {
        rel_path = str(Path(f.file_path).relative_to(repo));
        cov_entry = coverage_data.get("files", {}).get(rel_path);
        missing: set[int] = set(cov_entry["missing_lines"]) if cov_entry else set();
        covered = is_covered(f, missing) if cov_entry else False;

        if f.file_path not in editor_cache {
            editor_cache[f.file_path] = last_editor(repo, Path(f.file_path));
        }

        records.append({
            "qualified_name": f.qualified_name,
            "file_path": rel_path,
            "covered": covered,
            "last_editor": editor_cache[f.file_path],
        });
    }

    edges: list[tuple[str, str]] = [];
    for f in all_functions {
        for callee_short in set(f.calls) {
            for target in by_short_name.get(callee_short, []) {
                if target.qualified_name != f.qualified_name {
                    edges.append((f.qualified_name, target.qualified_name));
                }
            }
        }
    }
    return (records, edges);
}
