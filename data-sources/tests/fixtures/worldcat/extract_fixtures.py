"""Regenerate sample.jsonl from the real dump. Run by hand; the output is committed.

    uv run python tests/fixtures/worldcat/extract_fixtures.py \
        --source "/mnt/e/annas archive worldcat/annas_archive_meta__aacid__worldcat__\
20250804T000000Z--20250804T000000Z.jsonl.seekable.zst"

Selection is by explicit OCLC number, never "the first N lines": every line the
dump holds for each seeded number (all passes, all types) is kept, in file order,
then the synthetic rows below are appended. The real file is sorted by 13-digit
zero-padded OCLC number, so one number is a binary search over frame first keys.
"""

import argparse
import json
import re
import sys
from pathlib import Path

import zstandard

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "src"))
from worldcat.pipeline.seektable import read_seek_table  # noqa: E402

OUT = Path(__file__).parent / "sample.jsonl"
R_OCLC = re.compile(rb'"oclc_number":"(\d{13})"')

# Each seed is there for a reason; keep the comment when you add one.
SEED_OCLCS = [
    1,  # the first record: Book, no ISBN, French + English subjects, four scrape passes
    1055766559,  # Atomic Habits: canary; three title passes, an editions-endpoint brief, holdings
    1000415078,  # The Hobbit: canary; one title + one brief, "Fiction" genre
    1002380292,  # A Game of Thrones: canary; six ISBNs on one record
    1003236695,  # redirect_title_json -> 37975719 (canary)
    37975719,  # the redirect target
    123177986,  # The 48 Laws of Power as AudioBook/CD: a NON-Book format that must be dropped
    1010924379,  # It Ends With Us (Polish): "Powieść" genre, pol cataloguing language
    676190796,  # a brief record from an ISBN range query (pass "range_query")
    11280578,  # Animal Farm (Danish): a Book title record with NO ISBN
]


def _title(oclc: str, pass_name: str, **record) -> dict:
    base = {
        "oclcNumber": oclc.lstrip("0"),
        "generalFormat": "Book",
        "specificFormat": "PrintBook",
        "contributors": [],
        "otherFormats": [],
        "publisher": None,
        "publicationPlace": None,
        "publicationDate": None,
        "edition": None,
        "physicalDescription": None,
        "series": None,
        "summary": None,
        "mergedOclcNumbers": None,
        "catalogingLanguage": "eng",
        "totalEditions": 1,
    }
    base.update(record)
    return {
        "metadata": {
            "oclc_number": oclc,
            "type": "title_json",
            "from_filenames": [pass_name],
            "record": base,
        }
    }


def _tag(row: dict, tag: str, aacid: str) -> dict:
    row["aacid"] = f"aacid__worldcat__synthetic__{aacid}"
    row["metadata"]["_synthetic"] = tag
    return row


def _redirect(oclc: str, to: int, tag: str, aacid: str) -> dict:
    return _tag(
        {
            "metadata": {
                "oclc_number": oclc,
                "type": "redirect_title_json",
                "from_filenames": [f"w2/v7/0001/{aacid}"],
                "record": {"redirected_oclc_number": to},
            }
        },
        tag,
        aacid,
    )


SYNTHETIC = [
    # A title record whose only ISBN fails its check digit: `isbns` must not index it.
    _tag(
        _title(
            "0009000000001",
            "w2/v7/0001/1",
            title="Synthetic bad ISBN",
            creator="Nobody",
            isbns=["9780000000001"],
            genre="Fiction",
            subjectsText=["Fiction"],
            machineReadableDate="2001",
        ),
        "bad_checksum",
        "badisbn",
    ),
    # The Hobbit again in an OLDER pass with a different genre: the newest pass must win.
    _tag(
        _title(
            "0001000415078",
            "2023_04_v3/1000/1000415078",
            title="The Hobbit (older pass)",
            creator="J. R. R. Tolkien",
            isbns=["0395476909", "9780395476901"],
            genre="STALE GENRE",
            subjectsText=["Fiction"],
            machineReadableDate="1989",
        ),
        "older_pass",
        "olderpass",
    ),
    # A redirect chain A -> B -> Atomic Habits, and a cycle D <-> E.
    _redirect("0009000000010", 9000000011, "chain", "chain1"),
    _redirect("0009000000011", 1055766559, "chain", "chain2"),
    _redirect("0009000000020", 9000000021, "cycle", "cycle1"),
    _redirect("0009000000021", 9000000020, "cycle", "cycle2"),
    # A second, later holdings summary for Atomic Habits: the higher pass index must win.
    _tag(
        {
            "metadata": {
                "oclc_number": "0001055766559",
                "type": "search_holdings_summary_all_editions",
                "from_filenames": [
                    "search_holdings_summary_all_editions/1055766559/index/99999999"
                ],
                "record": {
                    "oclc_number": 1055766559,
                    "total_holding_count": 4000,
                    "total_editions": 25,
                },
            }
        },
        "later_holdings",
        "holdings2",
    ),
    # A brief record whose subjects are dicts, as some search responses return them.
    _tag(
        {
            "metadata": {
                "oclc_number": "0009000000030",
                "type": "briefrecords_json",
                "from_filenames": ["range_query/9780000###"],
                "record": {
                    "oclcNumber": "9000000030",
                    "title": "Synthetic dict subjects",
                    "creator": "Nobody",
                    "generalFormat": "Book",
                    "specificFormat": "PrintBook",
                    "isbns": ["9780306406157"],
                    "subjects": [{"text": "Science fiction"}, {"text": "Robots"}],
                    "machineReadableDate": "1999",
                    "catalogingLanguage": "eng",
                    "publisher": "Nobody Press",
                },
            }
        },
        "dict_subjects",
        "dictsubjects",
    ),
]


def lines_for(path: Path, frames, oclc: int) -> list[bytes]:
    key = str(oclc).zfill(13).encode()
    dctx = zstandard.ZstdDecompressor()
    cache: dict[int, bytes] = {}

    def frame(i: int) -> bytes:
        if i not in cache:
            f = frames[i]
            with path.open("rb") as fh:
                fh.seek(f.offset)
                cache[i] = dctx.decompress(
                    fh.read(f.compressed_size), max_output_size=f.decompressed_size
                )
        return cache[i]

    def first_key(i: int) -> bytes | None:
        for ln in frame(i).split(b"\n")[1:3]:
            m = R_OCLC.search(ln)
            if m:
                return m.group(1)
        return None

    # Last frame whose first key is strictly below `key`: lines for `key` may begin at the
    # end of that frame, so it is scanned too.
    lo, hi = 0, len(frames) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        k = first_key(mid)
        if k is not None and k < key:
            lo = mid
        else:
            hi = mid - 1
    out = []
    for i in range(lo, len(frames)):
        k = first_key(i)
        if i > lo and k is not None and k > key:
            break
        for ln in frame(i).split(b"\n"):
            if b'"oclc_number":"' + key + b'"' in ln:
                try:
                    json.loads(ln)
                except ValueError:
                    continue  # cut by a frame boundary; its other half is in the neighbour
                out.append(ln)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, required=True)
    args = ap.parse_args()
    frames = read_seek_table(args.source)
    kept: list[bytes] = []
    for oclc in SEED_OCLCS:
        found = lines_for(args.source, frames, oclc)
        if not found:
            raise SystemExit(f"OCLC {oclc} not found; the seed list is wrong")
        kept.extend(found)
    kept.extend(
        json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode() for row in SYNTHETIC
    )
    OUT.write_bytes(b"\n".join(kept) + b"\n")
    print(f"{OUT.name}: {len(kept)} lines, {OUT.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
