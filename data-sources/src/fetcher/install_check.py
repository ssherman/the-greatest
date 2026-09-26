"""Build-time check that the pinned Camoufox browser really is installed (spec §4).

`camoufox fetch` prints an error and exits 0 when a download fails, so the
image build runs `python -m fetcher.install_check` straight after it and fails
on anything missing: the pinned build, the bundled uBlock Origin add-on, or a
shared library Firefox needs.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def expected_build(spec: str) -> str:
    """`official/stable/152.0.4-beta.30` -> `152.0.4-beta.30`."""
    return spec.rstrip("/").rsplit("/", 1)[-1].removeprefix("v")


def missing_libraries(ldd_output: str) -> list[str]:
    """Library names `ldd` reports as `not found`."""
    return [
        line.split("=>", 1)[0].strip() for line in ldd_output.splitlines() if "not found" in line
    ]


def main() -> int:
    from camoufox.addons import ADDONS_DIR
    from camoufox.pkgman import camoufox_path, installed_verstr, launch_path

    spec = os.environ.get("CAMOUFOX_BROWSER", "")
    if not spec:
        print("CAMOUFOX_BROWSER is not set", file=sys.stderr)
        return 1
    try:
        # download_if_missing=False: this check must never fetch anything itself.
        executable = Path(launch_path(camoufox_path(download_if_missing=False)))
        installed = installed_verstr()
    except Exception as exc:  # camoufox raises its own types for a missing install
        print(f"the Camoufox browser is not installed: {exc}", file=sys.stderr)
        return 1
    if installed != expected_build(spec):
        print(f"installed build {installed} is not the pinned {spec}", file=sys.stderr)
        return 1
    if not (ADDONS_DIR / "UBO" / "manifest.json").exists():
        print(f"the uBlock Origin add-on is missing from {ADDONS_DIR}", file=sys.stderr)
        return 1
    # libxul.so is where Firefox's GTK, X11 and audio dependencies live; the
    # launcher binary itself links almost nothing.
    #
    # ldd needs LD_LIBRARY_PATH pointing at the browser's own directory:
    # libxul.so's sibling libraries (bundled NSS/NSPR, and Mozilla's private
    # codec/sqlite/sandbox/GTK-glue builds, which ship under names no Debian
    # package provides) live there, not on a system library path. The real
    # launch always sets this — it is exactly what Playwright's Firefox
    # launcher does before it execs the binary — so leaving it unset here
    # would make every one of those sibling libraries read as "not found"
    # even on a correctly installed browser.
    ldd_env = {**os.environ, "LD_LIBRARY_PATH": str(executable.parent)}
    missing: list[str] = []
    for binary in (executable, executable.parent / "libxul.so"):
        result = subprocess.run(
            ["ldd", str(binary)], capture_output=True, text=True, check=False, env=ldd_env
        )
        missing += missing_libraries(result.stdout)
    if missing:
        print(
            "Firefox needs libraries the image lacks: " + ", ".join(sorted(set(missing))),
            file=sys.stderr,
        )
        return 1
    print(f"Camoufox {installed} installed at {executable}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
