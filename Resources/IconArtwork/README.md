# Icon artwork

`Cursor.png` and `CursorPaused.png` are transparent foregrounds generated from
`Sources/Mousu/MousuSymbol.swift`. The editable designs are `../Mousu.icon` and
`../MousuPaused.icon`; their backgrounds and glass materials belong to Icon Composer.

Regenerate the foregrounds from the repository root in Bash:

```sh
source scripts/environment.sh
"$MOUSU_SWIFTC" -sdk "$SDKROOT" -target "$MOUSU_TRIPLE" \
  -module-cache-path "$MOUSU_ROOT/.build/ModuleCache" \
  scripts/GenerateIconLayers.swift Sources/Mousu/MousuSymbol.swift \
  -parse-as-library -o .build/generate-icon-layers
.build/generate-icon-layers Resources/IconArtwork
cp Resources/IconArtwork/Cursor.png Resources/Mousu.icon/Assets/Cursor.png
cp Resources/IconArtwork/CursorPaused.png Resources/MousuPaused.icon/Assets/CursorPaused.png
```

`scripts/bundle` compiles both designs with Xcode's `actool`, includes `Assets.car`
and `Mousu.icns`, and merges the generated icon metadata before signing. Global
pause switches the Dock icon to the paused asset; window branding remains unchanged.
