"""Tests for BlindSpot. Run with:  jac test blindspot_tests.jac

Walker tests build tiny graphs by hand; Gemini is replaced by MockLLM so
no credentials or credits are needed.
"""
import main;
import scanner;
import tempfile;
import from pathlib { Path }
import from byllm.lib { MockLLM, Model }
import from jaclang.lib { destroy }


"""Remove Function nodes left over from earlier tests or runs, so each
test sees only the graph it builds."""
def fresh_graph {
    old = [root-->][?:main.Function];
    if old {
        destroy(old as list);
    }
}


"""Build: caller -> risky (fully untested), caller -> partial (1 of 4
lines untested), caller -> safe (covered), plus dead (untested, called
by nothing)."""
def build_sample_graph {
    fresh_graph();
    # (name, untested lines, total lines)
    for (name, untested, total) in [
        ("caller", 0, 3), ("risky", 2, 2), ("partial", 1, 4), ("safe", 0, 5), ("dead", 3, 3)
    ] {
        root spawn main.AddFunction(
            qualified_name=name, file_path="m.py", covered=untested == 0,
            untested_lines=untested, total_lines=total, last_editor="Ada"
        );
    }
    for callee in ["risky", "partial", "safe"] {
        root spawn main.AddCallEdge(caller="caller", callee=callee);
    }
}


test "flags called functions with untested lines, fully untested first" {
    build_sample_graph();
    findings = (root spawn main.RiskyUncovered()).reports[0]["findings"] as list[dict[str, any]];
    assert [f["function"] for f in findings] == ["risky", "partial"], f"got {findings}";
    assert findings[0]["fully_untested"] == True;
    assert findings[0]["called_by_count"] == 1;
}


test "partly tested functions report how much is untested" {
    build_sample_graph();
    findings = (root spawn main.RiskyUncovered()).reports[0]["findings"] as list[dict[str, any]];
    partial = [f for f in findings if f["function"] == "partial"][0];
    assert partial["fully_untested"] == False, "1 of 4 lines untested is not 'fully untested'";
    assert partial["untested_lines"] == 1;
    assert partial["total_lines"] == 4;
}


test "ignores covered functions and dead code" {
    build_sample_graph();
    findings = (root spawn main.RiskyUncovered()).reports[0]["findings"] as list[dict[str, any]];
    flagged = [f["function"] for f in findings];
    assert "safe" not in flagged, "covered code should not be flagged";
    assert "dead" not in flagged, "uncalled (dead) code should not be flagged";
}


test "adding the same function twice keeps one node" {
    fresh_graph();
    root spawn main.AddFunction(qualified_name="f", file_path="m.py");
    root spawn main.AddFunction(qualified_name="f", file_path="m.py");
    assert len([root-->][?:main.Function]) == 1;
}


test "narration returns Gemini's summary and priority" {
    build_sample_graph();
    main.llm = MockLLM(
        model_name="mockllm",
        config={"outputs": [main.RiskReview(summary="Test risky() first.", priority="high")]},
    ) as Model;
    out = (root spawn main.NarratedRiskReport()).reports[0];
    assert out["summary"] == "Test risky() first.";
    assert out["priority"] == "high";
    assert len(out["findings"] as list) == 2;
}


test "narration falls back safely when Gemini fails" {
    build_sample_graph();
    # No canned outputs left to give, so the LLM call errors out.
    main.llm = MockLLM(model_name="mockllm", config={"outputs": []}) as Model;
    out = (root spawn main.NarratedRiskReport()).reports[0];
    assert out["summary"].startswith("Narration unavailable");
    assert out["priority"] == "unknown";
    assert len(out["findings"] as list) == 2, "findings must still come back";
}


test "author names are cleaned before use" {
    assert scanner.clean_name("Ada Lovelace\n") == "Ada Lovelace";
    assert scanner.clean_name("<script>alert(1)</script>") == "scriptalert1script";
    assert len(scanner.clean_name("x" * 100)) == 40;
    assert scanner.clean_name("   ") == "unknown";
}


