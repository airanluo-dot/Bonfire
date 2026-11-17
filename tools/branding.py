"""The multi-resolution placeholder is shared by Finder, Windows and the installer."""
from pathlib import Path
import struct
import shutil

def build_icon(branding, destination, platform):
    master = branding / "AppIcon.icns"
    if platform == "macos":
        shutil.copyfile(master, destination / "AppIcon.icns")
        return
    data = master.read_bytes()
    if data[:4] != b"icns" or int.from_bytes(data[4:8], "big") != len(data):
        raise ValueError("Invalid application icon")
    frames = {}
    pos = 8
    while pos < len(data):
        length = int.from_bytes(data[pos + 4:pos + 8], "big")
        if length < 8 or pos + length > len(data):
            raise ValueError("Invalid icon frame")
        frame = data[pos + 8:pos + length]
        pos += length
        if frame.startswith(b"\x89PNG\r\n\x1a\n"):
            width, height = struct.unpack_from(">II", frame, 16)
            if width == height and 0 < width <= 256:
                frames[width] = frame
    if 256 not in frames:
        raise ValueError("AppIcon.icns needs a 256px PNG frame for Windows")
    directory = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
    payload = bytearray()
    for size, frame in sorted(frames.items()):
        offset = 6 + 16 * len(frames) + len(payload)
        directory.extend(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(frame), offset))
        payload.extend(frame)
    (destination / "app.ico").write_bytes(directory + payload)
