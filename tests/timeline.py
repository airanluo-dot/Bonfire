"""Exercise both native shells' service contract, including packages from the original tool."""
import hashlib
import json
from pathlib import Path
import subprocess

def check(executable, game_root, work):
    def call(op, **params):
        data = json.dumps(dict(op=op, game="jurodo", **params)).encode()
        return json.loads(subprocess.run([executable], input=data, capture_output=True, check=True).stdout)

    folders = [work / "first", work / "second"]
    for folder in folders:
        folder.mkdir()
    original = Path(call("export", root=str(game_root), folder=str(folders[0]), title="Jurodo"))
    preview = call("preview", path=str(original))
    p = preview["progress"]
    assert p["count"] == 1 and p["playtime"] == "01:23:45"
    payload = original.read_bytes()[:-32]
    assert payload[8:12] == (2).to_bytes(4, "little")
    timestamp = int.from_bytes(payload[12:20], "little")
    original = original.rename(folders[0] / "renamed.jurosave")
    def package(path, body):
        path.write_bytes(body + hashlib.sha256(body).digest())
    legacy = payload[:8] + (1).to_bytes(4, "little") + payload[20:]
    first_old = folders[1] / "Jurodo-20250102-030405-1.jurosave"
    package(first_old, legacy)
    renamed_old = folders[1] / "unknown.jurosave"
    package(renamed_old, legacy)
    newer = folders[1] / "newer.jurosave"
    package(newer, payload[:12] + (timestamp + 1000).to_bytes(8, "little") + payload[20:])
    bad = folders[1] / "bad.jurosave"
    bad.write_bytes(payload + bytes(32))
    records = call("timeline", folders=list(map(str, [*folders, folders[0]])))
    rows = records["rows"]
    assert records["skipped"] == 1
    assert [i["name"] for i in rows] == [newer.name, original.name, first_old.name, renamed_old.name]
    assert rows[1]["created"] == timestamp and rows[-1]["created"] == 0
    assert all(i["progress"] == p for i in rows)
    assert call("preview", path=str(bad))["error"] == "BadHash"
    assert call("import", root=str(game_root), path=str(newer), checksum=preview["checksum"])["error"] == "ChangedPackage"
    assert call("import", root=str(game_root), path=str(first_old), checksum=call("preview", path=str(first_old))["checksum"])
    print("Original v1 import, v2 embedded time, renamed and damaged packages, folder deduplication, time ordering, preview binding: OK")
