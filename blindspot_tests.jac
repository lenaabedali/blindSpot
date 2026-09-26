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


"""Build: caller -> risky (uncovered), caller -> safe (covered),
plus dead (uncovered, called by nothing)."""
def build_sample_graph {
    fresh_graph();
    for (name, covered) in [("caller", True), ("risky", False), ("safe", True), ("dead", False)] {
        root spawn main.AddFunction(
            qualified_name=name, file_path="m.py", covered=covered, last_editor="Ada"
        );
    }
    root spawn main.AddCallEdge(caller="caller", callee="risky");
    root spawn main.AddCallEdge(caller="caller", callee="safe");
}


test "flags uncovered functions that are called" {
    build_sample_graph();
    findings = (root spawn main.RiskyUncovered()).reports[0]["findings"] as list[dict[str, any]];
    assert len(findings) == 1, f"expected only 'risky', got {findings}";
    assert findings[0]["function"] == "risky";
    assert findings[0]["called_by_count"] == 1;
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
    assert len(out["findings"] as list) == 1;
}


test "narration falls back safely when Gemini fails" {
    build_sample_graph();
    # No canned outputs left to give, so the LLM call errors out.
    main.llm = MockLLM(model_name="mockllm", config={"outputs": []}) as Model;
    out = (root spawn main.NarratedRiskReport()).reports[0];
    assert out["summary"].startswith("Narration unavailable");
    assert out["priority"] == "unknown";
    assert len(out["findings"] as list) == 1, "findings must still come back";
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
        # Lines 4-5 (function b) never ran in tests.
        coverage = {"files": {"src/m.py": {"missing_lines": [4, 5]}}};

        (records, edges) = scanner.collect(repo, coverage, "src/**/*.py");
        by_name = {r["qualified_name"]: r for r in records};

        assert set(by_name.keys()) == {"src.m.a", "src.m.b", "src.m.C.c"}, "broken.py should be skipped";
        assert by_name["src.m.a"]["covered"] == True;
        assert by_name["src.m.b"]["covered"] == False;
        assert ("src.m.a", "src.m.b") in edges;
        assert ("src.m.C.c", "src.m.a") in edges;
    }
}