test "scanner finds functions, methods, calls and coverage" {
    with tempfile.TemporaryDirectory() as tmp {
        repo = Path(str(tmp)).resolve();
        (repo / "src").mkdir();
        (repo / "src" / "m.py").write_text(
            "def a():\n    b()\n\ndef b():\n    return 1\n\nclass C:\n    def c(self):\n        self.a()\n"
        );
        (repo / "src" / "broken.py").write_text("def oops(:\n");
        # Only b's body (line 5) never ran; `def` lines always run on import.
        coverage = {"files": {"src/m.py": {
            "executed_lines": [1, 2, 4, 7, 8, 9], "missing_lines": [5]
        }}};

        (records, edges) = scanner.collect(repo, coverage, "src/**/*.py");
        by_name = {r["qualified_name"]: r for r in records};

        assert set(by_name.keys()) == {"src.m.a", "src.m.b", "src.m.C.c"}, "broken.py should be skipped";
        assert by_name["src.m.a"]["covered"] == True;
        assert by_name["src.m.b"]["covered"] == False;
        assert by_name["src.m.b"]["untested_lines"] == 1, "the def line must not count";
        assert by_name["src.m.b"]["total_lines"] == 1;
        assert ("src.m.a", "src.m.b") in edges;
        assert ("src.m.C.c", "src.m.a") in edges;
    }
}


test "BuildGraph builds the same graph as adding one by one" {
    fresh_graph();
    root spawn main.BuildGraph(
        functions=[
            {"qualified_name": "caller", "file_path": "m.py", "covered": True,
             "untested_lines": 0, "total_lines": 3, "last_editor": "Ada"},
            {"qualified_name": "risky", "file_path": "m.py", "covered": False,
             "untested_lines": 2, "total_lines": 2, "last_editor": "Ada"},
            {"qualified_name": "risky", "file_path": "m.py", "covered": False,
             "untested_lines": 2, "total_lines": 2, "last_editor": "Ada"},
        ],
        calls=[("caller", "risky"), ("caller", "missing")],
    );
    assert len([root-->][?:main.Function]) == 2, "duplicate names become one node";
    findings = (root spawn main.RiskyUncovered()).reports[0]["findings"] as list[dict[str, any]];
    assert [f["function"] for f in findings] == ["risky"];
}


"""Scan one made-up Python file and return its (records by name, edges)."""
def scan_source(
    source: str, missing: list[int]
) -> tuple[dict[str, dict[str, str | bool | int]], list[tuple[str, str]]] {
    with tempfile.TemporaryDirectory() as tmp {
        repo = Path(str(tmp)).resolve();
        (repo / "m.py").write_text(source);
        lines = list(range(1, len(source.splitlines()) + 1));
        coverage = {"files": {"m.py": {
            "executed_lines": [n for n in lines if n not in missing], "missing_lines": missing
        }}};
        (records, edges) = scanner.collect(repo, coverage, "*.py");
        return ({str(r["qualified_name"]): r for r in records}, edges);
    }
}


test "overloaded functions are judged by their real body" {
    # Lines 1-4 are @overload type stubs; lines 6-7 are the real function.
    source = "@overload\ndef f(x: int) -> int: ...\n@overload\ndef f(x: str) -> str: ...\n\ndef f(x):\n    return x\n";
    (by_name, _) = scan_source(source, [7]);
    assert len(by_name) == 1;
    assert by_name["m.f"]["untested_lines"] == 1, "must use the real body, not a stub";
    assert by_name["m.f"]["total_lines"] == 1;
}


test "self.method() links only to the same class's method" {
    source = "class A:\n    def run(self):\n        self.save()\n    def save(self):\n        pass\n\nclass B:\n    def save(self):\n        pass\n";
    (_, edges) = scan_source(source, []);
    assert ("m.A.run", "m.A.save") in edges;
    assert ("m.A.run", "m.B.save") not in edges, "B.save is a different method";
}


test "calls to special methods like __init__ are not matched by name" {
    source = "class A:\n    def __init__(self):\n        pass\n\nclass B(A):\n    def __init__(self):\n        super().__init__()\n";
    (_, edges) = scan_source(source, []);
    assert edges == [], f"super().__init__() should not link to every __init__, got {edges}";
}
