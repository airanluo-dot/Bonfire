"""Transfer packages produced by one native runner into installations on the other OS."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zlib

from renpy import GAMES, PICKLE, fixture, slot


def call(executable, env, game, operation, **params):
    request = json.dumps(dict(game=game, op=operation, **params)).encode()
    output = subprocess.run([executable], input=request, env=env, check=True, capture_output=True).stdout
    return json.loads(output)


def export(executable, work, artifact):
    artifact.mkdir(parents=True, exist_ok=True)
    shutil.copy2(executable, artifact / executable.name)
    (artifact / "platform.txt").write_text(sys.platform, encoding="ascii")
    for game, launcher, profile in GAMES:
        root, saves, _, env = fixture(work / "cross-export" / game, launcher, profile, game == "nekojishi")
        manual = "0-LT1.save" if game == "gotosnowtown" else "1-1-LT1.save"
        data = {manual: slot(90, 100, script=f"fixture-{sys.platform}-{game}"),
                "persistent": zlib.compress(PICKLE)}
        saves.mkdir(parents=True)
        expected = artifact / game / "expected"
        expected.mkdir(parents=True)
        for name, content in data.items():
            (saves / name).write_bytes(content)
            (expected / name).write_bytes(content)
        package = Path(call(executable, env, game, "export", root=str(root), folder=str(expected.parent)))
        package.rename(expected.parent / ("package" + package.suffix))
    print(f"Exported {len(GAMES)} native game packages on {sys.platform}")


def verify(executable, artifact, work, source_platform):
    assert (artifact / "platform.txt").read_text(encoding="ascii") == source_platform
    for game, launcher, profile in GAMES:
        root, saves, mirror, env = fixture(work / game, launcher, profile, game == "nekojishi")
        location = call(executable, env, game, "identify", path=str(root))
        assert Path(location[0]["save"]).resolve() == saves.resolve(), (game, location)
        package, = (artifact / game).glob("package.*")
        preview = call(executable, env, game, "preview", root=str(root), path=str(package))
        assert preview["blocking"] is None and preview["progress"]["count"] == 1, (game, preview)
        assert call(executable, env, game, "import", root=str(root), path=str(package),
                    checksum=preview["checksum"]) is True, game
        expected = {p.name: p.read_bytes() for p in (package.parent / "expected").iterdir()}
        manual = "0-LT1.save" if game == "gotosnowtown" else "1-1-LT1.save"
        assert expected.keys() == {manual, "persistent"}
        directories = [saves, mirror] if sys.platform == "win32" or game == "nekojishi" else [saves]
        for directory in directories:
            assert {p.name: p.read_bytes() for p in directory.iterdir()} == expected, (game, directory)
    print(f"Verified {len(GAMES)} imports from {source_platform} on {sys.platform}, byte for byte")


if __name__ == "__main__":
    artifacts = Path(sys.argv[1]).resolve()
    source = {"win32": "darwin", "darwin": "win32"}[sys.platform]
    runner = artifacts / ("cross-" + sys.platform) / ("roundtrip.exe" if sys.platform == "win32" else "roundtrip")
    if sys.platform == "darwin":
        runner.chmod(0o755)
    with tempfile.TemporaryDirectory(prefix="bonfire-cross-import-") as tmp:
        verify(runner, artifacts / ("cross-" + source), Path(tmp), source)
