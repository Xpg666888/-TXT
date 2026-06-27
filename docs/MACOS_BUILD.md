# macOS Build Guide

`Forever字幕工厂` cannot be built as a `.app` on Windows.  
Build must run on a real macOS machine (or macOS CI runner).

## 1) Prepare

- macOS 12+
- Python 3.10/3.11
- Xcode Command Line Tools

```bash
xcode-select --install
```

## 2) Build .app

From project root:

```bash
chmod +x scripts/build_macos.sh scripts/package_macos.sh
./scripts/build_macos.sh
```

Output:

- `dist/ForeverSubtitleFactory.app`

## 3) Package for distribution

```bash
./scripts/package_macos.sh
```

Output:

- `release/ForeverSubtitleFactory-macos.zip`

## Notes

- If you want custom icon on macOS, place `resources/app.icns`.
- Models are bundled via `--add-data "models:models"`.
- First launch on another Mac may require right-click -> Open (Gatekeeper).
