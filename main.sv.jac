"""BlindSpot API service.

Models a codebase as a graph of functions connected by call edges, then
walks it to find code that is both UNCOVERED by tests (some or all of its
lines never run) and RISKY (reachable from other code, not a dead end).
The walkers are run in-process by
ingest.py / mcp_server.py -- no web server involved.
"""
import json;
import from byllm.lib { Model }

glob llm: Model = Model(model_name="vertex_ai/gemini-2.5-flash");

node Function {
    has qualified_name: str,
        file_path: str,
        covered: bool = False,
        untested_lines: int = 0,  # code lines in the body tests never ran
        total_lines: int = 0,     # code lines in the body
        last_editor: str = "unknown";
}

edge Calls: Function --> Function {}

walker:pub AddFunction {
    """Register a function node (called while building the graph)."""
    has qualified_name: str,
        file_path: str,
        covered: bool = False,
        untested_lines: int = 0,
        total_lines: int = 0,
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
                untested_lines=self.untested_lines,
                total_lines=self.total_lines,
                last_editor=self.last_editor,
            ))[0] as Function;
            report created;
        }
    }
}

walker:pub BuildGraph {
    """Build the whole graph in one pass: every function, then every call.
    Keeps a name -> node table so each lookup is instant, instead of
    searching the graph once per function and per call (AddFunction /
    AddCallEdge), which takes minutes on a repo with ~1000 calls."""
    has functions: list[dict],
        calls: list[tuple[str, str]];

    can build with Root entry {
        by_name: dict[str, Function] = {};
        for rec in self.functions {
            name = rec["qualified_name"];
            if name not in by_name {
                by_name[name] = (here ++> Function(**rec))[0] as Function;
            }
        }
        for (caller, callee) in self.calls {
            if caller in by_name and callee in by_name {
                by_name[caller] +>:Calls():+> by_name[callee];
            }
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

"""Most urgent first: functions tests never touch at all, then the ones
the most other code depends on."""
def rank_findings(findings: list[dict]) -> list[dict] {
    return sorted(
        findings,
        key=lambda f: dict : (not f["fully_untested"], -f["called_by_count"])
    );
}

walker:pub RiskyUncovered {
    """Find functions with untested lines that are still called from
    other code (i.e. not dead code) -- the highest-priority gaps. Each
    finding says how much is untested, from a single line to the whole
    function (fully_untested).
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
                "untested_lines": here.untested_lines,
                "total_lines": here.total_lines,
                "fully_untested": here.untested_lines == here.total_lines,
            });
        }
    }

    can finish with Root exit {
        report {"findings": rank_findings(self.findings)};
    }
}

obj RiskReview {
    has summary: str;
    has priority: str;
}
sem RiskReview.summary = "A concise, actionable code-review comment (2-4 sentences) summarizing the risky uncovered functions for a developer about to merge a pull request. Reference specific function and file names.";
sem RiskReview.priority = "Overall urgency of addressing these gaps before merge. One of: low, medium, high.";

def narrate_findings(findings_json: str) -> RiskReview by llm();
sem narrate_findings = "Given a JSON list of functions that have untested lines but ARE called by other code (real risk, not dead code), write a short, prioritized code-review comment a developer would actually read before merging. Functions with fully_untested=true have no test coverage at all; the others are only partly untested (see untested_lines of total_lines), so describe them accurately and never call a partly tested function untested.";
sem narrate_findings.findings_json = "JSON-encoded list of findings, most urgent first, each with function, file, called_by_count, untested_lines, total_lines, fully_untested.";

walker:pub NarratedRiskReport(RiskyUncovered) {
    """Same graph walk as RiskyUncovered, but the exit ability sends the
    raw findings to Gemini (via byLLM) for a human-readable, prioritized
    review comment instead of returning bare JSON.
    """
    override can finish with Root exit {
        self.findings = rank_findings(self.findings);
        if self.findings {
            # Gemini doesn't need people's names to write the comment, so
            # leave last_editor out of what we send to Google.
            to_send = [
                {"function": f["function"], "file": f["file"],
                 "called_by_count": f["called_by_count"],
                 "untested_lines": f["untested_lines"],
                 "total_lines": f["total_lines"],
                 "fully_untested": f["fully_untested"]}
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


# ---------------------------------------------------------------------------
# Triage agent: Gemini investigates each risky function with read-only
# tools, then decides how urgently it needs tests and why.
# ---------------------------------------------------------------------------

# What the agent's tools may read. Filled in by TriageRisks right before the
# LLM call, from data BlindSpot already has in memory -- the agent never
# passes a file path, so it can't read anything else.
glob triage_sources: dict[str, str] = {},
     triage_callers: dict[str, list[str]] = {};

"""Read-only tool: the source code of one function."""
def read_function_source(qualified_name: str) -> str {
    return triage_sources.get(
        qualified_name, f"No source available for {qualified_name}."
    );
}
sem read_function_source = "Return the Python source code of one function from the scanned repo (read-only). Use it to see what the function actually does.";
sem read_function_source.qualified_name = "Full function name exactly as it appears in the findings, e.g. src.pkg.module.Class.method.";

"""Read-only tool: which functions call this one."""
def list_callers(qualified_name: str) -> list[str] {
    return triage_callers.get(qualified_name, []);
}
sem list_callers = "Return the full names of the functions that call the given function (read-only). Use it to judge how much other code depends on it.";
sem list_callers.qualified_name = "Full function name exactly as it appears in the findings.";

obj Triage {
    has function: str;
    has priority: str;
    has reason: str;
}
sem Triage.function = "Full function name, exactly as given in the findings.";
sem Triage.priority = "How urgently this function needs tests. One of: high, medium, low.";
sem Triage.reason = "One sentence explaining the priority, grounded in what the code does and who calls it.";

def triage_findings(findings_json: str) -> list[Triage] by llm(
    tools=[read_function_source, list_callers], max_react_iterations=25
);
sem triage_findings = "You are reviewing functions that other code calls but tests don't fully cover. Investigate before judging: you MUST call read_function_source for EVERY finding before giving your answer (never judge a function you haven't read), and call list_callers when knowing who depends on it would change the priority. Then decide how urgently it needs tests (high, medium or low) with a one-sentence reason based on the code itself. Error handling, security, data changes and widely used helpers matter more than trivial getters or repr methods. A partly tested function (fully_untested=false) is only partly untested; say so accurately. Return one Triage per finding, most urgent first.";
sem triage_findings.findings_json = "JSON-encoded list of findings, each with function, file, called_by_count, untested_lines, total_lines, fully_untested.";

walker:pub TriageRisks(RiskyUncovered) {
    """Same graph walk as RiskyUncovered, then a Gemini agent triages the
    most urgent findings using the read-only tools above."""
    has sources: dict[str, str] = {},
        max_functions: int = 10,
        callers_of: dict[str, list[str]] = {};

    can note_callers with Function entry {
        self.callers_of[here.qualified_name] = [
            (c as Function).qualified_name for c in [here <-:Calls:<-]
        ];
    }

    override can finish with Root exit {
        global triage_sources, triage_callers;
        self.findings = rank_findings(self.findings);
        top = self.findings[:self.max_functions];
        # The agent may read the flagged functions and the code that calls them.
        readable: set[str] = set();
        for f in top {
            name = str(f["function"]);
            readable.add(name);
            readable.update(self.callers_of.get(name, []));
        }
        triage_sources = {n: self.sources[n] for n in readable if n in self.sources};
        triage_callers = {
            str(f["function"]): self.callers_of.get(str(f["function"]), []) for f in top
        };
        # Leave people's names (last_editor) out of what goes to Google.
        to_send = [
            {"function": f["function"], "file": f["file"],
             "called_by_count": f["called_by_count"],
             "untested_lines": f["untested_lines"],
             "total_lines": f["total_lines"],
             "fully_untested": f["fully_untested"]}
            for f in top
        ];
        if not top {
            report {"findings": self.findings, "triage": [], "summary": "No risky uncovered functions found."};
        } else {
            try {
                # Gemini sometimes stops early and skips functions, so send the
                # missing ones back for another round (up to 3 rounds). Only
                # keep answers about functions we actually asked about.
                judged: dict[str, Triage] = {};
                pending = to_send;
                for _ in range(3) {
                    if not pending {
                        break;
                    }
                    for t in triage_findings(json.dumps(pending)) {
                        if t.function in triage_callers and t.function not in judged {
                            judged[t.function] = t;
                        }
                    }
                    pending = [f for f in to_send if f["function"] not in judged];
                }
                order = {"high": 0, "medium": 1, "low": 2};
                ranked = sorted(
                    judged.values(),
                    key=lambda t: Triage : order.get(t.priority.lower(), 3)
                );
                report {
                    "findings": self.findings,
                    "triage": [
                        {"function": t.function, "priority": t.priority, "reason": t.reason}
                        for t in ranked
                    ],
                    "triaged_count": len(judged),
                };
            } except Exception as e {
                # Log details server-side only, like NarratedRiskReport.
                print(f"TriageRisks: LLM call failed: {type(e).__name__}");
                report {
                    "findings": self.findings,
                    "triage": [],
                    "summary": "Triage unavailable: the Gemini call failed. Make sure "
                        "you've run `gcloud auth application-default login` against a "
                        "Google Cloud project with the Vertex AI API enabled. "
                        "(RiskyUncovered works without this.)",
                };
            }
        }
    }
}
