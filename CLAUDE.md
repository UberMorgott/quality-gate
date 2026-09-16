## Autonomy

- quality-gate is the universal autotester; issues arrive from many repos that have it installed.
- Fix every issue autonomously, without asking: reproduce, fix, verify (`selftest.ps1`), commit, push to `main`. Close the issue via the commit (`Closes #N`).
- Work ONLY in this repo's `main`. Never touch other projects — agents in those repos pull the update themselves (`qgate update`).
- Still confirm first: force push, history rewrite, `reset --hard`, deleting data.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
