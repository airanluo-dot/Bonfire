"""Run the native transfer tests with synthetic game data on Windows or macOS."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]


def build_tests(work):
    sources = [ROOT / "tests/roundtrip.cpp", ROOT / "adapters/catalog.cpp", *sorted((ROOT / "app").glob("*.cpp"))]
    sources.extend(sorted((ROOT / "core").glob("*.cpp")))
    for line in (ROOT / "adapters/catalog.def").read_text().splitlines():
        game_id = re.fullmatch(r"BONFIRE_GAME\(([a-z][a-z0-9_]*)\)", line)[1]
        sources.append(ROOT / "adapters" / game_id / (game_id + ".cpp"))
    puff = ROOT / "vendor/puff.c"
    if sys.platform == "win32":
        exe = work / "roundtrip.exe"
        subprocess.run(["cl", "/nologo", "/std:c++17", "/utf-8", "/MT", "/EHsc",
                        *sources, puff, "/Fe:" + str(exe), "/link", "bcrypt.lib"], cwd=work, check=True)
    elif sys.platform == "darwin":
        exe = work / "roundtrip"
        subprocess.run(["xcrun", "clang", "-c", puff, "-o", "puff.o"], cwd=work, check=True)
        subprocess.run(["xcrun", "clang++", "-std=c++17", *sources, "puff.o", "-o", exe], cwd=work, check=True)
    else:
        raise SystemExit("Run on native Windows or macOS.")
    return exe


def game_fixture(work):
    root = work / "Jurodo_win"
    if sys.platform == "darwin":
        root = work / "Jurodo.app/Contents/Resources/app.nw"
    for name in ("save", "data", "js"):
        (root / name).mkdir(parents=True)
    if sys.platform == "win32":
        (root / "Jurodo.exe").touch()
    else:
        (root.parents[1] / "Info.plist").touch()
    (root / "data/System.json").write_text(json.dumps({"advanced": {"gameId": 97475763}, "gameTitle": "獣労働"}))
    (root / "js/rmmz_managers.js").touch()
    entries = {"config": {"bgmVolume": 80}, "file1": {"map": {}, "party": {}, "system": {}},
               "global": [None, {"title": "獣労働", "playtime": "01:23:45", "timestamp": 1}]}
    for name, data in entries.items():
        packed = zlib.compress(json.dumps(data).encode()).decode("latin1").encode("utf-8")
        (root / "save" / (name + ".rmmzsave")).write_bytes(packed)
    return root


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--export-cross", type=Path, help="Write fixtures and the native runner for the other OS test")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="bonfire-tests-") as temp:
        work = Path(temp)
        destination = work / "destination"
        destination.mkdir()
        executable = build_tests(work)
        game = game_fixture(work)
        subprocess.run([executable, game, destination], check=True)
        from timeline import check
        check(executable, game, work)
        from updates import check as check_updates
        check_updates(executable)
        from renpy import check as check_renpy
        check_renpy(executable, work)
        from renpy_format import check as check_renpy_format
        check_renpy_format(executable, work)
        from nekojishi import check as check_nekojishi
        check_nekojishi(executable, work)
        from renpy_paths import check as check_renpy_paths
        check_renpy_paths(executable, work)
        if args.export_cross:
            from renpy_cross import export
            export(executable, work, args.export_cross.resolve())
