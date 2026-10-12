"""Stage 1: read the dump once, keep what the artifact needs, write Parquet shards.

Each worker owns a contiguous range of frames, decodes one frame at a time,
carries the partial last line into the next frame, and drops a line with a
byte-level pre-filter BEFORE parsing JSON (most of the 2 billion lines are
not-found stubs, HTML, or non-Book records). Kept lines are reduced to the
shard columns and flushed to Parquet through DuckDB every `batch_size` rows.
A worker keeps no state that grows with the file: a per-worker set of OCLC
numbers exhausted a 45 GB machine on the spike.
"""

import errno
import json
import multiprocessing as mp
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

import duckdb
import zstandard

from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.seektable import Frame, frame_ranges, read_seek_table

SHARD_COLUMNS: dict[str, str] = {
    "kind": "VARCHAR",  # record | redirect | holdings
    "oclc": "BIGINT",
    "type": "VARCHAR",
    "pass": "VARCHAR",
    "pass_index": "BIGINT",
    "title": "VARCHAR",
    "subtitle": "VARCHAR",
    "creator": "VARCHAR",
    "contributors": "VARCHAR[]",
    "year": "INTEGER",
    "publication_date_raw": "VARCHAR",
    "publisher": "VARCHAR",
    "publication_place": "VARCHAR",
    "cataloging_language": "VARCHAR",
    "specific_format": "VARCHAR",
    "edition_statement": "VARCHAR",
    "physical_description": "VARCHAR",
    "series": "VARCHAR",
    "genre": "VARCHAR",
    "subjects": "VARCHAR[]",
    "isbns_raw": "VARCHAR[]",
    "merged_oclc": "BIGINT[]",
    "other_format_oclc": "BIGINT[]",
    "total_editions": "INTEGER",
    "summary": "VARCHAR",
    "redirect_to": "BIGINT",
    "total_holding_count": "INTEGER",
    "holdings_total_editions": "INTEGER",
}

_RECORD_TYPES = (b'"type":"title_json"', b'"type":"briefrecords_json"')
_REDIRECT = b'"type":"redirect_title_json"'
_HOLDINGS = b'"type":"search_holdings_summary_all_editions"'
_BOOK = b'"generalFormat":"Book"'
_HAS_ISBN = b'"isbns":["'
_YEAR = re.compile(r"\d{4}")
_INT = re.compile(r"\d+")


def keep(line: bytes) -> bool:
    if _REDIRECT in line or _HOLDINGS in line:
        return True
    return any(t in line for t in _RECORD_TYPES) and _BOOK in line and _HAS_ISBN in line


def _pass(meta: dict) -> tuple[str, int | None]:
    """('w2', 315408380) from 'w2/v7/3154/315408380'; a tar member path such as
    'x/2025-01-01_02.tar/9' gives its member number; a range query gives None."""
    names = meta.get("from_filenames") or []
    if not names:
        return "unknown", None
    parts = str(names[0]).split("/")
    last = parts[-1]
    return parts[0], (int(last) if last.isdigit() else None)


def _int(value) -> int | None:
    if value is None:
        return None
    m = _INT.search(str(value))
    return int(m.group()) if m else None


def _year(value) -> int | None:
    if value is None:
        return None
    m = _YEAR.search(str(value))
    return int(m.group()) if m else None


def _text(value) -> str | None:
    if isinstance(value, dict):
        value = value.get("text")
    return value if isinstance(value, str) and value else None


def _subjects(record: dict) -> list[str]:
    out = []
    for item in record.get("subjectsText") or record.get("subjects") or []:
        text = item if isinstance(item, str) else _text(item)
        if text:
            out.append(text)
    return out


def _contributors(record: dict) -> list[str]:
    out = []
    for c in record.get("contributors") or []:
        name = " ".join(p for p in (_text(c.get("firstName")), _text(c.get("secondName"))) if p)
        if name:
            out.append(name)
    return out


def _oclc_list(value) -> list[int]:
    out = []
    for item in value or []:
        number = _int(item.get("oclcNumber") if isinstance(item, dict) else item)
        if number is not None:
            out.append(number)
    return out


