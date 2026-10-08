#!/usr/bin/env python3
"""Offline, deterministic Swift symbols + native Image accessors. No network/build-time credentials."""
import json
import re
import sys
from pathlib import Path

def generate(catalog):
    if type(catalog.get("schemaVersion")) is not int or catalog["schemaVersion"] != 1:
        raise ValueError("Unsupported catalog")
    if not isinstance(catalog.get("placements"), list) or not 1 <= len(catalog["placements"]) <= 100:
        raise ValueError("Catalog must contain 1 to 100 placements")
    groups = {}
    seen = set()
    keys = set()
    accessors = {}
    reserved = {"store", "bundle", "all", "AppArtwork", "AssetCatalog"}
    for item in catalog["placements"]:
        symbol = item["symbol"]
        if len(symbol) != 2 or any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", x) for x in symbol):
            raise ValueError("Symbols must be exactly two Swift identifiers")
        group, member = symbol
        accessor = group[0].lower() + group[1:]
        if group in reserved or member in reserved or accessor in reserved:
            raise ValueError("Symbol collides with a generated helper")
        if accessor in accessors and accessors[accessor] != group:
            raise ValueError("Groups generate the same accessor")
        accessors[accessor] = group
        pair = (group, member)
        if pair in seen or item["key"] in keys or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,119}", item["key"]):
            raise ValueError("Duplicate symbol or invalid key")
        for axis in ("width", "height"):
            if type(item[axis]) is not int or not 1 <= item[axis] <= 8192:
                raise ValueError("Invalid placement dimensions")
        fallback = item["fallbackImageName"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,120}", fallback):
            raise ValueError("Invalid fallback image name")
        seen.add(pair)
        keys.add(item["key"])
        groups.setdefault(group, []).append(item)
    lines = ["// Generated offline by generate-catalog.py. Commit this file; do not edit it.", "import SwiftUI", "import AssetLib", "", "enum AssetCatalog {"]
    refs = []
    for group, items in groups.items():
        lines.append(f"    enum `{group}` {{")
        for item in items:
            member = item["symbol"][1]
            lines.append(f'        static let `{member}` = AssetReference(key: "{item["key"]}", width: {item["width"]}, height: {item["height"]})')
            refs.append(f"`{group}`.`{member}`")
        lines.append("    }")
    lines += [f"    static let all: [AssetReference] = [{', '.join(refs)}]", "}", "", "@MainActor struct AppArtwork {", "    let store: AssetImageStore", "    var bundle: Bundle = .main"]
    for group, items in groups.items():
        accessor = group[0].lower() + group[1:]
        lines += [f"    var `{accessor}`: `{group}` {{ `{group}`(store: store, bundle: bundle) }}", f"    @MainActor struct `{group}` {{", "        let store: AssetImageStore", "        let bundle: Bundle"]
        for item in items:
            member = item["symbol"][1]
            lines.append(f'        var `{member}`: Image {{ store.image(for: AssetCatalog.`{group}`.`{member}`, fallback: Image("{item["fallbackImageName"]}", bundle: bundle)) }}')
        lines.append("    }")
    return "\n".join(lines + ["}", ""])

if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate-catalog.py catalog.json Artwork.generated.swift")
    Path(sys.argv[2]).write_text(generate(json.loads(Path(sys.argv[1]).read_text())))
