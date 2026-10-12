"""Read the seek table a zstd *seekable* file carries in its last frame.

The dump is 277,369 independent zstd frames of ~10.5 MB followed by one
skippable frame listing every frame's compressed and decompressed size. With
that table a worker can decompress any frame on its own, which is what makes
the build parallel and a lookup by position cheap. Frames are decoded one at a
time on purpose: a streaming decoder that hits a read error is left in an
inconsistent state and then reports "data corruption" (measured 2026-10-10).
"""

import struct
from dataclasses import dataclass
from pathlib import Path

SEEKABLE_MAGIC = 0x8F92EAB1
FOOTER_SIZE = 9  # <I number_of_frames> <B descriptor> <I magic>
CHECKSUM_FLAG = 0x80


@dataclass(frozen=True)
class Frame:
    index: int
    offset: int
    compressed_size: int
    decompressed_size: int


def read_seek_table(path: Path) -> list[Frame]:
    size = path.stat().st_size
    with path.open("rb") as fh:
        fh.seek(size - FOOTER_SIZE)
        n_frames, descriptor, magic = struct.unpack("<IBI", fh.read(FOOTER_SIZE))
        if magic != SEEKABLE_MAGIC:
            raise ValueError(f"{path} is not a zstd seekable file (no seek table footer)")
        entry_size = 12 if descriptor & CHECKSUM_FLAG else 8
        fh.seek(size - FOOTER_SIZE - n_frames * entry_size)
        table = fh.read(n_frames * entry_size)
    frames: list[Frame] = []
    offset = 0
    for index in range(n_frames):
        compressed, decompressed = struct.unpack_from("<II", table, index * entry_size)
        frames.append(Frame(index, offset, compressed, decompressed))
        offset += compressed
    return frames


def frame_ranges(n_frames: int, workers: int) -> list[tuple[int, int]]:
    """Contiguous [start, end) frame ranges, one per worker, never empty."""
    workers = max(1, min(workers, n_frames))
    bounds = [n_frames * i // workers for i in range(workers + 1)]
    return [(bounds[i], bounds[i + 1]) for i in range(workers)]
