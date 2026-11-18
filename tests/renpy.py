"""Exercise the registered Ren'Py adapters through the native service, in isolated user homes."""
import io
import json
import os
from pathlib import Path
import pickle
import subprocess
import sys
import zipfile
import zlib


GAMES = (
    ("adastra", "Adastra", "Adastra-1513063297"),
    ("interea", "Interea", "AdastraInterea-1614811255"),
    ("khemia", "Khemia", "Khemia-1733067824"),
    ("remember_flowers", "RemembertheFlowers", "RemembertheFlowers-1617808159"),
    ("nekojishi", "Nekojishi", "Neko-171107s"),
    ("gotosnowtown", "GoToSnowTown", "GoToSnowTown-VERSION260901"),
    ("emberbound", "Emberbound", "newgame-1773923380"),
)
PICKLE = b"\x80\x02N."


def slot(seconds, timestamp, *, chapter=None, script=None):
    stream = io.BytesIO()
    metadata = {"_ctime": timestamp, "_game_runtime": seconds}
    if chapter:
        metadata["emberbound_chapter"] = chapter
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("log", pickle.dumps(script, protocol=2) if script else PICKLE)
        archive.writestr("json", json.dumps(metadata))
        archive.writestr("renpy_version", "Ren'Py 8.3.2")
    return stream.getvalue()


def fixture(device, launcher, profile, external_mac):
    home = device / "home"
    env = dict(os.environ, HOME=str(home), USERPROFILE=str(home), APPDATA=str(home / "Roaming"))
    env.pop("RENPY_PATH_TO_SAVES", None)
    release = device / "installation"
    if sys.platform == "win32":
        install = release / launcher
        base = install
        binary = install / (launcher + ".exe")
        saves = home / "Roaming" / "RenPy" / profile
    else:
        install = release / (launcher + ".app")
        contents = install / "Contents"
        binary = contents / "MacOS" / launcher
        contents.mkdir(parents=True)
        (contents / "Info.plist").touch()
        base = release if external_mac else contents / "Resources" / "autorun"
        saves = home / "Library" / "RenPy" / profile
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.touch()
    mirror = base / "game" / "saves"
    mirror.mkdir(parents=True)
    (base / "game" / "script.rpyc").touch()
    (base / (launcher + ".py")).touch()
    (base / "renpy").mkdir()
    (base / "renpy" / "bootstrap.py").touch()
    return install, saves, mirror, env


def write_script_archive(path, script):
    key = 0x42424242
    payload = b"compiled fixture"
    offset = 34 + len(payload)
    index = {script + "c": [(34 ^ key, len(payload) ^ key, b"")]}
    header = f"RPA-3.0 {offset:016x} {key:08x}\n".encode()
    path.write_bytes(header + payload + zlib.compress(pickle.dumps(index, protocol=5)))


def check_content_versions(game, call, source, target, primary, other, target_game, source_env, target_env, packages):
    if game == "emberbound":
        script = "side_stories/shengyang_day/story.rpy"
        data = slot(400, 700, chapter="extra_shengyang_day")
        error = "Emberbound_SideStoryMissing"
    else:
        script = "scripts/story/story_ep1.rpy"
        data = slot(400, 700, script="game/" + script)
        error = "Snowtown_PublicMissing"
    (primary / "quick-2-LT1.save").write_bytes(data)
    path = call(source_env, "export", root=str(source), folder=str(packages))
    checksum = call(source_env, "preview", path=path)["checksum"]
    write_script_archive(target_game / "archive.rpa", "scripts/main.rpy")
    before = {file.name: file.read_bytes() for file in other.iterdir()}
    assert call(target_env, "preview", path=path, root=str(target))["blocking"]["key"] == error
    assert call(target_env, "import", root=str(target), path=path, checksum=checksum)["error"] == error
    assert before == {file.name: file.read_bytes() for file in other.iterdir()}, game
    # A resource patch in another archive supplies the exact chapter without changing the version string.
    write_script_archive(target_game / "additional_content.rpa", script)
    assert call(target_env, "preview", path=path, root=str(target))["blocking"] is None
    assert call(target_env, "import", root=str(target), path=path, checksum=checksum) is True
    assert (other / "quick-2-LT1.save").read_bytes() == data


