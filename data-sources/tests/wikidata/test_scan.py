from pathlib import Path

from wikidata.pipeline.scan import iter_entities

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "wikidata"
PLAIN = FIXTURES / "mini-all.json"
GZIPPED = FIXTURES / "mini-all.json.gz"


def test_iter_entities_reads_gzip_and_plain():
    plain = [e["id"] for e in iter_entities(PLAIN)]
    gzipped = [e["id"] for e in iter_entities(GZIPPED)]
    assert len(plain) == 44
    assert plain == gzipped


def test_slim_keeps_rank_snaktype_and_datavalue(slimmed):
    author = slimmed["Q900006"]
    born = author.claims["P569"]
    assert born[0]["rank"] == "preferred"
    assert born[0]["mainsnak"]["datavalue"]["value"]["time"] == "+1950-01-01T00:00:00Z"
    assert born[1]["rank"] == "deprecated"
    died = author.claims["P570"][0]
    assert died["mainsnak"]["snaktype"] == "somevalue"
    assert "datavalue" not in died["mainsnak"]


def test_slim_drops_qualifiers_and_unlisted_properties(slimmed):
    author = slimmed["Q900006"]
    assert "P18" not in author.claims
    assert set(author.claims["P27"][0]) == {"rank", "mainsnak"}
    assert set(author.claims["P27"][0]["mainsnak"]) <= {"snaktype", "datavalue"}
    edition = slimmed["Q900001"]
    assert set(edition.claims["P577"][0]) == {"rank", "mainsnak"}
    assert edition.claims["P212"][0]["mainsnak"]["datavalue"]["value"] == "978-0-385-47454-2"


def test_slim_extracts_type_subclass_and_form_ids(slimmed, config):
    assert slimmed["Q900005"].types == ["Q900004"]
    assert slimmed["Q900004"].subclass_of == ["Q900007"]
    assert slimmed["Q900007"].subclass_of == ["Q7725634"]
    assert {"Q900004", "Q900007"}.isdisjoint(config.work_roots)
    assert slimmed["Q622400"].forms == ["Q8261"]


def test_slim_limits_labels_to_configured_languages(slimmed):
    thing = slimmed["Q622400"]
    assert set(thing.labels) <= {"en", "mul"}
    assert thing.labels["en"]["value"]
    assert set(slimmed["Q900006"].aliases) == {"en"}


def test_slim_all_names_spans_languages(slimmed):
    tolstoy = slimmed["Q7243"]
    assert "Лев Толстой" in tolstoy.all_names
    assert tolstoy.labels == {}
    author = slimmed["Q900006"]
    assert {"Ada Example", "A. Example", "Ada Beispiel"} <= set(author.all_names)
    assert len(author.all_names) == len(set(author.all_names))


def test_slim_counts_sitelinks_and_keeps_enwiki(slimmed):
    author = slimmed["Q900006"]
    assert author.sitelink_count == 4
    assert author.enwiki_title == "Ada Example"
    assert slimmed["Q900005"].sitelink_count == 0
    assert slimmed["Q900005"].enwiki_title is None
