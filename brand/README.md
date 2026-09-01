# Wallspan brand assets

The SVGs here are the source of truth. Everything else — the `.icns`, the menu bar glyph
drawn in Swift — is derived from them, and should be regenerated rather than edited.

| File | Use | Consumed by |
| --- | --- | --- |
| `wallspan-mark.svg` | Mark alone (232×126). Three panels cut from one continuous field. | nothing yet |
| `wallspan-lockup-horizontal.svg` | Default lockup, dark ink. | nothing yet |
| `wallspan-lockup-horizontal-onDark.svg` | Same, white ink. | nothing yet |
| `wallspan-lockup-stacked.svg` | Square-ish crops, About box, avatars. | nothing yet |
| `wallspan-lockup-stacked-onDark.svg` | Same, white ink. | nothing yet |
| `wallspan-icon.svg` | App icon artwork, 96×96 at 22px corner radius. | `AppIcon.icns`, via `Scripts/make-icon.sh` |
| `wallspan-menubar-template.svg` | 16×16 menu bar glyph. `currentColor`, so it works as a template image. | `Sources/WallspanApp/BrandGlyph.swift` — transcribed, not loaded |
| `wallspan-banner-light.svg` | README banner, 1280×400. | `README.md` |
| `wallspan-banner-dark.svg` | Same, dark theme. | `README.md` |
| `AppIcon.icns` | Generated. Copied into `Wallspan.app/Contents/Resources` by `Scripts/make-app.sh`. | |

## Tokens

- Accent `#3D7BE8`
- Ink `#14171C`
- Field gradient (bottom-left → top-right): `#1E3A6E` → `#3D7BE8` → `#9CC2F8`; on dark
  backgrounds `#24406F` → `#3D7BE8` → `#8FBAF7`
- Typeface: system UI (SF Pro on macOS), semibold, tight tracking

## Rules

- The seam belongs to the wordmark only. Icons and the menu bar glyph stay panel-only so they
  hold at 16px.
- Never repeat the panel motif twice in one composition — if a screenshot or scene is present,
  use the wordmark alone.
- Don't recolor the panels individually; they are windows onto one image, which is the whole
  idea.

## Regenerating the app icon

```sh
Scripts/make-icon.sh          # needs librsvg: brew install librsvg
```

The `.icns` is committed because CI runners have no librsvg, and an icon generated at build
time would therefore be missing from every released `.app`. The script pads the artwork onto
the macOS 824-of-1024 icon grid; rendering it edge to edge looks oversized beside other Dock
icons.

## The menu bar glyph is transcribed, not loaded

`BrandGlyph.swift` redraws the three rects in `wallspan-menubar-template.svg` rather than
bundling an image. A SwiftPM `resources:` declaration emits a separate
`WallspanApp_WallspanApp.bundle` that `make-app.sh` does not copy into the app, so
`NSImage(named:)` would work under `swift run` and return nil in the shipped bundle. If the
glyph's geometry changes here, change it there too.

## A note on the type

The wordmark is live SVG `<text>` in a system font stack, so it renders as SF Pro on macOS and
falls back to Arial/Helvetica elsewhere. Off Apple platforms "Wall" sets slightly wider and its
gap to the accent seam tightens — visibly tighter at banner scale, not collided. Outlining the
letters to paths would make rendering byte-identical everywhere, at the cost of text that can
no longer be re-set.
