#!/usr/bin/env python3
"""Offline, deterministic Swift symbols + native Image accessors. No network/build-time credentials."""
import json
import re
import sys
from pathlib import Path

def swift_string(value):
    # Escape all non-ASCII/control scalars and backslashes, including Swift interpolation syntax.
    return '"' + ''.join('\\' + c if c in ('"', '\\') else c if 32 <= ord(c) < 127 else f'\\u{{{ord(c):x}}}' for c in value) + '"'

def accessibility(value):
    if not isinstance(value, dict) or not isinstance(value.get("defaultLocale"), str) or not isinstance(value.get("descriptions"), dict):
        raise ValueError("Invalid bundled accessibility descriptions")
    descriptions = value["descriptions"]
    locale = value["defaultLocale"]
    valid_locale = lambda key: isinstance(key, str) and len(key) <= 63 and re.fullmatch(r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*", key)
    if not valid_locale(locale) or not 1 <= len(descriptions) <= 32 or any(not valid_locale(key) for key in descriptions):
        raise ValueError("Invalid accessibility locale")
    keys = [key.lower() for key in descriptions]
    if len(set(keys)) != len(keys) or locale.lower() not in keys:
        raise ValueError("Accessibility requires a unique default locale")
    for text in descriptions.values():
        blanks = "\u0009\u000a\u000b\u000c\u000d\u0020\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"
        if not isinstance(text, str) or not text.strip(blanks) or len(text.encode("utf-16-le")) // 2 > 1000:
            raise ValueError("Invalid accessibility description")
    pairs = ', '.join(f'{swift_string(key)}: {swift_string(text)}' for key, text in sorted(descriptions.items()))
    return f'try! AssetAccessibility(defaultLocale: {swift_string(locale)}, descriptions: [{pairs}])'

def generate(catalog):
    if type(catalog.get("schemaVersion")) is not int or catalog["schemaVersion"] != 1:
        raise ValueError("Unsupported catalog")
    if not isinstance(catalog.get("placements"), list) or not 1 <= len(catalog["placements"]) <= 100:
        raise ValueError("Catalog must contain 1 to 100 placements")
    groups = {}
    seen = set()
    keys = set()
    accessors = {}
    reserved = {"store", "bundle", "all", "AppArtwork", "AssetCatalog", "AssetArtwork",
                "Image", "Locale", "AssetAccessibility", "AssetImageStore", "AssetReference"}
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
        if "bundledAccessibility" in item:
            accessibility(item["bundledAccessibility"])
        if item.get("rendering", "original") not in ("original", "template"):
            raise ValueError(f'Invalid rendering for {item["key"]}: use "original" or "template"')
        seen.add(pair)
        keys.add(item["key"])
        groups.setdefault(group, []).append(item)
    for items in groups.values():
        names = {item["symbol"][1] for item in items}
        if any(name + "Artwork" in names for name in names):
            raise ValueError("Symbol collides with a generated artwork accessor")
    lines = ["// Generated offline by generate-catalog.py. Commit this file; do not edit it.", "import SwiftUI", "import AssetLib", "", "enum AssetCatalog {"]
    refs = []
    for group, items in groups.items():
        lines.append(f"    enum `{group}` {{")
        for item in items:
            member = item["symbol"][1]
            rendering = ", rendering: .template" if item.get("rendering") == "template" else ""
            lines.append(f'        static let `{member}` = AssetReference(key: "{item["key"]}", width: {item["width"]}, height: {item["height"]}{rendering})')
            refs.append(f"`{group}`.`{member}`")
        lines.append("    }")
    lines += [f"    static let all: [AssetReference] = [{', '.join(refs)}]", "}", "", "@MainActor struct AppArtwork {", "    let store: AssetImageStore", "    var bundle: Bundle = .main"]
    for group, items in groups.items():
        accessor = group[0].lower() + group[1:]
        lines += [f"    var `{accessor}`: `{group}` {{ `{group}`(store: store, bundle: bundle) }}", f"    @MainActor struct `{group}` {{", "        let store: AssetImageStore", "        let bundle: Bundle"]
        for item in items:
            member = item["symbol"][1]
            fallback = f'Image(decorative: "{item["fallbackImageName"]}", bundle: bundle)'
            metadata = accessibility(item["bundledAccessibility"]) if "bundledAccessibility" in item else "nil"
            lines.append(f'        var `{member}`: Image {{ store.image(for: AssetCatalog.`{group}`.`{member}`, fallback: {fallback}) }}')
            lines += [f'        func `{member}Artwork`(locale: Locale = .current, requireDescription: Bool = false) -> AssetArtwork {{',
                      f'            store.artwork(for: AssetCatalog.`{group}`.`{member}`, fallback: {fallback}, bundledAccessibility: {metadata}, locale: locale, requireDescription: requireDescription)',
                      '        }']
        lines.append("    }")
    return "\n".join(lines + ["}", ""])

if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate-catalog.py catalog.json Artwork.generated.swift")
    Path(sys.argv[2]).write_text(generate(json.loads(Path(sys.argv[1]).read_text())))
