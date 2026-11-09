"""Wikidata redirects from the MediaWiki SQL dumps (`redirect` and `page`).

Both files are MySQL extended INSERTs, in either form: ``INSERT INTO `t` VALUES (..),(..);`` on one
line, or (the real dumps) ``VALUES`` alone on its line then one tuple per line, `,`-terminated, the
last `;`. Parsed line by line with a field-level tuple tokenizer (quoted strings with
backslash escapes), never read whole.
"""

import gzip
import re
from collections.abc import Iterator
from pathlib import Path
from typing import IO

MAX_HOPS = 10

_FIELD = r"'(?:[^'\\]|\\.)*'|[^,()']*"
_TUPLE = re.compile(rf"\(((?:{_FIELD})(?:,(?:{_FIELD}))*)\)")
_ONE_FIELD = re.compile(r"'((?:[^'\\]|\\.)*)'|([^,']*)")
_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", "b": "\b", "Z": "\x1a"}
_QID = re.compile(r"Q(\d+)")


def _unescape(inner: str) -> str:
    if "\\" not in inner:
        return inner
    return re.sub(r"\\(.)", lambda m: _ESCAPES.get(m.group(1), m.group(1)), inner)


def _split(body: str) -> list[str | None]:
    fields: list[str | None] = []
    pos = 0
    while True:
        match = _ONE_FIELD.match(body, pos)
        quoted, bare = match.groups()
        if quoted is not None:
            fields.append(_unescape(quoted))
        else:
            fields.append(None if bare == "NULL" else bare)
        pos = match.end()
        if pos >= len(body):
            return fields
        pos += 1  # the comma


def _open(path: Path) -> IO[str]:
    if Path(path).suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace", newline="")
    return open(path, encoding="utf-8", errors="replace", newline="")


def iter_rows(path: Path, table: str) -> Iterator[list[str | None]]:
    """Every row of every ``INSERT INTO `table` `` statement, as a list of decoded fields."""
    prefix = f"INSERT INTO `{table}` VALUES"
    inserting = False
    pending = ""  # the unfinished tail of a tuple that continues on the next line
    with _open(path) as handle:
        for line in handle:
            if line.startswith(prefix):
                inserting = True
                line = line[len(prefix) :]
                pending = ""
            elif not inserting:
                continue
            text = pending + line
            end = 0
            for match in _TUPLE.finditer(text):
                end = match.end()
                yield _split(match.group(1))
            pending = text[end:] if "(" in text[end:] else ""
            if line.rstrip().endswith(";") and not pending:
                inserting = False


def _qid_number(title: str | None) -> int | None:
    match = _QID.fullmatch(title or "")
    return int(match.group(1)) if match else None


def parse_redirects(redirect_sql: Path, page_sql: Path) -> Iterator[tuple[str, str]]:
    """(from_qid, to_qid), main namespace only, resolved to the end of the chain.

    A chain longer than MAX_HOPS or one that loops has no end, so it yields nothing. Redirects
    are held as ints (a few million), not strings.
    """
    # page_id -> qid number: redirect pages in namespace 0 only.
    redirect_pages: dict[int, int] = {}
    for row in iter_rows(page_sql, "page"):
        if row[1] == "0" and row[3] == "1":
            number = _qid_number(row[2])
            if number is not None:
                redirect_pages[int(row[0])] = number

    step: dict[int, int] = {}
    for row in iter_rows(redirect_sql, "redirect"):
        if row[1] != "0" or row[3]:  # target namespace; interwiki
            continue
        source = redirect_pages.get(int(row[0]))
        target = _qid_number(row[2])
        if source is not None and target is not None:
            step[source] = target
    del redirect_pages

    for source in sorted(step):
        end = source
        for _ in range(MAX_HOPS):
            following = step.get(end)
            if following is None:
                break
            end = following
        if end in step:  # still moving after MAX_HOPS: a loop, or too long
            continue
        yield f"Q{source}", f"Q{end}"
