"""Build the public game catalog and its assets from the native adapter registry."""

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path


def edition_notes(readme):
    """Use the package extension to match optional release notes to each adapter."""
    notes = {}
    for line in readme.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 3 or not re.fullmatch(r"`\.[a-z0-9_]+`", cells[2]):
            continue
        text = cells[1].split("[", 1)[0].rstrip("。 ·")
        edition, _, note = text.partition("，")
        notes[cells[2].strip("`")] = (edition, note)
    return notes


def build_catalog(root, output, version):
    if (root / "VERSION").read_text(encoding="utf-8").strip() != version:
        raise ValueError(f"Tagged game catalog does not match release {version}")
    (output / "assets/games").mkdir(parents=True, exist_ok=True)
    adapters = root / "adapters"
    notes = edition_notes((root / "README.md").read_text(encoding="utf-8"))
    games = []
    seen = set()
    for line in (adapters / "catalog.def").read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        entry = re.fullmatch(r"BONFIRE_GAME\(([a-z][a-z0-9_]*)\)", line.strip())
        if not entry or entry[1] in seen:
            raise ValueError(f"Invalid or repeated game registration: {line}")
        game_id = entry[1]
        seen.add(game_id)
        folder = adapters / game_id
        catalog = json.loads((folder / "localization/zh-Hans.json").read_text(encoding="utf-8"))
        source = (folder / f"{game_id}.cpp").read_text(encoding="utf-8")
        # GameInfo starts with the stable ID, package extension and 8-byte signature.
        package = re.search(rf'"{game_id}"\s*,\s*"([a-z0-9_]+)"\s*,\s*\{{', source)
        if not package:
            raise ValueError(f"Missing GameInfo package extension for {game_id}")
        extension = "." + package[1]
        edition, note = notes.get(extension, ("", ""))
        icon = (folder / "icon.png").read_bytes()
        fingerprint = hashlib.sha256(icon).hexdigest()[:16]
        icon_path = f"assets/games/{game_id}.{fingerprint}.png"
        (output / icon_path).write_bytes(icon)
        games.append({
            "id": game_id, "name": catalog["Game_" + game_id], "extension": extension,
            "edition": edition, "note": note, "icon": icon_path,
        })

    (output / "assets/bonfire.svg").write_bytes((root / "branding/Bonfire.svg").read_bytes())
    payload = {"version": version, "games": games}
    (output / "games.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return payload


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    with zipfile.ZipFile(args.archive) as source:
        build_catalog(zipfile.Path(source), args.output_root, args.version)
