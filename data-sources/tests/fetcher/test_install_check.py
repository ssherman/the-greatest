import os
import subprocess

import pytest

from fetcher import install_check
from fetcher.install_check import expected_build, missing_libraries

PINNED_BUILD = "152.0.4-beta.31"


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


class _FakeRun:
    """A fake `subprocess.run` that always answers the same way and records every call."""

    def __init__(self, returncode, stdout, stderr):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.calls = []

    def __call__(self, cmd, capture_output=True, text=True, check=False, env=None):
        self.calls.append({"cmd": cmd, "env": env})
        return subprocess.CompletedProcess(
            cmd, self.returncode, stdout=self.stdout, stderr=self.stderr
        )


@pytest.fixture
def patch_camoufox(tmp_path, monkeypatch):
    """Wire main()'s camoufox imports to a fake install, with no real browser involved."""
    monkeypatch.setenv("CAMOUFOX_BROWSER", f"official/stable/{PINNED_BUILD}")

    browser_dir = tmp_path / "browser"
    browser_dir.mkdir()
    executable = browser_dir / "camoufox-bin"

    addons_dir = tmp_path / "addons"
    (addons_dir / "UBO").mkdir(parents=True)
    (addons_dir / "UBO" / "manifest.json").write_text("{}")

    monkeypatch.setattr(
        "camoufox.pkgman.camoufox_path", lambda download_if_missing=True: browser_dir
    )
    monkeypatch.setattr("camoufox.pkgman.launch_path", lambda browser_path=None: str(executable))
    monkeypatch.setattr("camoufox.pkgman.installed_verstr", lambda: PINNED_BUILD)
    monkeypatch.setattr("camoufox.addons.ADDONS_DIR", addons_dir)

    return browser_dir


def test_main_fails_when_ldd_fails(patch_camoufox, monkeypatch, capsys):
    # returncode 1 with EMPTY stdout: missing_libraries("") is [], so a version of
    # main() that forgot to check returncode and only looked at `missing` would
    # wrongly report success. That is exactly what this test must catch.
    fake_run = _FakeRun(1, "", "ldd: /x/libxul.so: No such file or directory")
    monkeypatch.setattr(install_check.subprocess, "run", fake_run)

    assert install_check.main() == 1

    err = capsys.readouterr().err
    assert "ldd failed on" in err
    assert "No such file or directory" in err


def test_main_fails_when_a_library_is_missing(patch_camoufox, monkeypatch, capsys):
    fake_run = _FakeRun(0, "\tlibX.so => not found\n", "")
    monkeypatch.setattr(install_check.subprocess, "run", fake_run)

    assert install_check.main() == 1

    err = capsys.readouterr().err
    assert "libX.so" in err


def test_main_succeeds_when_everything_resolves(patch_camoufox, monkeypatch):
    fake_run = _FakeRun(0, "\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f)\n", "")
    monkeypatch.setattr(install_check.subprocess, "run", fake_run)

    assert install_check.main() == 0


def test_ldd_env_appends_to_existing_ld_library_path(patch_camoufox, monkeypatch):
    monkeypatch.setenv("LD_LIBRARY_PATH", "/existing/path")
    fake_run = _FakeRun(0, "\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f)\n", "")
    monkeypatch.setattr(install_check.subprocess, "run", fake_run)

    assert install_check.main() == 0

    browser_dir = patch_camoufox
    assert fake_run.calls, "ldd should have been invoked at least once"
    for call in fake_run.calls:
        assert call["env"]["LD_LIBRARY_PATH"].endswith(os.pathsep + str(browser_dir))
