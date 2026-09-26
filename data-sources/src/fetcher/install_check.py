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
    # package provides) live there, not on a system library path. ldd only
    # consults the system search path plus LD_LIBRARY_PATH -- it knows
    # nothing of `dependentlibs.list`, which lists exactly these names and is
    # what Firefox's own XPCOM glue uses to preload them by absolute path at
    # real launch time, which is why the browser runs fine with no
    # LD_LIBRARY_PATH set. Camoufox never references LD_LIBRARY_PATH at all;
    # Playwright's own dependency validator (missingFileDependencies) sets it
    # the same way we do here -- appended to whatever is already set, never
    # replacing it -- for the same reason: so ITS ldd call can resolve these
    # siblings too.
    existing_ld_path = os.environ.get("LD_LIBRARY_PATH")
    ld_library_path = (
        f"{existing_ld_path}{os.pathsep}{executable.parent}"
        if existing_ld_path
        else str(executable.parent)
    )
    ldd_env = {**os.environ, "LD_LIBRARY_PATH": ld_library_path}
    missing: list[str] = []
    for binary in (executable, executable.parent / "libxul.so"):
        result = subprocess.run(
            ["ldd", str(binary)], capture_output=True, text=True, check=False, env=ldd_env
        )
        if result.returncode != 0:
            print(f"ldd failed on {binary}: {result.stderr.strip()}", file=sys.stderr)
            return 1
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
