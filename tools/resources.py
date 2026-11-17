"""Check both catalogs, then compile them into the resource format of each native UI."""
import argparse
import json
import plistlib
import re
import shutil
from pathlib import Path
from string import Formatter
from xml.etree import ElementTree as ET
from branding import build_icon

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans")

def registered():
    lines = (ROOT / "adapters/catalog.def").read_text().splitlines()
    games = [re.fullmatch(r"BONFIRE_GAME\(([a-z][a-z0-9_]*)\)", line)[1] for line in lines if line.strip()]
    if len(games) != len(set(games)):
        raise ValueError("Duplicate game registration")
    return games

def unique(pairs):
    data = {}
    for key, value in pairs:
        if key in data:
            raise ValueError(f"Duplicate localization key: {key}")
        data[key] = value
    return data

def parameters(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("Translation must be nonempty text")
    fields = []
    for _, field, spec, conv in Formatter().parse(value):
        if field is not None:
            if not field.isdecimal() or spec or conv:
                raise ValueError(f"Only indexed arguments are supported: {value}")
            fields.append(int(field))
    if fields and set(fields) != set(range(max(fields) + 1)):
        raise ValueError(f"Non-consecutive format arguments: {value}")
    return sorted(fields)

def catalogs(games):
    tables = {lang: {} for lang in LANGUAGES}
    paths = [ROOT / "localization", *(ROOT / "adapters" / g / "localization" for g in games)]
    for path in paths:
        local = {lang: json.loads((path / (lang + ".json")).read_text(encoding="utf-8"),
                                  object_pairs_hook=unique) for lang in LANGUAGES}
        if local["en"].keys() != local["zh-Hans"].keys():
            raise ValueError(f"Different localization keys in {path}: {local['en'].keys() ^ local['zh-Hans'].keys()}")
        for key, value in local["en"].items():
            if key in tables["en"] or not re.fullmatch(r"[A-Za-z][A-Za-z_0-9]*", key):
                raise ValueError(f"Duplicate or invalid localization key: {key}")
            if parameters(value) != parameters(local["zh-Hans"][key]):
                raise ValueError(f"Different format arguments for {key}")
        for lang in LANGUAGES:
            tables[lang].update(local[lang])

    required = {"Game_" + game for game in games}
    # Dynamic keys (catalog IDs and language choices) are validated separately.
    lookup = re.compile(r'(?:\b(?:T|Error|ServiceError)\(\s*|\b(?:t|format|text|group):\s*@)"([A-Za-z][A-Za-z_0-9]*)"')
    for directory in ["app", "core", "adapters", "windows", "macos"]:
        for file in (ROOT / directory).rglob("*"):
            if file.suffix in {".cpp", ".mm", ".cs", ".hpp"} and not set(file.parts) & {"obj", "bin"}:
                required.update(lookup.findall(file.read_text(encoding="utf-8-sig")))
    required.discard("Game_")
    missing = required - tables["en"].keys()
    if missing:
        raise ValueError(f"Missing referenced translations: {sorted(missing)}")
    return tables

def generate(destination, platform):
    games = registered()
    tables = catalogs(games)
    icons = destination / ("Assets/Games" if platform == "windows" else "Games")
    icons.mkdir(parents=True, exist_ok=True)
    build_icon(ROOT / "branding", destination, platform)
    for game in games:
        shutil.copyfile(ROOT / "adapters" / game / "icon.png", icons / (game + ".png"))
    for lang, table in tables.items():
        if platform == "windows":
            folder = destination / "Strings" / lang
            folder.mkdir(parents=True, exist_ok=True)
            tree = ET.Element("root")
            for key, value in sorted(table.items()):
                item = ET.SubElement(tree, "data", {"name": key, "xml:space": "preserve"})
                ET.SubElement(item, "value").text = value
            ET.ElementTree(tree).write(folder / "Resources.resw", encoding="utf-8", xml_declaration=True)
        else:
            folder = destination / (lang + ".lproj")
            folder.mkdir(parents=True, exist_ok=True)
            for filename, is_usage in [("Localizable.strings", False), ("InfoPlist.strings", True)]:
                lines = [f"{json.dumps(k)} = {json.dumps(v, ensure_ascii=False)};\n"
                         for k, v in sorted(table.items()) if k.endswith("UsageDescription") == is_usage]
                (folder / filename).write_text("".join(lines), encoding="utf-8")
    if platform == "macos":
        # Include an English fallback for system privacy prompts before localization is loaded.
        path = destination.parent / "Info.plist"
        info = plistlib.loads((ROOT / "macos/Info.plist").read_bytes())
        version = (ROOT / "VERSION").read_text().strip()
        short, _, beta = version.partition("-beta.")
        info.update(CFBundleShortVersionString=short, CFBundleVersion=beta or "1", BonfireVersion=version)
        info.update({k: v for k, v in tables["en"].items() if k.endswith("UsageDescription")})
        path.write_bytes(plistlib.dumps(info, sort_keys=False))
    return len(tables["en"])

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=["windows", "macos"])
    parser.add_argument("out", type=Path)
    args = parser.parse_args()
    print(generate(args.out, args.platform), "localized keys validated")
