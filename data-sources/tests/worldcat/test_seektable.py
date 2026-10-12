from pathlib import Path

import pytest
import zstandard

from tests.fixtures.worldcat.seekable import write_seekable
from worldcat.pipeline.seektable import Frame, frame_ranges, read_seek_table


def test_reads_every_frame_with_offsets_that_chain(tmp_path: Path):
    path = tmp_path / "sample.jsonl.seekable.zst"
    lines = [b'{"n":%d}' % i for i in range(25)]
    assert write_seekable(lines, path, frame_lines=10) == 3

    frames = read_seek_table(path)

    assert [f.index for f in frames] == [0, 1, 2]
    assert frames[0].offset == 0
    assert frames[1].offset == frames[0].compressed_size
    assert frames[2].offset == frames[1].offset + frames[1].compressed_size
    with path.open("rb") as fh:
        fh.seek(frames[2].offset)
        raw = zstandard.ZstdDecompressor().decompress(
            fh.read(frames[2].compressed_size), max_output_size=frames[2].decompressed_size
        )
    assert raw == b'{"n":20}\n{"n":21}\n{"n":22}\n{"n":23}\n{"n":24}\n'


def test_a_plain_zstd_file_is_refused(tmp_path: Path):
    path = tmp_path / "plain.zst"
    path.write_bytes(zstandard.ZstdCompressor().compress(b"hello\n"))
    with pytest.raises(ValueError, match="seekable"):
        read_seek_table(path)


def test_frame_ranges_cover_every_frame_once_in_order():
    ranges = frame_ranges(10, 3)
    assert ranges == [(0, 3), (3, 6), (6, 10)]
    assert frame_ranges(2, 8) == [(0, 1), (1, 2)]


def test_frame_is_a_plain_record():
    frame = Frame(index=0, offset=0, compressed_size=5, decompressed_size=9)
    assert frame.decompressed_size == 9
