"""Write a zstd *seekable* file the way the Anna's Archive dump is written:
one standard zstd frame per chunk, then a skippable frame holding the seek
table (zstd's seekable format, magic 0x8F92EAB1, no checksums)."""

import struct
from pathlib import Path

import zstandard

SEEKABLE_MAGIC = 0x8F92EAB1
SKIPPABLE_MAGIC = 0x184D2A5E


def write_seekable(lines: list[bytes], path: Path, *, frame_lines: int) -> int:
    compressor = zstandard.ZstdCompressor(level=3)
    entries: list[tuple[int, int]] = []
    with path.open("wb") as out:
        for start in range(0, len(lines), frame_lines):
            raw = b"".join(line + b"\n" for line in lines[start : start + frame_lines])
            frame = compressor.compress(raw)
            out.write(frame)
            entries.append((len(frame), len(raw)))
        table = b"".join(struct.pack("<II", c, d) for c, d in entries)
        footer = struct.pack("<IBI", len(entries), 0, SEEKABLE_MAGIC)
        body = table + footer
        out.write(struct.pack("<II", SKIPPABLE_MAGIC, len(body)))
        out.write(body)
    return len(entries)
