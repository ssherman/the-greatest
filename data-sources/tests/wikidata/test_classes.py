import duckdb

from wikidata.pipeline.classes import closure, closure_table


def _edges(slimmed):
    return [(q, parent) for q, s in slimmed.items() for parent in s.subclass_of]


def test_two_hop_chain_is_in_the_closure(slimmed, config):
    classes = closure(_edges(slimmed), config.work_roots)
    assert {"Q900007", "Q900004", "Q7725634"} <= classes


def test_excluded_root_is_its_own_closure(slimmed, config):
    assert closure(_edges(slimmed), config.excluded_roots) == {"Q13442814"}
    assert "Q13442814" not in closure(_edges(slimmed), config.work_roots)


def test_unrelated_classes_are_not_in_the_closure(slimmed, config):
    assert "Q5" not in closure(_edges(slimmed), config.work_roots)


def test_closure_survives_a_cycle():
    assert closure([("A", "B"), ("B", "A"), ("C", "B")], ["B"]) == {"A", "B", "C"}


def test_sql_closure_matches_python_closure(slimmed, config):
    edges = _edges(slimmed)
    con = duckdb.connect()
    con.execute("CREATE TABLE edges(child VARCHAR, parent VARCHAR)")
    con.executemany("INSERT INTO edges VALUES (?, ?)", edges)
    closure_table(con, "work_classes", config.work_roots, "edges")
    from_sql = {r[0] for r in con.execute("SELECT cls FROM work_classes").fetchall()}
    assert from_sql == closure(edges, config.work_roots)
