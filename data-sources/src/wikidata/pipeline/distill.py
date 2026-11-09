"""Distill the Wikidata JSON dump into the artifact's lookup tables.

Pass 1 streams the dump once and spills bounded batches of per-entity rows into Parquet shards
under `paths.shards_dir`; nothing per-entity survives in Python beyond one batch. Pass 2 is
DuckDB over those shards: the class closure, the kept set, then the six tables.

Everything lands in `paths.staging_dir`. Promoting it to `version_dir` is the caller's job,
after the gates.
"""

import multiprocessing
import shutil
import threading
from collections.abc import Iterable, Iterator
from pathlib import Path

import duckdb
import orjson

from wikidata.pipeline.classes import closure_table
from wikidata.pipeline.config import KeptConfig
from wikidata.pipeline.normalize import normalize_external_id, normalize_name
from wikidata.pipeline.paths import TABLES, WikidataPaths
from wikidata.pipeline.redirects import parse_redirects
from wikidata.pipeline.scan import SlimEntity, slim
from wikidata.pipeline.scan import _open as open_dump

# A batch of raw lines is cut at whichever limit comes first. 32 MB keeps a worker's parsed
# batch to a few hundred MB and the full dump to tens of thousands of shards (one glob).
BATCH_LINES = 20_000
BATCH_BYTES = 32 * 1024 * 1024
# DuckDB rounds row groups to 2,048-row vectors, so 8,192 stays at or under the spec's 10,000.
ROW_GROUP = 8_192

_SHARD_COLUMNS = (
    "{qid: 'VARCHAR', label_en: 'VARCHAR', label_mul: 'VARCHAR', description_en: 'VARCHAR',"
    " types: 'VARCHAR[]', forms: 'VARCHAR[]', subclass_of: 'VARCHAR[]', targets: 'VARCHAR[]',"
    " labels: 'VARCHAR', descriptions: 'VARCHAR', aliases: 'VARCHAR', claims: 'VARCHAR',"
    " names: 'VARCHAR[]',"
    " ext_ids: 'STRUCT(property VARCHAR, value VARCHAR)[]',"
    " links: 'STRUCT(property VARCHAR, target VARCHAR)[]',"
    " enwiki_title: 'VARCHAR', sitelink_count: 'BIGINT'}"
)


def _live(statements: list[dict]) -> Iterable[dict]:
    return (s for s in statements if s.get("rank") != "deprecated")


def _value(statement: dict):
    return statement.get("mainsnak", {}).get("datavalue", {}).get("value")


def _item_targets(slimmed: SlimEntity, config: KeptConfig) -> list[str]:
    targets: dict[str, None] = {}
    for prop, statements in slimmed.claims.items():
        if prop not in config.statement_properties:
            continue
        for statement in _live(statements):
            value = _value(statement)
            if isinstance(value, dict) and str(value.get("id", "")).startswith("Q"):
                targets[value["id"]] = None
    return list(targets)


def _external_ids(slimmed: SlimEntity, config: KeptConfig) -> list[dict]:
    found: dict[tuple[str, str], None] = {}
    for prop, kind in config.external_ids.items():
        for statement in _live(slimmed.claims.get(prop, [])):
            value = _value(statement)
            if isinstance(value, str):
                normalized = normalize_external_id(kind, value)
                if normalized:
                    found[(prop, normalized)] = None
    return [{"property": p, "value": v} for p, v in found]


def _links(slimmed: SlimEntity, config: KeptConfig) -> list[dict]:
    found: dict[tuple[str, str], None] = {}
    for prop in config.reverse_links:
        for statement in _live(slimmed.claims.get(prop, [])):
            value = _value(statement)
            if isinstance(value, dict) and str(value.get("id", "")).startswith("Q"):
                found[(prop, value["id"])] = None
    return [{"property": p, "target": t} for p, t in found]


def _names(slimmed: SlimEntity, config: KeptConfig) -> list[str]:
    """Normalized names, for person-typed entities only (the one place a name index is used)."""
    if not config.person_types.intersection(slimmed.types):
        return []
    return sorted({n for n in map(normalize_name, slimmed.all_names) if n})


