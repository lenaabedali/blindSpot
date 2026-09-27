"""BlindSpot scanner.

Reads a Python repo and turns it into plain records for the graph in
main.sv.jac: which functions exist, how many of their lines tests run,
who last edited each file, and which functions call which. The scanned
code is only read (parsed with `ast`), never run.
"""
import ast;
import re;
import subprocess;
import from pathlib { Path }


"""One function found in the repo, before it becomes a graph node."""
obj FunctionInfo {
    has qualified_name: str,
        file_path: str,
        body_start: int,  # first line INSIDE the function (not the `def`)
        end_lineno: int,
        class_name: str,  # enclosing class ("" if not a method)
        calls: list[str],  # names called in the body, e.g. escape(x), obj.write()
        self_calls: list[str];  # names called on self/cls, e.g. self.escape(x)
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


"""Names of everything a function calls, split in two: calls on
`self`/`cls` (e.g. `self.escape(x)`, which means this class's method), and
all other calls (e.g. `escape(x)` or `stream.write(x)`)."""
def called_names(func: ast.FunctionDef | ast.AsyncFunctionDef) -> tuple[list[str], list[str]] {
    calls: list[str] = [];
    self_calls: list[str] = [];
    for sub in ast.walk(func) {
        if isinstance(sub, ast.Call) {
            target = sub.func;
            if isinstance(target, ast.Name) {
                calls.append(target.id);
            } elif isinstance(target, ast.Attribute) {
                receiver = target.value;
                if isinstance(receiver, ast.Name) and receiver.id in ("self", "cls") {
                    self_calls.append(target.attr);
                } else {
                    calls.append(target.attr);
                }
            }
        }
    }
    return (calls, self_calls);
}


"""Special methods like __init__ or __repr__: a call such as
`super().__init__()` says nothing about WHICH class's method runs, so
matching them by name would link it to every __init__ in the repo."""
def is_dunder(name: str) -> bool {
    return name.startswith("__") and name.endswith("__");
}


"""Walk one level of the syntax tree, recording functions and going
inside classes and functions to find methods and nested functions."""
def visit_defs(
    parent: ast.AST, prefix: str, class_name: str, py_file: Path, found: list[FunctionInfo]
) {
    for child in ast.iter_child_nodes(parent) {
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) {
            qname = f"{prefix}.{child.name}";
            (calls, self_calls) = called_names(child);
            found.append(FunctionInfo(
                qualified_name=qname,
                file_path=str(py_file),
                # The `def` line itself always "runs" when the file is
                # imported, so only the body tells us what tests ran.
                body_start=child.body[0].lineno,
                end_lineno=child.end_lineno or child.lineno,
                class_name=class_name,
                calls=calls,
                self_calls=self_calls,
            ));
            visit_defs(child, qname, "", py_file, found);  # nested functions
        } elif isinstance(child, ast.ClassDef) {
            cname = f"{prefix}.{child.name}";
            visit_defs(child, cname, cname, py_file, found);  # methods
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
    visit_defs(tree, module_qualifier, "", py_file, found);
    return found;
}


"""Count a function's code lines and how many of them tests never ran.
Only lines coverage.py tracks count (real code, not blanks or comments).
Returns (untested, total)."""
def line_counts(func: FunctionInfo, executed: set[int], missing: set[int]) -> tuple[int, int] {
    body = set(range(func.body_start, func.end_lineno + 1));
    return (len(body & missing), len(body & (executed | missing)));
}


"""Scan the repo: return one record per function (for AddFunction) and
one (caller, callee) pair per call (for AddCallEdge)."""
def collect(
    repo: Path, coverage_data: dict[str, any], src_glob: str
) -> tuple[list[dict[str, str | bool | int]], list[tuple[str, str]]] {
    all_functions: list[FunctionInfo] = [];
    for py_file in sorted(repo.glob(src_glob)) {
        if not py_file.resolve().is_relative_to(repo) {
            continue;  # e.g. a symlink pointing outside the repo
        }
        rel = py_file.relative_to(repo);
        module_qualifier = str(rel).replace("/", ".").removesuffix(".py");
        all_functions.extend(extract_functions(py_file, module_qualifier));
    }

    # The same name can be defined more than once, e.g. `@overload` type
    # stubs followed by the real function. Like Python, keep the LAST one:
    # it's the code that actually runs.
    latest: dict[str, FunctionInfo] = {};
    for f in all_functions {
        latest[f.qualified_name] = f;
    }
    all_functions = list(latest.values());

    # Calls are matched by short name ("escape"), so index functions by it.
    by_short_name: dict[str, list[FunctionInfo]] = {};
    for f in all_functions {
        short = f.qualified_name.rsplit(".", 1)[-1];
        by_short_name.setdefault(short, []).append(f);
    }

    editor_cache: dict[str, str] = {};
    records: list[dict[str, str | bool | int]] = [];
    for f in all_functions {
        rel_path = str(Path(f.file_path).relative_to(repo));
        cov_entry = coverage_data.get("files", {}).get(rel_path);
        if cov_entry {
            (untested, total) = line_counts(
                f, set(cov_entry.get("executed_lines", [])), set(cov_entry.get("missing_lines", []))
            );
        } else {
            # File never ran under the tests at all: the whole body is untested.
            total = f.end_lineno - f.body_start + 1;
            untested = total;
        }

        if f.file_path not in editor_cache {
            editor_cache[f.file_path] = last_editor(repo, Path(f.file_path));
        }

        records.append({
            "qualified_name": f.qualified_name,
            "file_path": rel_path,
            "covered": untested == 0,
            "untested_lines": untested,
            "total_lines": total,
            "last_editor": editor_cache[f.file_path],
        });
    }

    edges: list[tuple[str, str]] = [];
    for f in all_functions {
        targets: set[str] = set();
        for name in set(f.self_calls) {
            own_method = f"{f.class_name}.{name}";
            if f.class_name and own_method in latest {
                targets.add(own_method);  # self.x() -> this class's x
            } elif not is_dunder(name) {
                # Not defined here (e.g. inherited): fall back to name matching.
                targets.update(t.qualified_name for t in by_short_name.get(name, []));
            }
        }
        for name in set(f.calls) {
            if not is_dunder(name) {
                targets.update(t.qualified_name for t in by_short_name.get(name, []));
            }
        }
        targets.discard(f.qualified_name);  # a function calling itself isn't "used elsewhere"
        for target in sorted(targets) {
            edges.append((f.qualified_name, target));
        }
    }
    return (records, edges);
}
