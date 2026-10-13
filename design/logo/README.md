# Lidless logo

An eye drawn without its upper lid: a pupil above a crescent. Nothing can close over it.

<img src="lidless-lockup.svg" alt="Lidless" width="360">

## Files

| File | Use |
| --- | --- |
| `lidless-lockup.svg` | Mark and name, for light backgrounds. The default. |
| `lidless-lockup-on-dark.svg` | The same for dark backgrounds, with the ember pupil. |
| `lidless-lockup-white.svg` | One colour, for dark backgrounds where a second colour is not possible. |
| `lidless-lockup-stacked.svg`, `-stacked-on-dark.svg` | Mark above the name, for square spaces. |
| `lidless-symbol.svg`, `-on-dark.svg`, `-white.svg` | The mark alone. |
| `menubar/awake.svg`, `rest.svg`, `lid.svg` | The small-size cut, as macOS template glyphs on an 18-point grid. |
| `app-icon.svg`, `app-icon-1024.png`, `AppIcon.icns` | The macOS app icon. |
| `favicon.svg`, `favicon.ico` | For a web page. |
| `social-preview.svg`, `social-preview.png` | 1280 × 640, for the GitHub repository card. |

The app does not load these files. It draws the menu bar glyphs and the app icon in code
(`Sources/Lidless/StatusIcon.swift`, `AppIconArtwork.swift`) from the same numbers, and
`app-icon-1024.png` and `AppIcon.icns` are exported from that code, so they cannot drift apart.

## Colours

| Name | Hex | Where |
| --- | --- | --- |
| Ink | `#17171B` | The mark and the name on light backgrounds; the app icon tile. |
| Paper | `#F4F2EC` | The mark and the name on dark backgrounds. |
| Ember | `#F5A63B` | The pupil, on dark backgrounds only: the light that stays on. |

The logo is one colour first. Ember is an accent, never used on a light background, where it is
too pale to carry the pupil.

## Construction

On a 256-unit square:

- **Pupil**: a disc of radius 42 centred at (128, 106).
- **Lower lid**: the crescent between two arcs that share their ends at (20, 122) and (236, 122).
  The outer arc has radius 121.36 and sags 66; the inner one has radius 165.8 and sags 40. The
  lid is 26 thick in the middle and comes to a point at each corner of the eye.

The **small-size cut** replaces the tapering crescent with a line of constant weight, because the
taper turns to mush below 24 px. On an 18-point square: pupil of radius 3.1 at (9, 6.6); lid, a
1.6-point arc of radius 9.1 centred at (9, 3.9), from (1.75, 9.4) to (16.25, 9.4). Use it at
24 px and below.

The menu bar has three states. Awake: pupil and lid. At rest: the lid alone, an eye closed.
Closed-lid mode: a bar above the pupil, the laptop's lid that cannot come down.

## Using it

- **Clear space**: keep one pupil diameter free on every side.
- **Smallest sizes**: the full mark down to 24 px wide; below that, the small-size cut, down to
  16 px. The lockup down to 120 px wide.
- **Backgrounds**: ink on light, paper on dark. On a photograph or a busy background, put it on a
  solid tile first.
- **Don't** recolour the pupil on a light background, add the upper lid back, stretch, rotate,
  outline or shadow the mark, or set the name in another typeface next to it.

## Type

The name is set in Barlow SemiBold (SIL Open Font License) and converted to outlines: no file
here needs the font installed.

## Status

No trademark search has been done. Before relying on the mark commercially, check it against
existing marks.
