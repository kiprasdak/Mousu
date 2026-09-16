#!/usr/bin/env python3
"""Optional authoring: render both native icon generations and their moving parts.

Pillow and NumPy are only needed when regenerating assets on a Mac with Icon
Composer. The original app documents and foreground artwork are never changed.
"""
from pathlib import Path
from tempfile import TemporaryDirectory
import json
import shutil
import subprocess
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent
ICTOOL = Path('/Applications/Icon Composer.app/Contents/Executables/ictool')
NAMES = ('top', 'wink', 'upper-right', 'left', 'right', 'lower-left', 'pointer')


def components(image):
    rgba = np.array(image.convert('RGBA'))
    pending = rgba[:, :, 3] > 0
    pieces = []
    height, width = pending.shape
    while pending.any():
        y, x = np.argwhere(pending)[0]
        stack = [(int(x), int(y))]
        pending[y, x] = False
        mask = np.zeros_like(pending)
        while stack:
            x, y = stack.pop()
            mask[y, x] = True
            for nx, ny in ((x-1,y),(x+1,y),(x,y-1),(x,y+1)):
                if 0 <= nx < width and 0 <= ny < height and pending[ny, nx]:
                    pending[ny, nx] = False
                    stack.append((nx, ny))
        part = rgba.copy()
        part[~mask] = 0
        pieces.append(Image.fromarray(part))
    # Reading order, with the larger cursor kept last.
    pointer = max(pieces, key=lambda part: np.count_nonzero(np.array(part)[:, :, 3]))
    pieces.remove(pointer)
    pieces.sort(key=lambda part: (part.getbbox()[1] // 80, part.getbbox()[0]))
    return pieces + [pointer]


def render(document, output, generation):
    subprocess.run([
        str(ICTOOL), str(document), '--export-image', '--output-file', str(output),
        '--platform', 'macOS', '--rendition', 'Default', '--width', '1024',
        '--height', '1024', '--scale', '1', '--design-generation', str(generation),
    ], check=True, stdout=subprocess.DEVNULL)
    with Image.open(output) as source:
        result = source.convert('RGBA')
        result.info = source.info.copy()
        return result


def foreground(rendered, plate):
    """Recover native light AND shadow over its own plate using source-over.

Composer exports a composited tile. Solve R = alpha * F + (1-alpha) * B
    channel by channel; the smallest legal alpha retains highlights and shadows
    as a transparent part, without carrying a rectangle of the blue background.
    All nontransparent ink is well inside the opaque part of the native tile.
    """
    rendered_rgb = np.asarray(rendered, dtype=np.float64)[:, :, :3] / 255
    base = np.asarray(plate, dtype=np.float64)[:, :, :3] / 255
    delta = rendered_rgb - base
    needed = np.where(delta >= 0, delta / np.maximum(1-base, 1/255), -delta / np.maximum(base, 1/255))
    alpha = np.ceil(np.max(needed, axis=2) * 255) / 255
    rgb = np.clip(base + delta / np.maximum(alpha[:, :, None], 1/255), 0, 1)
    rgb[alpha == 0] = 0
    layer = Image.fromarray(np.round(np.dstack((rgb, alpha)) * 255).astype('uint8'))
    reconstructed = Image.alpha_composite(plate, layer)
    error = np.abs(np.asarray(reconstructed, dtype=int) - np.asarray(rendered, dtype=int)).max()
    assert error <= 1, f'Native layer reconstruction drifted by {error}'
    return layer


def save_webp(image, path, profile):
    image.save(path, lossless=True, method=6, exact=True, icc_profile=profile)
    with Image.open(path) as encoded:
        assert encoded.convert('RGBA').tobytes() == image.convert('RGBA').tobytes()
        assert encoded.info.get('icc_profile', b'') == profile
    print(f'{path.name}: {path.stat().st_size:,} bytes')


def main():
    if not ICTOOL.is_file():
        raise SystemExit('Install Icon Composer to render the native icon layers.')
    assets = ROOT / 'assets'
    with TemporaryDirectory(prefix='mousu-parts-') as directory:
        temp = Path(directory)
        document = temp / 'Part.icon'
        shutil.copytree(ROOT.parent / 'Resources/Mousu.icon', document)
        config = json.loads((document / 'icon.json').read_text())
        original_groups = config['groups']
        with Image.open(document / 'Assets/Cursor.png') as source:
            pieces = components(source)
        assert len(pieces) == len(NAMES)
        print('Native foreground components:', [(name, part.getbbox()) for name, part in zip(NAMES, pieces)])
        for generation in (26, 27):
            active = render(ROOT.parent / 'Resources/Mousu.icon', temp / 'active.png', generation)
            profile = active.info.get('icc_profile', b'')
            # Keep the approved 26 originals. 27 gets a matching static fallback,
            # responsive active artwork, favicon, and legacy pause frame.
            if generation == 27:
                active.save(assets / 'mousu-icon-27.png', icc_profile=profile)
                for width in (160, 320):
                    save_webp(active.resize((width,width), Image.Resampling.LANCZOS), assets / f'mousu-icon-27-{width}.webp', profile)
                active.resize((32,32), Image.Resampling.LANCZOS).save(assets / 'mousu-favicon-27.png', icc_profile=profile)
                paused = render(ROOT.parent / 'Resources/MousuPaused.icon', temp / 'paused.png', generation)
                save_webp(paused.resize((320,320), Image.Resampling.LANCZOS), assets / 'mousu-icon-paused-27-320.webp', profile)
            config['groups'] = []
            (document / 'icon.json').write_text(json.dumps(config))
            plate = render(document, temp / 'plate.png', generation)
            layers = [plate]
            config['groups'] = original_groups
            (document / 'icon.json').write_text(json.dumps(config))
            for part in pieces:
                part.save(document / 'Assets/Cursor.png')
                isolated = render(document, temp / 'part.png', generation)
                layers.append(foreground(isolated, plate))
            composed = plate.copy()
            for part in layers[1:]:
                composed = Image.alpha_composite(composed, part)
            error = np.abs(np.asarray(composed, dtype=int) - np.asarray(active, dtype=int))
            # Separate exports must preserve the actual native appearance.
            assert np.percentile(error, 99.9) <= 3, np.percentile(error, 99.9)
            atlas = Image.new('RGBA', (320 * len(layers), 320))
            for index, part in enumerate(layers):
                atlas.paste(part.resize((320,320), Image.Resampling.LANCZOS), (320 * index, 0))
            save_webp(atlas, assets / f'mousu-icon-parts-{generation}.webp', profile)
            composed.resize((320,320), Image.Resampling.LANCZOS).save(temp / f'composed-{generation}.png')
            print(f'Generation {generation}: 99.9% reconstruction error {np.percentile(error,99.9):.1f}/255')


if __name__ == '__main__':
    main()