def reduce(row: dict) -> dict | None:
    meta = row.get("metadata") or {}
    kind = meta.get("type")
    oclc = _int(meta.get("oclc_number"))
    if oclc is None:
        return None
    record = meta.get("record") or {}
    pass_name, pass_index = _pass(meta)
    out: dict = dict.fromkeys(SHARD_COLUMNS)
    out["oclc"], out["type"], out["pass"], out["pass_index"] = oclc, kind, pass_name, pass_index
    if kind == "redirect_title_json":
        out["kind"] = "redirect"
        out["redirect_to"] = _int(record.get("redirected_oclc_number"))
        return out if out["redirect_to"] is not None else None
    if kind == "search_holdings_summary_all_editions":
        out["kind"] = "holdings"
        out["total_holding_count"] = _int(record.get("total_holding_count"))
        out["holdings_total_editions"] = _int(record.get("total_editions"))
        return out
    if kind not in ("title_json", "briefrecords_json"):
        return None
    # keep() is a byte match, so a nested otherFormats[].generalFormat or an
    # isbns array elsewhere in the line can satisfy it; check the top level here.
    isbns = record.get("isbns")
    if record.get("generalFormat") != "Book" or not isinstance(isbns, list) or not isbns:
        return None
    out["kind"] = "record"
    out["title"] = _text(record.get("title")) or _text(record.get("titleInfo"))
    out["subtitle"] = _text(record.get("subtitle"))
    out["creator"] = _text(record.get("creator"))
    out["contributors"] = _contributors(record)
    out["year"] = _year(
        record.get("machineReadableDate") or record.get("publicationDate") or record.get("date")
    )
    out["publication_date_raw"] = _text(record.get("publicationDate") or record.get("date"))
    out["publisher"] = _text(record.get("publisher") or record.get("publisherName"))
    out["publication_place"] = _text(record.get("publicationPlace"))
    out["cataloging_language"] = _text(record.get("catalogingLanguage") or record.get("language"))
    out["specific_format"] = _text(record.get("specificFormat"))
    out["edition_statement"] = _text(record.get("edition"))
    out["physical_description"] = _text(record.get("physicalDescription"))
    out["series"] = _text(record.get("series"))
    out["genre"] = _text(record.get("genre"))
    out["subjects"] = _subjects(record)
    out["isbns_raw"] = [str(i) for i in (record.get("isbns") or []) if i]
    out["merged_oclc"] = _oclc_list(record.get("mergedOclcNumbers"))
    out["other_format_oclc"] = _oclc_list(record.get("otherFormats"))
    out["total_editions"] = _int(record.get("totalEditions"))
    out["summary"] = _text(record.get("summary"))
    return out


@dataclass
class ExtractStats:
    worker: int
    lines: int = 0
    kept: int = 0
    shards: int = 0
    bad_frames: list[tuple[int, str]] = field(default_factory=list)


class ShardWriter:
    """Buffers reduced rows and writes each batch as one Parquet file via DuckDB
    (no pyarrow in this environment, so rows go through a temp JSONL file)."""

    def __init__(self, paths: WorldcatPaths, worker: int, batch_size: int) -> None:
        self.paths, self.worker, self.batch_size = paths, worker, batch_size
        self.rows: list[dict] = []
        self.index = 0
        self.con = duckdb.connect()

    def add(self, row: dict) -> None:
        self.rows.append(row)
        if len(self.rows) >= self.batch_size:
            self.flush()

    def flush(self) -> None:
        if not self.rows:
            return
        tmp = self.paths.tmp_dir / f"shard_{self.worker:03d}_{self.index:05d}.jsonl"
        with tmp.open("w", encoding="utf-8") as fh:
            for row in self.rows:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        columns = ", ".join(f"'{name}': '{sql_type}'" for name, sql_type in SHARD_COLUMNS.items())
        target = self.paths.shard(self.worker, self.index)
        self.con.execute(
            f"COPY (SELECT * FROM read_json('{tmp}', format='newline_delimited', "
            f"columns={{{columns}}})) TO '{target}' (FORMAT parquet, COMPRESSION zstd)"
        )
        tmp.unlink()
        self.rows = []
        self.index += 1

    def close(self) -> int:
        self.flush()
        self.con.close()
        return self.index


