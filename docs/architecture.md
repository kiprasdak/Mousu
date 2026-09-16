# Architecture

Mousü is one unprivileged macOS process. Swift Package Manager builds three modules:

| Module | Responsibility |
| --- | --- |
| `MousuCore` | Device identity, profile resolution, persistence and scroll policy |
| `MousuNative` | C/Objective-C boundary for HID services and scroll-event attribution |
| `Mousu` | SwiftUI/AppKit interface, device discovery, input control, property recovery and Metal rendering |

## Input and identity

Accessibility is requested through setup. Input Monitoring, raw HID reports and
keyboard events are not used. Built-in devices are excluded from control.
The bridge runtime-checks the macOS SPI required for per-device properties and
sender attribution. Unsupported or unidentified input passes through unchanged.

A dedicated event-tap thread transforms scrolling against immutable per-sender
configuration snapshots. Its callbacks do not access disk, network or UI state.
Flat pointer response changes supported properties on each HID service, not
global mouse preferences. Continuous scrolling retains phase and momentum.

Connection IDs route live events; stable, trustworthy hardware identifiers restore
individual profiles. Anonymous connections get session-only identities. Shared
model cards are explicit opt-ins. Their stored fingerprints can expand to an
unambiguous anonymous connection with the same reported model name, vendor and
pointer function. Card names and connection-label overrides are presentation only.
Shared cards never replace the actual sender IDs used by the input engine.

## Persistence and recovery

Versioned preferences and a recovery journal live in
`~/Library/Application Support/Mousu/`. Writes are atomic. Unknown schemas and
invalid files fail without replacing saved data. No input history is recorded.

Before changing an HID property, the app journals its original and intended
values. Restoration writes the original only if the current value still matches
the value Mousü applied. Changes made by other utilities are left alone.
Pause, permission loss and normal quit release owned properties. After a crash,
recovery happens on the next launch and validates device identity before writing.

First-time setup requires Continue after permission is granted. After setup has
been completed, restoring Accessibility resumes control automatically.

## Rendering

The Try area uses Metal through `CAMetalDisplayLink`. The final surface is capped
at 2.5 million pixels and 4096 pixels per axis; the CRT intermediate is capped at
one million pixels. There are at most two submissions in flight. Hidden views
stop rendering, settled Fast mode pauses, and GPU failure uses a static fallback.
Bundling compiles the shared shader source into `TryCanvas.metallib` ahead of time.

## Device metadata

Bundled systemd classification and USB names affect presentation, not input
authorization. `python3 scripts/update-device-database.py` regenerates the JSON
offline; `--check` verifies it. Review the manifest, checksums, licenses and output
before updating source snapshots. Original data and the generator ship in the app;
see [third-party notices](../THIRD_PARTY_NOTICES.md).

The app has no network client, telemetry, privileged helper or automatic updater.