def _shard_row(slimmed: SlimEntity, config: KeptConfig) -> dict:
    def text(mapping: dict, lang: str) -> str | None:
        entry = mapping.get(lang)
        return entry["value"] if entry else None

    return {
        "qid": slimmed.qid,
        "label_en": text(slimmed.labels, "en"),
        "label_mul": text(slimmed.labels, "mul"),
        "description_en": text(slimmed.descriptions, "en"),
        "types": slimmed.types,
        "forms": slimmed.forms,
        "subclass_of": slimmed.subclass_of,
        "targets": _item_targets(slimmed, config),
        "labels": orjson.dumps(slimmed.labels).decode(),
        "descriptions": orjson.dumps(slimmed.descriptions).decode(),
        "aliases": orjson.dumps(slimmed.aliases).decode(),
        "claims": orjson.dumps(slimmed.claims).decode(),
        "names": _names(slimmed, config),
        "ext_ids": _external_ids(slimmed, config),
        "links": _links(slimmed, config),
        "enwiki_title": slimmed.enwiki_title,
        "sitelink_count": slimmed.sitelink_count,
    }


_worker_config: KeptConfig | None = None
_worker_con: duckdb.DuckDBPyConnection | None = None


def _init_worker(config: KeptConfig) -> None:
    """Pool initializer: module-level and picklable, so it works under spawn and forkserver."""
    global _worker_config, _worker_con
    _worker_config = config
    _worker_con = duckdb.connect(database=":memory:")
    _worker_con.execute("SET threads=1")
    _worker_con.execute("SET memory_limit='512MB'")


def _process_batch(task: tuple[int, list[bytes], str]) -> int:
    """Parse one batch of raw dump lines and write its shard; returns the rows written."""
    number, lines, shards_dir = task
    rows = []
    for line in lines:
        entity = orjson.loads(line)
        if str(entity.get("id", "")).startswith("Q"):
            rows.append(orjson.dumps(_shard_row(slim(entity, _worker_config), _worker_config)))
    if not rows:
        return 0
    source = Path(shards_dir) / f"batch_{number:07d}.ndjson"
    source.write_bytes(b"\n".join(rows) + b"\n")
    target = Path(shards_dir) / f"shard_{number:07d}.parquet"
    _worker_con.execute(
        f"COPY (SELECT * FROM read_json('{source}', format='newline_delimited',"
        f" columns={_SHARD_COLUMNS})) TO '{target}' (FORMAT parquet, COMPRESSION zstd)"
    )
    source.unlink()
    return len(rows)


def _raw_batches(dump: Path, threads: int) -> Iterator[list[bytes]]:
    """Slice the dump into batches of raw entity lines, without parsing them."""
    batch: list[bytes] = []
    size = 0
    with open_dump(dump, min(threads, 4)) as handle:
        for raw in handle:
            line = raw.strip()
            if line in (b"", b"[", b"]"):
                continue
            batch.append(line[:-1] if line.endswith(b",") else line)
            size += len(line)
            if len(batch) >= BATCH_LINES or size >= BATCH_BYTES:
                yield batch
                batch, size = [], 0
    if batch:
        yield batch


def _pass_one(dump: Path, paths: WikidataPaths, config: KeptConfig, threads: int) -> int:
    """The parent decompresses and slices lines; `threads - 1` workers (min 1) parse and write
    shards. In-flight batches are bounded, so memory stays at a few batches per worker."""
    workers = max(1, threads - 1)
    in_flight = threading.BoundedSemaphore(2 * workers)
    errors: list[BaseException] = []

    def done(_rows: int) -> None:
        in_flight.release()

    def failed(error: BaseException) -> None:
        errors.append(error)
        in_flight.release()

    context = multiprocessing.get_context("spawn")
    with context.Pool(workers, _init_worker, (config,)) as pool:
        for number, lines in enumerate(_raw_batches(dump, threads)):
            in_flight.acquire()
            if errors:
                break
            pool.apply_async(
                _process_batch,
                ((number, lines, str(paths.shards_dir)),),
                callback=done,
                error_callback=failed,
            )
        pool.close()
        pool.join()
    if errors:
        raise errors[0]
    return len(list(paths.shards_dir.glob("shard_*.parquet")))


