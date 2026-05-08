"""Build hook: bundle the native libpyx artifact into the wheel.

Order of operations on `pip wheel .` / `python -m build --wheel`:

  1. Locate a pre-built dylib (env var, walked-up `zig-out/lib`, or run
     `zig build -Doptimize=ReleaseSmall` from the repo root if Zig is on
     PATH).
  2. Copy the platform-appropriate library into `pyx/` so setuptools'
     package_data pattern (declared in `pyproject.toml`) picks it up.
  3. Force the resulting wheel to be platform-tagged (not pure-Python),
     since it ships a native binary.

The metadata stays in `pyproject.toml`; this file is only present for
the build hook.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from setuptools import Distribution, setup
from setuptools.command.build_py import build_py


HERE = Path(__file__).resolve().parent
PKG_DIR = HERE / "pyx"


def _lib_name() -> str:
    if sys.platform == "darwin":
        return "libpyx.dylib"
    if sys.platform.startswith("linux") or sys.platform.startswith("freebsd"):
        return "libpyx.so"
    if sys.platform == "win32":
        return "pyx.dll"
    raise RuntimeError(f"unsupported platform for pyx: {sys.platform}")


def _candidate_prebuilt() -> list[Path]:
    name = _lib_name()
    paths: list[Path] = []
    if env := os.environ.get("PYX_PREBUILT_LIB"):
        paths.append(Path(env))
    # Walk up from this file looking for `zig-out/lib/<name>` so the
    # build works whether `setup.py` runs in-place or has been copied
    # into a build sandbox by the frontend.
    cur = HERE
    for _ in range(6):
        paths.append(cur / "zig-out" / "lib" / name)
        cur = cur.parent
    return paths


def _find_repo_root() -> Path | None:
    cur = HERE
    for _ in range(6):
        if (cur / "build.zig").exists():
            return cur
        cur = cur.parent
    return None


def _ensure_native_lib() -> Path:
    name = _lib_name()
    for c in _candidate_prebuilt():
        if c.exists():
            return c

    if os.environ.get("PYX_SKIP_NATIVE_BUILD"):
        raise RuntimeError(
            f"PYX_SKIP_NATIVE_BUILD is set but no prebuilt {name} found. "
            "Set PYX_PREBUILT_LIB=/path/to/libpyx.{dylib,so,dll}."
        )

    repo_root = _find_repo_root()
    if repo_root is None or not shutil.which("zig"):
        raise RuntimeError(
            f"Could not locate {name}. Either:\n"
            "  - run `zig build -Doptimize=ReleaseSmall` in the project root before building the wheel, or\n"
            "  - install Zig (https://ziglang.org/download/), or\n"
            "  - set PYX_PREBUILT_LIB=/path/to/libpyx.{dylib,so,dll}."
        )

    print(f"[pyx-setup] running `zig build -Doptimize=ReleaseSmall` in {repo_root}", flush=True)
    subprocess.check_call(
        ["zig", "build", "-Doptimize=ReleaseSmall"],
        cwd=str(repo_root),
    )
    out = repo_root / "zig-out" / "lib" / name
    if not out.exists():
        raise RuntimeError(f"`zig build` succeeded but {out} is missing")
    return out


class BuildPy(build_py):
    """Stages libpyx into the source package dir before files are copied."""

    def run(self):
        src = _ensure_native_lib()
        dst = PKG_DIR / src.name
        if not dst.exists() or dst.stat().st_mtime < src.stat().st_mtime:
            shutil.copy2(src, dst)
            print(f"[pyx-setup] bundled {src} -> {dst}", flush=True)
        super().run()


# Force a platform-tagged wheel — this package ships a native library, so
# it is not pure-Python and the wheel tag must reflect that.
cmdclass = {"build_py": BuildPy}

class BinaryDistribution(Distribution):
    """Tell setuptools this distribution is platform-specific even though
    it has no setuptools-tracked C extensions. Without this the wheel
    would be tagged `py3-none-any` and pip would happily install a macOS
    .dylib on a Linux machine."""

    def has_ext_modules(self):
        return True


try:
    from wheel.bdist_wheel import bdist_wheel as _bdist_wheel  # type: ignore

    class BdistWheel(_bdist_wheel):
        def get_tag(self):
            # ABI: `none` because the binding is ctypes-only — there is no
            # Python C-ABI dependency, so one wheel works for every
            # CPython 3.x and PyPy on the matching platform. Platform tag
            # comes from `has_ext_modules() == True` above.
            _, _, plat = super().get_tag()
            return "py3", "none", plat

    cmdclass["bdist_wheel"] = BdistWheel
except ImportError:
    pass


setup(cmdclass=cmdclass, distclass=BinaryDistribution)
