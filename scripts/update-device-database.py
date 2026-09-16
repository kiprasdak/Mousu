#!/usr/bin/env python3
"""Fetch pinned upstream snapshots, then generate the offline presentation catalog.

Run --fetch to deliberately update the vendored snapshots. Normal generation and
--check require no network. Change the pinned revisions only after reviewing the
upstream changes. The app never downloads device metadata at runtime.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Resources/DeviceDatabase'
OUTPUT = ROOT / 'Sources/MousuCore/Resources'
SYSTEMD = '17d46d0442f3ce6921d963175731cf0ff5a8c50b'
USBIDS_SHA256 = 'f5a48b0cc8dae1607c2f0bae6b8dc13f2ecef69dbeaeaf34b4be8e280d34dba4'
URLS = {
    '70-mouse.hwdb': f'https://raw.githubusercontent.com/systemd/systemd/{SYSTEMD}/hwdb.d/70-mouse.hwdb',
    'systemd-LICENSES-README.md': f'https://raw.githubusercontent.com/systemd/systemd/{SYSTEMD}/LICENSES/README.md',
    'LGPL-2.1-or-later.txt': 'https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt',
    'usb.ids': 'https://usb-ids.gowdy.us/usb.ids',
    'USB-IDS-permission.html': 'https://usb-ids.gowdy.us/',
}


def classifications(text):
    rules = []
    patterns = []
    properties = {}

    def finish():
        kind = 'trackball' if properties.get('ID_INPUT_TRACKBALL') == '1' else (
            'other' if properties.get('ID_INPUT_3D_MOUSE') == '1' else None)
        if kind:
            rules.extend({'pattern': pattern, 'kind': kind} for pattern in patterns)

    for line in text.splitlines() + ['']:
        if line.startswith('#'):
            continue
        if not line.strip():
            finish()
            patterns, properties = [], {}
        elif line[0].isspace():
            if '=' in line:
                key, value = line.strip().split('=', 1)
                properties[key] = value
        elif line.startswith('mouse:'):
            if properties:
                finish()
                patterns, properties = [], {}
            # Normalize hexadecimal matching fields only; preserve name globs.
            pattern = re.sub(r'v([0-9A-Fa-f]{4})p([0-9A-Fa-f]{4})', lambda m: m[0].lower(), line)
            patterns.append(pattern)
        else:
            raise ValueError(f'Unsupported hwdb match: {line}')
    return rules


def usb_names(text):
    vendors, products = {}, {}
    vendor = None
    for line in text.splitlines():
        if re.match(r'^[0-9a-fA-F]{4}  ', line):
            vendor, name = line.split(None, 1)
            vendor = vendor.lower()
            vendors[vendor] = name
        elif vendor and re.match(r'^\t[0-9a-fA-F]{4}  ', line):
            product, name = line.strip().split(None, 1)
            products[f'{vendor}:{product.lower()}'] = name
        elif line and not line.startswith(('#', '\t')):
            vendor = None
    return {'vendors': vendors, 'products': products}


def is_utf8(data):
    try:
        data.decode('utf-8')
        return True
    except UnicodeDecodeError:
        return False


def main():
    global SOURCES, OUTPUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fetch', action='store_true')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--source-dir', type=Path, default=SOURCES)
    parser.add_argument('--output-dir', type=Path, default=OUTPUT)
    args = parser.parse_args()
    SOURCES, OUTPUT = args.source_dir, args.output_dir
    if args.fetch and args.check:
        parser.error('--fetch and --check are mutually exclusive')
    SOURCES.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if args.fetch:
        for name, url in URLS.items():
            request = urllib.request.Request(url, headers={'User-Agent': 'Mousu-device-catalog-builder'})
            with urllib.request.urlopen(request, timeout=45) as response:
                data = response.read(8_000_001)
            if len(data) > 8_000_000:
                raise ValueError(f'Snapshot too large: {name}')
            if name == 'usb.ids' and hashlib.sha256(data).hexdigest() != USBIDS_SHA256:
                raise ValueError('Upstream USB IDs changed. Review the update, then change USBIDS_SHA256 deliberately.')
            (SOURCES / name).write_bytes(data)
    if hashlib.sha256((SOURCES / 'usb.ids').read_bytes()).hexdigest() != USBIDS_SHA256:
        raise ValueError('USB ID snapshot does not match its pinned checksum')
    hwdb = (SOURCES / '70-mouse.hwdb').read_text()
    # Upstream contains a few legacy Latin-1 names among UTF-8 entries.
    usbids = '\n'.join(line.decode('utf-8') if is_utf8(line) else line.decode('latin-1')
                       for line in (SOURCES / 'usb.ids').read_bytes().splitlines())
    catalog = {'schemaVersion': 1, 'source': f'systemd {SYSTEMD}', 'rules': classifications(hwdb)}
    names = usb_names(usbids)
    assert len(catalog['rules']) > 30 and len(names['products']) > 10000, 'Unexpectedly empty upstream input'
    manifest = {
        'schemaVersion': 1,
        'sources': [{'file': name, 'url': url, 'sha256': hashlib.sha256((SOURCES / name).read_bytes()).hexdigest()}
                    for name, url in URLS.items()],
        'classificationRules': len(catalog['rules']), 'usbVendors': len(names['vendors']),
        'usbProducts': len(names['products']),
        'policy': 'Presentation metadata only. No DPI, button mappings, or Linux input quirks are applied.',
    }
    outputs = {OUTPUT / 'PointerModels.json': catalog, OUTPUT / 'USBNames.json': names,
               SOURCES / 'manifest.json': manifest}
    for path, value in outputs.items():
        content = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n'
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f'Device database is out of date: {path}')
        else:
            path.write_text(content)
    print(f"Verified {len(catalog['rules'])} classification rules, {len(names['products'])} USB product names.")


if __name__ == '__main__':
    main()