def _copy(con: duckdb.DuckDBPyConnection, select: str, target: Path, row_group: int = ROW_GROUP):
    con.execute(
        f"COPY ({select}) TO '{target}'"
        f" (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {row_group})"
    )
    (rows,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
    return rows


def _sql_list(values: Iterable[str]) -> str:
    return "[" + ", ".join(f"'{v}'" for v in sorted(values)) + "]"


def _kept_set(con: duckdb.DuckDBPyConnection, config: KeptConfig) -> None:
    """TEMP TABLE kept(qid).

    Kept: typed (P31 or P7937) under the work roots or as the edition type, and not typed under
    an excluded root; or a person type; or the target of a statement property of one of those.
    """
    con.execute(
        "CREATE OR REPLACE TEMP TABLE edges AS "
        "SELECT qid AS child, unnest(subclass_of) AS parent FROM shards"
    )
    closure_table(con, "work_classes", config.work_roots, "edges")
    closure_table(con, "excluded_classes", config.excluded_roots, "edges")
    con.execute(
        "CREATE OR REPLACE TEMP TABLE typed AS "
        "SELECT qid, unnest(list_concat(types, forms)) AS cls FROM shards"
    )
    con.execute(
        f"""
        CREATE OR REPLACE TEMP TABLE core AS
        SELECT DISTINCT qid FROM typed
        WHERE (cls IN (SELECT cls FROM work_classes) OR cls = '{config.edition_type}')
          AND qid NOT IN (SELECT qid FROM typed WHERE cls IN (SELECT cls FROM excluded_classes))
        UNION
        SELECT qid FROM shards WHERE list_has_any(types, {_sql_list(config.person_types)})
        """
    )
    con.execute(
        """
        CREATE OR REPLACE TEMP TABLE kept AS
        SELECT qid FROM core
        UNION
        SELECT DISTINCT t.qid FROM (
          SELECT unnest(s.targets) AS qid FROM shards s JOIN core USING (qid)
        ) t JOIN shards USING (qid)
        """
    )


def _write_redirects_raw(redirect_sql: Path, page_sql: Path, raw: Path) -> None:
    with raw.open("wb") as out:
        for from_qid, to_qid in parse_redirects(redirect_sql, page_sql):
            out.write(orjson.dumps({"from_qid": from_qid, "to_qid": to_qid}) + b"\n")


def distill(
    dump: Path,
    redirect_sql: Path,
    page_sql: Path,
    paths: WikidataPaths,
    config: KeptConfig,
    *,
    memory_limit: str,
    threads: int,
) -> dict[str, int]:
    """Build every table into `paths.staging_dir`; returns table -> row count."""
    paths.ensure()
    if paths.shards_dir.exists():
        shutil.rmtree(paths.shards_dir)
    paths.shards_dir.mkdir(parents=True)

    con = duckdb.connect(database=":memory:")
    try:
        con.execute("SET preserve_insertion_order=false")
        con.execute(f"SET memory_limit='{memory_limit}'")
        con.execute(f"SET temp_directory='{paths.tmp_dir}'")
        con.execute(f"SET threads={int(threads)}")

        _pass_one(dump, paths, config, threads)
        raw_redirects = paths.shards_dir / "redirects.ndjson"
        _write_redirects_raw(redirect_sql, page_sql, raw_redirects)

        glob = paths.shards_dir / "shard_*.parquet"
        con.execute(f"CREATE OR REPLACE VIEW shards AS SELECT * FROM read_parquet('{glob}')")
        _kept_set(con, config)

        counts = {
            "items": _copy(
                con,
                """
                SELECT s.qid, s.label_en, s.label_mul, s.description_en, s.types, s.forms,
                       s.subclass_of, s.labels, s.descriptions, s.aliases, s.claims,
                       s.enwiki_title, s.sitelink_count
                FROM shards s JOIN kept USING (qid) ORDER BY s.qid
                """,
                paths.staged("items"),
            ),
            "labels": _copy(
                con,
                "SELECT qid, label_en, label_mul, description_en FROM shards ORDER BY qid",
                paths.staged("labels"),
                ROW_GROUP,
            ),
            "external_ids": _copy(
                con,
                """
                SELECT DISTINCT e.property AS property, e.value AS value, qid
                FROM (SELECT qid, unnest(ext_ids) AS e FROM shards)
                WHERE qid IN (SELECT qid FROM kept)
                ORDER BY property, value, qid
                """,
                paths.staged("external_ids"),
            ),
            "links": _copy(
                con,
                """
                SELECT DISTINCT l.property AS property, l.target AS target, qid AS source
                FROM (SELECT qid, unnest(links) AS l FROM shards)
                WHERE qid IN (SELECT qid FROM kept)
                ORDER BY property, target, source
                """,
                paths.staged("links"),
            ),
            "names": _copy(
                con,
                """
                SELECT DISTINCT name, qid
                FROM (SELECT qid, unnest(names) AS name FROM shards)
                WHERE qid IN (SELECT qid FROM kept) AND name <> ''
                ORDER BY name, qid
                """,
                paths.staged("names"),
            ),
            "redirects": _copy(
                con,
                f"""
                SELECT from_qid, to_qid
                FROM read_json('{raw_redirects}', format='newline_delimited',
                               columns={{from_qid: 'VARCHAR', to_qid: 'VARCHAR'}})
                WHERE to_qid IN (SELECT qid FROM kept)
                ORDER BY from_qid, to_qid
                """,
                paths.staged("redirects"),
                ROW_GROUP,
            ),
        }
        assert set(counts) == set(TABLES)
        return counts
    finally:
        con.close()
        shutil.rmtree(paths.shards_dir, ignore_errors=True)
