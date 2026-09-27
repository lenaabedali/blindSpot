"""BlindSpot MCP server.

Your AI client (Claude Code, Cursor, ...) launches this script and talks to
it over stdio -- a private pipe between the two programs. There is no HTTP
server and no open network port: the Jac graph in main.sv.jac is loaded and
walked right here, in-process, so nothing else on your network can reach it.

Point your MCP client's config at:  python /path/to/blindspot/mcp_server.py
"""
from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

from ingest import _load_graph, scan

mcp = MCPServer("blindspot")


def _scan(*args, **kwargs) -> dict:
    """Run a scan; if the inputs are bad, tell the AI why (e.g. "Not a git
    repo") so it can fix them. These are our own messages about the paths
    it passed. Any other crash stays a generic error, so internal details
    never leave this machine."""
    try:
        return scan(*args, **kwargs)
    except ValueError as e:
        raise ToolError(str(e)) from e


@mcp.tool()
def find_risky_uncovered_functions(repo_path: str, coverage_json_path: str,
                                   src_glob: str = "src/**/*.py") -> dict:
    """Scan a Python repo and return functions with untested lines that ARE
    called from other code (real risk, not dead code), found by walking its
    call graph in Jac. Each finding says how many of its lines tests never
    run; fully untested functions come first.

    repo_path: the repo folder. coverage_json_path: output of
    `coverage json` from running that repo's tests. src_glob: which files
    to scan, relative to the repo.
    """
    return _scan(repo_path, coverage_json_path, src_glob)


@mcp.tool()
def get_narrated_risk_report(repo_path: str, coverage_json_path: str,
                             src_glob: str = "src/**/*.py") -> dict:
    """Same scan as find_risky_uncovered_functions, plus a short prioritized
    code-review comment written by Gemini (Vertex AI, via Jac's by llm).
    Uses the Google Cloud login of whoever runs this server."""
    return _scan(repo_path, coverage_json_path, src_glob, narrate=True)


if __name__ == "__main__":
    _load_graph()  # compile/load the Jac graph up front so the first call is fast
    mcp.run()
