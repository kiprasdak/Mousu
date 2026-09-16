#!/usr/bin/env python3
"""Optional authoring step: create local delivery images from the unchanged PNGs.

Requires Pillow. Serving or validating the website does not require Pillow.
"""
from pathlib import Path
from PIL import Image

ASSETS = Path(__file__).resolve().parent / 'assets'
VARIANTS = {
    'mousu-light': (1512, 2268, None),
    'mousu-dark': (1512, 2268, None),
    'macbook-silver': (1930, None),
    'macbook-dark': (1930, None),
    'mousu-menu-bar-detail-light': (692, 1038, None),
    'mousu-menu-bar-detail-dark': (692, 1038, None),
    'mousu-icon': (160, 320),
    'mousu-icon-27': (160, 320),
}


def main():
    for name, widths in VARIANTS.items():
        with Image.open(ASSETS / f'{name}.png') as source:
            for width in widths:
                target = ASSETS / (f'{name}-{width}.webp' if width else f'{name}.webp')
                image = source if width is None else source.resize(
                    (width, round(source.height * width / source.width)), Image.Resampling.LANCZOS)
                image.save(target, format='WEBP', lossless=True, method=6, exact=True,
                           icc_profile=source.info.get('icc_profile', b''))
                with Image.open(target) as encoded:
                    assert encoded.convert('RGBA').tobytes() == image.convert('RGBA').tobytes(), target
                    assert encoded.info.get('icc_profile') == source.info.get('icc_profile'), target
                print(f'{target.name}: {target.stat().st_size:,} bytes')
    for suffix in ('', '-27'):
        with Image.open(ASSETS / f'mousu-icon{suffix}.png') as icon:
            icon.resize((32, 32), Image.Resampling.LANCZOS).save(
                ASSETS / f'mousu-favicon{suffix}.png', icc_profile=icon.info.get('icc_profile', b''))


if __name__ == '__main__':
    main()
