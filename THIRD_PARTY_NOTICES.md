# Third-party references

Mousü has no third-party package or bundled runtime dependencies. Apple's operating-system frameworks and the Swift toolchain are used under their respective terms and are not vendored into this source repository.

The following projects informed the desired behavior and the investigation of macOS input APIs:

| Project | Role | Upstream license |
| --- | --- | --- |
| [DiscreteScroll](https://github.com/emreyolcu/discrete-scroll) by Emre Yolcu | Fixed-distance wheel scrolling reference | [MIT](https://github.com/emreyolcu/discrete-scroll/blob/master/LICENSE) |
| [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser) by Nick Moore / Pilotmoon Software | Independent scrolling direction reference | [Apache 2.0](https://github.com/pilotmoon/Scroll-Reverser/blob/master/LICENSE) |
| [LinearMouse](https://github.com/linearmouse/linearmouse) | Per-service HID routing and property API research | [MIT](https://github.com/linearmouse/linearmouse/blob/main/LICENSE) |

Mousü independently implements its input policy and UI. It does not include these applications, their binaries, update frameworks, assets, or copied implementations. If future changes adapt upstream source, include that source's required copyright, license, and NOTICE text alongside the adaptation before distribution.

Mousü's app icons are compiled from the Icon Composer documents in `Resources`. Their foregrounds use the shared `MousuSymbol` artwork. SF Symbols used by the interface are provided by macOS and are subject to Apple's terms.

The MacBook frame artwork comes from Apple’s [Product Bezels](https://developer.apple.com/design/resources/#product-bezels), MacBook Pro M5 package. Apple artwork remains subject to Apple’s applicable terms and is not covered by Mousü’s source terms.

Copyright © 2026 kiprasdak. Mousü's original source is licensed under the MIT License in `LICENSE`. Third-party artwork and data retain their respective terms.

## Bundled device metadata

Mousü includes data, not drivers or runtime libraries, from these projects:

- **systemd mouse hardware database**, revision
  `17d46d0442f3ce6921d963175731cf0ff5a8c50b`. The original
  `70-mouse.hwdb`, project licensing statement, and LGPL-2.1-or-later text
  are in `Resources/DeviceDatabase`. `PointerModels.json` is a modified
  extraction made by Mousü on 2026-09-14: only trackball/3D-pointer
  classification rules are retained; hexadecimal match fields are normalized.
  This derived data retains the upstream LGPL-2.1-or-later licensing.
  The original source, generator, and generated data are shipped with the app.
  No systemd executable, parser, library, DPI setting, or Linux input quirk
  is included in Mousü's input implementation.
- **USB ID Repository**, snapshot 2026.06.26, maintained by Stephen J. Gowdy
  and its contributors, obtained from <https://usb-ids.gowdy.us/usb.ids>.
  Mousü uses the repository's **BSD-3-Clause** licensing option for its data.
  `usb.ids` preserves the original attribution. The repository's permission
  statement and BSD terms are in `Resources/DeviceDatabase`.
  `USBNames.json` extracts vendor/product names and normalizes legacy text
  encoding. It does not contain per-device identifiers or user information.

`Resources/DeviceDatabase/manifest.json` records source URLs, immutable
systemd revision, snapshot checksums, and generated counts. Run
`python3 scripts/update-device-database.py` to regenerate the data offline,
or `--check` to verify reproducibility. In the app, these sources and notices
are under `Contents/Resources/DeviceDatabase`, alongside the generated
`Mousu_MousuCore.bundle`. The app performs no online device lookup.
