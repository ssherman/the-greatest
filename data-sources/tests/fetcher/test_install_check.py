import pytest

from fetcher.install_check import expected_build, missing_libraries


@pytest.mark.parametrize(
    ("spec", "build"),
    [
        ("official/stable/152.0.4-beta.30", "152.0.4-beta.30"),
        ("official/152.0.4-beta.30", "152.0.4-beta.30"),
        ("152.0.4-beta.30", "152.0.4-beta.30"),
        ("official/stable/v152.0.4-beta.30/", "152.0.4-beta.30"),
    ],
)
def test_expected_build_drops_the_repo_and_channel(spec, build):
    assert expected_build(spec) == build


def test_missing_libraries_lists_only_what_ldd_could_not_find():
    output = (
        "\tlinux-vdso.so.1 (0x00007ffd)\n"
        "\tlibgtk-3.so.0 => /lib/x86_64-linux-gnu/libgtk-3.so.0 (0x00007f)\n"
        "\tlibdbus-glib-1.so.2 => not found\n"
        "\tlibXt.so.6 => not found\n"
    )
    assert missing_libraries(output) == ["libdbus-glib-1.so.2", "libXt.so.6"]


def test_missing_libraries_is_empty_when_everything_resolves():
    assert missing_libraries("\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f)\n") == []