def check(executable, work):
    packages = work / "renpy-packages"
    packages.mkdir()
    for game, launcher, profile in GAMES:
        def call(env, operation, *, adapter=game, **params):
            data = json.dumps(dict(game=adapter, op=operation, **params)).encode()
            output = subprocess.run([executable], input=data, env=env, capture_output=True,
                                    check=True).stdout
            return json.loads(output)

        standalone = sys.platform == "darwin" and game != "nekojishi"
        folder = work / "renpy" / game
        source, primary, mirror, source_env = fixture(folder / "source", launcher, profile,
                                                      external_mac=game == "nekojishi")
        target, other, other_mirror, target_env = fixture(folder / "target", launcher, profile,
                                                          external_mac=game == "nekojishi")
        roots = call(source_env, "identify", path=str(source.parent))
        assert Path(roots[0]["root"]).resolve() == source.resolve(), (game, roots)
        assert Path(roots[0]["save"]).resolve() == primary.resolve(), (game, roots)
        state = call(source_env, "inventory", root=str(source))
        assert not state["available"] and state["count"] == 0, (game, state)
        assert "error" in call(source_env, "export", root=str(source), folder=str(packages))
        primary.mkdir(parents=True)
        persistent = zlib.compress(PICKLE)
        (primary / "persistent").write_bytes(persistent)
        first = call(source_env, "export", root=str(source), folder=str(packages))
        header = call(source_env, "preview", path=first)
        state = header["progress"]
        assert state["available"] and state["persistent"] and state["count"] == 0, (game, state)
        assert call(target_env, "import", root=str(target), path=first, checksum=header["checksum"]) is True
        assert (other / "persistent").read_bytes() == persistent

        manual = "0-LT1.save" if game == "gotosnowtown" else "1-1-LT1.save"
        second = "quit-LT1.save" if game == "gotosnowtown" else "auto-1-LT1.save"
        newer = slot(3723, 300)
        additional = slot(55, 100)
        (primary / manual).write_bytes(newer if standalone else slot(1, 50))
        if standalone:
            # A standalone .app is read-only in ordinary use. Its bundled saves are ignored.
            (mirror / manual).write_bytes(b"bundled example")
            (primary / second).write_bytes(additional)
        else:
            (mirror / manual).write_bytes(newer)
            os.utime(primary / manual, (100, 100))
            os.utime(mirror / manual, (200, 200))
            (primary / second).write_bytes(additional)

        full = call(source_env, "export", root=str(source), folder=str(packages))
        preview = call(source_env, "preview", path=full)
        state = preview["progress"]
        assert state == call(source_env, "inventory", root=str(source)), (game, state)
        assert state["count"] == 2 and state["slot"] == manual.split("-LT1")[0], (game, state)
        assert state["playtime"] == "01:02:03" and state["persistent"], (game, state)
        active_dirs = [other] if standalone else [other, other_mirror]
        for dest in active_dirs:
            (dest / "99-99-LT1.save").write_bytes(slot(0, 1))
            (dest / "notes.txt").write_bytes(b"keep")
        for _ in range(2):
            assert call(target_env, "import", root=str(target), path=full, checksum=preview["checksum"]) is True
            for dest in active_dirs:
                assert (dest / manual).read_bytes() == newer and (dest / second).read_bytes() == additional
                assert (dest / "persistent").read_bytes() == persistent
                assert (dest / "notes.txt").read_bytes() == b"keep" and not (dest / "99-99-LT1.save").exists()
        if standalone:
            assert not list(other_mirror.iterdir())
        if game in ("emberbound", "gotosnowtown"):
            check_content_versions(game, call, source, target, primary, other, other_mirror.parent,
                                   source_env, target_env, packages)
        wrong_game = "adastra" if game != "adastra" else "khemia"
        assert call(target_env, "preview", adapter=wrong_game, path=full)["error"] == "WrongFormat"
        corrupted = packages / "damaged-package"
        damaged = bytearray(Path(full).read_bytes())
        damaged[-1] ^= 1
        corrupted.write_bytes(damaged)
        assert call(target_env, "import", root=str(target), path=str(corrupted),
                    checksum=preview["checksum"])["error"] == "BadHash"
        (primary / second).write_bytes(b"damaged slot")
        assert call(source_env, "export", root=str(source), folder=str(packages))["error"] == "Renpy_Format"
    print("Seven Ren'Py adapters: isolated profiles, persistent-only data, slot merging, "
          "repeat imports, package isolation and corrupt saves: OK")
