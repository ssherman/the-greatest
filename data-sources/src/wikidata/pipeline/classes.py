"""The class closure: every class at or below a set of roots in the subclass-of (P279) graph."""

from collections import defaultdict, deque
from collections.abc import Iterable

import duckdb


def closure(subclass_edges: Iterable[tuple[str, str]], roots: Iterable[str]) -> set[str]:
    """Edges are (child, parent). Returns the roots plus every class that reaches one."""
    children: dict[str, list[str]] = defaultdict(list)
    for child, parent in subclass_edges:
        children[parent].append(child)
    seen = set(roots)
    queue = deque(seen)
    while queue:
        for child in children.get(queue.popleft(), ()):
            if child not in seen:
                seen.add(child)
                queue.append(child)
    return seen


def closure_table(
    con: duckdb.DuckDBPyConnection, name: str, roots: Iterable[str], edges_table: str
) -> None:
    """Materialize the closure as TEMP TABLE `name`(cls) from `edges_table`(child, parent).

    The same walk as `closure`, as a recursive CTE so a multi-million-edge graph stays in
    DuckDB. UNION (not UNION ALL) drops repeats, which also terminates cycles.
    """
    con.execute("CREATE OR REPLACE TEMP TABLE _roots(cls VARCHAR)")
    con.executemany("INSERT INTO _roots VALUES (?)", [(r,) for r in sorted(set(roots))])
    con.execute(
        f"""
        CREATE OR REPLACE TEMP TABLE {name} AS
        WITH RECURSIVE c(cls) AS (
          SELECT cls FROM _roots
          UNION
          SELECT e.child FROM {edges_table} e JOIN c ON e.parent = c.cls
        )
        SELECT cls FROM c
        """
    )
    con.execute("DROP TABLE _roots")
