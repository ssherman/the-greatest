from wikidata.pipeline.config import KeptConfig


def test_load_returns_the_kept_roots():
    config = KeptConfig.load()
    assert config.work_roots == frozenset(
        [
            "Q7725634",
            "Q47461344",
            "Q571",
            "Q8261",
            "Q5185279",
            "Q25379",
            "Q35760",
            "Q49084",
            "Q1279564",
            "Q12106333",
            "Q725377",
            "Q8274",
            "Q1004",
            "Q7725310",
        ]
    )
    assert config.edition_type == "Q3331189"
    assert config.person_types == frozenset({"Q5", "Q61002", "Q16017119", "Q21070568"})
    assert config.excluded_roots == frozenset({"Q13442814"})
    assert config.reverse_links == frozenset({"P50", "P800"})
    assert config.label_languages == ("en", "mul")


def test_external_ids_map_to_normalizers():
    config = KeptConfig.load()
    assert config.external_ids["P212"] == "isbn"
    assert config.external_ids["P957"] == "isbn"
    assert config.external_ids["P213"] == "strip_spaces"
    assert config.external_ids["P214"] == "exact"


def test_statement_properties_include_every_external_id_property():
    config = KeptConfig.load()
    assert set(config.external_ids) <= config.statement_properties
    assert {"P31", "P279", "P7937", "P50", "P495", "P297"} <= config.statement_properties
    assert "P18" not in config.statement_properties
