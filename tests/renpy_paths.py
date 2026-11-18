"""Exercise Ren'Py profile discovery and rollback across two save locations."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

from renpy import fixture, slot


@contextmanager
def deny_write(path):
    # Both save locations can still be snapshotted. Only the write to the
    # second directory fails, after the first copy has been replaced.
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateFileW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = kernel.CreateFileW(str(path), 0x80000000, 1, None, 3, 0, None)
        if handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            yield
        finally:
            kernel.CloseHandle(handle)
    else:
        original = path.stat().st_flags
        os.chflags(path, original | stat.UF_IMMUTABLE)
        try:
            yield
        finally:
            os.chflags(path, original)


def check(executable, work):
    def call(game, env, op, **params):
        request = json.dumps(dict(game=game, op=op, **params)).encode()
        response = subprocess.run([executable], input=request, env=env, capture_output=True, check=True)
        return json.loads(response.stdout)

    folder = work / "renpy-save-paths"
    for game, launcher, profile, override_supported in (
            ("adastra", "Adastra", "Adastra-1513063297", False),
            ("khemia", "Khemia", "Khemia-1733067824", True)):
        install, default, mirror, env = fixture(folder / game, launcher, profile, False)
        options = mirror.parent / "options.rpy"
        options.write_text(f"define config.save_directory = '{profile}'\n")
        def discovered(settings):
            return Path(call(game, settings, "identify", path=str(install))[0]["save"]).resolve()
        assert discovered(env) == default.resolve()
        if sys.platform == "win32":
            without_appdata = env.copy()
            del without_appdata["APPDATA"]
            home_saves = Path(env["USERPROFILE"]) / "RenPy" / profile
            assert discovered(without_appdata) == home_saves.resolve()
        portable = install.parent / "Ren'Py Data"
        portable.mkdir()
        assert discovered(env) == (portable / profile).resolve()
        override = folder / "separate save location"
        redirected = dict(env, RENPY_PATH_TO_SAVES=str(override))
        destination = override if override_supported else portable
        assert discovered(redirected) == (destination / profile).resolve()
        options.write_text('define config.save_directory = "another-title"\n')
        assert call(game, env, "identify", path=str(install)) == {"error": "InvalidLocation"}

    game, launcher, profile = "adastra", "Adastra", "Adastra-1513063297"
    source, primary, _, env = fixture(folder / "before-transfer", launcher, profile, True)
    target, dest, mirror, target_env = fixture(folder / "failing-device", launcher, profile, True)
    primary.mkdir(parents=True)
    dest.mkdir(parents=True)
    name = "1-1-LT1.save"
    incoming = slot(100, 100)
    (primary / name).write_bytes(incoming)
    (primary / "3-1-LT1.save").write_bytes(slot(50, 50))
    packages = folder / "packages"
    packages.mkdir()
    package = call(game, env, "export", root=str(source), folder=str(packages))
    checksum = call(game, env, "preview", path=package)["checksum"]

    def snapshot(directory):
        return {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in directory.iterdir()}

    for index, location in enumerate((dest, mirror)):
        for filename in (name, "2-1-LT1.save", "unmanaged.txt"):
            path = location / filename
            path.write_bytes(f"{index}-{filename}".encode())
            os.utime(path, (1_600_000_000 + index, 1_600_000_000 + index))
    before = [snapshot(location) for location in (dest, mirror)]
    with deny_write(mirror / name):
        failed = call(game, target_env, "import", root=str(target), path=package, checksum=checksum)
        assert failed == {"error": "OpenFile"}, failed
    assert [snapshot(location) for location in (dest, mirror)] == before
    assert call(game, target_env, "import", root=str(target), path=package, checksum=checksum) is True
    for location in (dest, mirror):
        assert (location / name).read_bytes() == incoming and not (location / "2-1-LT1.save").exists()
    print("Ren'Py profile identity, portable and override paths, two-directory rollback and retry: OK")
