"""Check real Ren'Py signature framing and ZIP member CRC failures at the service boundary."""
import io
import json
import subprocess
import zipfile
import zlib

from renpy import fixture, PICKLE, slot


# A generated P-256 public key and raw ECDSA signature for PICKLE, as written
# by Ren'Py. No signing key is required to run the test or retained here.
SIGNATURE = (
    b"signature MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEWXAuTVzqZEVNan9c7wtk26C9pUQhJidUQ"
    b"57XK2dlkbydDqE9JiycLWFen4z4comrvPlvFdZ7I2mB9W9eA0iEKw== "
    b"PkA0UKqn7SNwIke9S4h1OkdrAyuMTPGI1QGJf8Qv4mXxM9LxYxfO4xZTZ1yQUWPnxMfaGQ08DHuMScwvJIPvCQ==\n"
)


def corrupt_crc():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", zipfile.ZIP_STORED) as archive:
        archive.writestr("log", PICKLE)
        archive.writestr("json", b'{"_game_runtime":1234}')
        archive.writestr("renpy_version", "Ren'Py 8.3.4")
    # One valid JSON number changes in the stored payload. Both ZIP headers and
    # the pickle framing still match, isolating the stale payload checksum.
    return stream.getvalue().replace(b"1234}", b"1235}", 1)


def check(executable, work):
    root = work / "renpy-format"
    install, primary, _, env = fixture(root / "device", "Khemia", "Khemia-1733067824", False)
    target, restored, _, target_env = fixture(root / "target", "Khemia", "Khemia-1733067824", False)
    packages = root / "packages"
    packages.mkdir()
    primary.mkdir(parents=True)

    def call(operation, *, device_env=env, **params):
        request = json.dumps(dict(game="khemia", op=operation, **params)).encode()
        result = subprocess.run([executable], input=request, capture_output=True, env=device_env, check=True)
        return json.loads(result.stdout)

    persistent = primary / "persistent"
    unsigned = zlib.compress(PICKLE)
    for tail in (b"", SIGNATURE, SIGNATURE * 2):
        persistent.write_bytes(unsigned + tail)
        package = call("export", root=str(install), folder=str(packages))
        preview = call("preview", path=package, root=str(target), device_env=target_env)
        assert preview["progress"]["persistent"], preview
        assert ("Renpy_SignedOnly" in preview["notices"]) == bool(tail), preview
        assert "Renpy_Signed" not in preview["notices"], preview
        assert call("import", path=package, root=str(target), device_env=target_env,
                    checksum=preview["checksum"]) is True
        assert (restored / "persistent").read_bytes() == unsigned + tail

    auto = primary / "auto-1-LT1.save"
    auto.write_bytes(slot(30, 50))
    package = call("export", root=str(install), folder=str(packages))
    preview = call("preview", path=package)
    assert "Renpy_Signed" in preview["notices"] and "Renpy_SignedOnly" not in preview["notices"], preview
    persistent.write_bytes(unsigned + b"signature missing-pair\n")
    assert call("export", root=str(install), folder=str(packages))["error"] == "Renpy_Format"
    persistent.write_bytes(unsigned)
    auto.write_bytes(corrupt_crc())
    assert call("export", root=str(install), folder=str(packages))["error"] == "Renpy_Format"
    print("Ren'Py signed and unsigned persistent data, transfer and damaged ZIP member CRC: OK")