def _read_frame(fh, frame: Frame, dctx: zstandard.ZstdDecompressor) -> bytes:
    for attempt in range(30):
        try:
            fh.seek(frame.offset)
            blob = fh.read(frame.compressed_size)
            if len(blob) != frame.compressed_size:
                raise OSError(errno.EIO, "short read")
            return dctx.decompress(blob, max_output_size=frame.decompressed_size)
        except OSError as exc:
            # WSL's drvfs returns ENOMEM under concurrent large reads: back off and retry.
            if exc.errno not in (errno.ENOMEM, errno.EIO) or attempt == 29:
                raise
            time.sleep(0.5 * (attempt + 1))
    raise AssertionError("unreachable")


def _ends_on_newline(fh, frame: Frame, dctx: zstandard.ZstdDecompressor) -> bool:
    try:
        return _read_frame(fh, frame, dctx).endswith(b"\n")
    except (zstandard.ZstdError, OSError):
        return False


def _finish_line(fh, frames: list[Frame], index: int, dctx: zstandard.ZstdDecompressor) -> bytes:
    """The rest of a line that runs past this worker's last frame: everything from
    frame `index` up to (not including) the first newline. A line may span several
    frames; an unreadable frame ends the search with what was gathered."""
    out = b""
    for j in range(index, len(frames)):
        try:
            raw = _read_frame(fh, frames[j], dctx)
        except (zstandard.ZstdError, OSError):
            return out
        newline = raw.find(b"\n")
        if newline >= 0:
            return out + raw[:newline]
        out += raw
    return out


def _consume(line: bytes, writer: ShardWriter, stats: ExtractStats) -> None:
    stats.lines += 1
    if not keep(line):
        return
    try:
        row = reduce(json.loads(line))
    except ValueError:
        return
    if row is not None:
        writer.add(row)
        stats.kept += 1


def extract_range(
    source: Path,
    paths: WorldcatPaths,
    worker: int,
    start: int,
    end: int,
    *,
    batch_size: int = 50_000,
) -> ExtractStats:
    frames = read_seek_table(source)
    stats = ExtractStats(worker=worker)
    writer = ShardWriter(paths, worker, batch_size)
    dctx = zstandard.ZstdDecompressor()
    progress = paths.staging_dir / f"progress_{worker:03d}.txt"
    started = time.time()
    carry = b""
    with source.open("rb") as fh:
        # A line can straddle two workers' ranges. The earlier worker finishes it
        # (below), so this one drops the fragment its first frame begins with --
        # unless the previous frame ended exactly on a newline.
        skipping = start > 0 and not _ends_on_newline(fh, frames[start - 1], dctx)
        for i in range(start, end):
            try:
                raw = _read_frame(fh, frames[i], dctx)
            except (zstandard.ZstdError, OSError) as exc:
                stats.bad_frames.append((i, str(exc)[:100]))
                carry = b""
                continue
            if skipping:
                newline = raw.find(b"\n")
                if newline < 0:
                    continue
                raw, skipping = raw[newline + 1 :], False
            parts = (carry + raw).split(b"\n")
            carry = parts.pop()
            for line in parts:
                if line:
                    _consume(line, writer, stats)
            if (i - start) % 500 == 0:
                progress.write_text(
                    f"{(i - start + 1) / (end - start) * 100:.1f}% lines={stats.lines} "
                    f"kept={stats.kept} bad={len(stats.bad_frames)} "
                    f"elapsed={time.time() - started:.0f}s\n"
                )
        if carry and end < len(frames):
            carry += _finish_line(fh, frames, end, dctx)
    if carry.strip():
        _consume(carry, writer, stats)
    stats.shards = writer.close()
    progress.write_text(
        f"100.0% lines={stats.lines} kept={stats.kept} bad={len(stats.bad_frames)} done\n"
    )
    return stats


def _work(args: tuple) -> ExtractStats:
    source, paths, worker, start, end, batch_size = args
    return extract_range(source, paths, worker, start, end, batch_size=batch_size)


def extract_all(
    source: Path, paths: WorldcatPaths, *, workers: int, batch_size: int = 50_000
) -> list[ExtractStats]:
    n_frames = len(read_seek_table(source))
    jobs = [
        (source, paths, w, start, end, batch_size)
        for w, (start, end) in enumerate(frame_ranges(n_frames, workers))
    ]
    if len(jobs) == 1:
        return [_work(jobs[0])]
    with mp.get_context("spawn").Pool(len(jobs)) as pool:
        return list(pool.imap_unordered(_work, jobs))
