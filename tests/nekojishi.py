"""Verify optional-content checks through the package and receive services."""
import hashlib
import io
import json
import pickle
import struct
import subprocess
import zipfile

from renpy import fixture


def slot(state):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("log", pickle.dumps(state, protocol=2))
        archive.writestr("json", '{"_version":"1.06s"}')
        archive.writestr("renpy_version", "Ren'Py 7.1.3.1092")
    return stream.getvalue()


def check(executable, work):
    source, saves, mirror, source_env = fixture(work / "neko-patched", "Nekojishi", "Neko-171107s", True)
    target, received, target_mirror, target_env = fixture(work / "neko-stock", "Nekojishi", "Neko-171107s", True)
    saves.mkdir(parents=True)
    output = work / "neko-content-packages"
    output.mkdir()
    patch, expansion = "adult-d.rpa", "extra.rpa"
    for archive in (patch, expansion):
        (mirror.parent / archive).touch()

    def call(env, operation, **params):
        request = json.dumps(dict(game="nekojishi", op=operation, **params)).encode()
        return json.loads(subprocess.run([executable], env=env, input=request,
                                         capture_output=True, check=True).stdout)

    def transfer(package):
        preview = call(target_env, "preview", root=str(target), path=str(package))
        return call(target_env, "import", root=str(target), path=str(package), checksum=preview["checksum"])

    name = "1-1-LT1.save"
    adult_script = "game/tl/zhHans/adult/script/14_r18.rpy"
    sunny_script = "game/extra/script/script.rpy"

    def export(state):
        (saves / name).write_bytes(slot(state))
        return call(source_env, "export", root=str(source), folder=str(output))

    # Merely storing an optional script name as a string is not a dependency.
    plain = export({"current": ("game/script/14.rpy", 1, 2),
                    "gallery": (adult_script, 1, 2)})
    preview = call(target_env, "preview", root=str(target), path=plain)
    assert preview["notices"] == ["Neko_SourceBoth"] and preview["blocking"] is None
    assert transfer(plain) is True
    original = (received / name).read_bytes()
    assert all(p.name == name for p in received.iterdir())
    assert all(p.name == name for p in target_mirror.iterdir())
    for state, expected in [
        ({"current": (adult_script, 1524496581, 20)}, "Neko_NeedsAdult"),
        ({"current": (sunny_script, 1543484936, 972)}, "Neko_NeedsSunny"),
        ([{"current": (adult_script, 1, 2)}, {"current": (sunny_script, 3, 4)}], "Neko_NeedsBoth"),
    ]:
        package = export(state)
        preview = call(target_env, "preview", root=str(target), path=package)
        assert preview["blocking"]["key"] == expected and not preview["notices"]
        assert transfer(package) == {"error": expected}
        assert (received / name).read_bytes() == original

    (target_mirror.parent / "adult.rpa").touch()
    assert transfer(package) == {"error": "Neko_NeedsSunny"}
    (target_mirror.parent / expansion).touch()
    assert transfer(package) is True
    assert (received / name).read_bytes() == (saves / name).read_bytes()
    assert not (received / "bonfire-nekojishi-content").exists()
    assert transfer(plain) is True  # A destination with extra content is compatible.

    # Packages from before the optional-content manifest remain readable.
    raw = slot(None)
    body = (b"NEKOSAVE" + struct.pack("<IQI", 2, 1000, 1)
            + struct.pack("<II", len(name), len(raw)) + name.encode() + raw)
    legacy = output / "no-manifest.nekosave"
    legacy.write_bytes(body + hashlib.sha256(body).digest())
    assert transfer(legacy) is True
    print("Nekojishi: base saves, optional-content notices, scene requirements and legacy packages: OK")
