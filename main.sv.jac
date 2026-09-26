"""BlindSpot API service.

Models a codebase as a graph of functions connected by call edges, then
walks it to find code that is both UNCOVERED by tests and RISKY (reachable
from other code, not a dead end). The walkers are run in-process by
ingest.py / mcp_server.py -- no web server involved.
"""
import json;
import from byllm.lib { Model }

glob llm: Model = Model(model_name="vertex_ai/gemini-2.0-flash-001");

node Function {
    has qualified_name: str,
        file_path: str,
        covered: bool = False,
        last_editor: str = "unknown";
}

edge Calls: Function --> Function {}

walker:pub AddFunction {
    """Register a function node (called while building the graph)."""
    has qualified_name: str,
        file_path: str,
        covered: bool = False,
        last_editor: str = "unknown",
        reports: list[Function] = [];

    can add with Root entry {
        existing = [here --> [?:Function, qualified_name == self.qualified_name]];
        if existing {
            report existing[0];
        } else {
            created = (here ++> Function(
                qualified_name=self.qualified_name,
                file_path=self.file_path,
                covered=self.covered,
                last_editor=self.last_editor,
            ))[0] as Function;
            report created;
        }
    }
}

walker:pub AddCallEdge {
    """Connect two already-registered functions with a Calls edge."""
    has caller: str,
        callee: str;

    can connect with Root entry {
        callers = [here --> [?:Function, qualified_name == self.caller]];
        callees = [here --> [?:Function, qualified_name == self.callee]];
        if callers and callees {
            callers[0] +>:Calls():+> callees[0];
        }
    }
}

walker:pub RiskyUncovered {
    """Find functions with zero test coverage that are still reachable
    from other code (i.e. not dead code) -- the highest-priority gaps.
    """
    has findings: list[dict] = [],
        reports: list[dict] = [];

    can scan with Root entry {
        visit [-->];
    }

    can check with Function entry {
        callers = [edge here <-:Calls:<-];
        if (not here.covered) and len(callers) > 0 {
            self.findings.append({
                "function": here.qualified_name,
                "file": here.file_path,
                "last_editor": here.last_editor,
                "called_by_count": len(callers),
            });
        }
    }

    can finish with Root exit {
        report {"findings": self.findings};
    }
}

obj RiskReview {
    has summary: str;
    has priority: str;
}
sem RiskReview.summary = "A concise, actionable code-review comment (2-4 sentences) summarizing the risky uncovered functions for a developer about to merge a pull request. Reference specific function and file names.";
sem RiskReview.priority = "Overall urgency of addressing these gaps before merge. One of: low, medium, high.";

def narrate_findings(findings_json: str) -> RiskReview by llm();
sem narrate_findings = "Given a JSON list of functions that have zero test coverage but ARE called by other code (real risk, not dead code), write a short, prioritized code-review comment a developer would actually read before merging.";
sem narrate_findings.findings_json = "JSON-encoded list of risky-uncovered-function findings, each with function, file, called_by_count.";

walker:pub NarratedRiskReport(RiskyUncovered) {
    """Same graph walk as RiskyUncovered, but the exit ability sends the
    raw findings to Gemini (via byLLM) for a human-readable, prioritized
    review comment instead of returning bare JSON.
    """
    override can finish with Root exit {
        if self.findings {
            # Gemini doesn't need people's names to write the comment, so
            # leave last_editor out of what we send to Google.
            to_send = [
                {"function": f["function"], "file": f["file"],
                 "called_by_count": f["called_by_count"]}
                for f in self.findings
            ];
            try {
                review = narrate_findings(json.dumps(to_send));
                report {
                    "findings": self.findings,
                    "summary": review.summary,
                    "priority": review.priority,
                };
            } except Exception as e {
                # Log details server-side only; never send stack traces or
                # environment details back to the caller.
                print(f"NarratedRiskReport: LLM call failed: {type(e).__name__}");
                report {
                    "findings": self.findings,
                    "summary": "Narration unavailable: the Gemini call failed. Make sure "
                        "you've run `gcloud auth application-default login` against a "
                        "Google Cloud project with the Vertex AI API enabled. "
                        "(RiskyUncovered works without this.)",
                    "priority": "unknown",
                };
            }
        } else {
            report {
                "findings": self.findings,
                "summary": "No risky uncovered functions found.",
                "priority": "low",
            };
        }
    }
}
