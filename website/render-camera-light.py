#!/usr/bin/env python3
"""Encode the tiny camera-light texture in Rec.2020/PQ; no imaging dependency.

PNG 3 cICP: https://www.w3.org/TR/png-3/#cICP-chunk
ST 2084 OETF maps absolute channel luminance to 16-bit PQ samples.
The browser applies available display headroom; these are encoded, not measured nits.
"""
from pathlib import Path
import struct
import zlib


def pq(nits):
    m1, m2 = 2610 / 16384, 2523 / 32
    c1, c2, c3 = 3424 / 4096, 2413 / 128, 2392 / 128
    power = (nits / 10000) ** m1
    return round(((c1 + c2 * power) / (1 + c3 * power)) ** m2 * 65535)


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def main():
    # Approximately P3 (0.03, 1, 0.005), at 4 × 203-nit reference white.
    # Rec.2020 channel luminances keep a saturated green within the P3 gamut.
    channels = (180, 766, 18)
    luminance = sum(n * w for n, w in zip(channels, (.2627, .6780, .0593)))
    pixel = struct.pack('>HHH', *(pq(nits) for nits in channels))
    scanlines = (b'\x00' + pixel * 16) * 16
    image = b'\x89PNG\r\n\x1a\n'
    image += chunk(b'IHDR', struct.pack('>IIBBBBB', 16, 16, 16, 2, 0, 0, 0))
    image += chunk(b'cICP', bytes((9, 16, 0, 1)))  # BT.2020, PQ, RGB, full range.
    image += chunk(b'cLLI', struct.pack('>II', *([round(luminance * 10000)] * 2)))
    image += chunk(b'IDAT', zlib.compress(scanlines, 9))
    image += chunk(b'IEND', b'')
    target = Path(__file__).resolve().parent / 'assets' / 'camera-light-hdr.png'
    target.write_bytes(image)
    print(f'{target.name}: {len(image)} bytes, encoded luminance {luminance:.1f} nits')


if __name__ == '__main__':
    main()
