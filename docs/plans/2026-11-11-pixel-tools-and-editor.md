# Pixel tools and editor additions: build plan

Goal: make a screenshot something you can measure and sample, not only mark up, and close the remaining gaps in the editor's redaction, overlay and style tools.

ClearShot already has the frozen-screen capture overlay with its magnifier, scrolling capture, text and QR reading, pins, the background tool, crop, resize, rotate and the expandable canvas, combined images, pixelate and blur redaction, spotlight, counters, pen, highlighter, curved and double arrows, Open from Clipboard, Restore Last Capture, name templates, Retina downscaling, Print, URL commands, screen recording and sensitive-info masking. It also already checks for updates and offers to install them (see the README's Updates section), in release builds.

Out of scope: uploading to a cloud bucket. ClearShot promises that nothing is uploaded.

## Milestones

### M1: pixel foundation, and the work that doesn't need it (wave 1, in parallel)

| Task | Delivers |
|---|---|
| Pixel foundation | `PixelSampler` (an RGBA8 buffer of the picture as shown, without annotations: colour at a point, average, darkest in an area, edge scans with a tolerance, flood fill with an area cap); the editor's cached sampler, rebuilt when the picture changes; colour strings (HEX, HEX without #, `rgb()`, `hsl()`, `oklch()`); WCAG 2 and APCA contrast; a "Show sizes in: Points / Pixels" setting |
| Image overlay opacity and before/after GIF | Opacity on a pasted image (digit keys 1–9, 0 and the property bar); File › Export Before/After GIF… writes two frames, without and with the top image |
| Shape fill | A fill and a fill opacity for rectangles and ellipses |
| Bendable arrows and hand-drawn style | A bend handle on every arrow style; a hand-drawn look for rectangle, ellipse, arrow and text, with a stored seed so undo, copy and reopen draw the same shape, and ⌘R to reroll it |
| Editor keys: selection and zoom | Arrows nudge the selection, ⌘-arrows resize it, `[` `]` grow it; Z-click and Z-drag zoom on a spot, ⌘2 zooms to the selection, Space-drag and right-drag pan |
| Automatic save format | Format "Automatic": PNG for flat, text-heavy pictures and JPEG for photographic ones; a transparent picture is always PNG |
| Capture overlay extras | In area selection: hold Z for a 10× zoom around the cursor, hold ⌘ to slow the cursor, WASD nudges it by one point |

### M2: pixel inspection and redaction (wave 2, needs the foundation)

| Task | Delivers |
|---|---|
| Colour copy | Tab copies the colour under the cursor, ⇧Tab the darkest colour in 20×20 (text colour), ⌥Tab a selection's average; a chip by the cursor shows the value; the copy format is a setting |
| Ruler | Holding an arrow key measures from the cursor to the nearest edge each way along that axis (⇧ for the outer size, the scroll wheel sets the tolerance); a click imprints it as an editable ruler annotation |
| Smart selection | ⌘-click selects a flat-colour region; ⌥A fits a selection to its content (⌥ previews); a click on one edge trims that edge; a padding stepper |
| Magnifier annotation | A zoomed callout of part of the picture, 2×–8×, round or rounded square, with a connector; it never shows what a redaction hides |
| Object removal | A new redaction style, Erase, that fills an area from the pixels around it; Delete on a pixel selection applies it |
| Text-only redaction | A "Text only" switch: the chosen style covers only the words in the area |
| Contrast and guides | The contrast of a selection's two main colours above it (WCAG 2, ⌥-click for APCA); ⌥S and ⌥D show a vertical or horizontal guide, and a click imprints it |

### M3: integration and release

| Task | Delivers |
|---|---|
| Merge and document format | All branches merged; one document-version bump covering the new objects and fields, with older builds refusing newer documents |
| Shortcuts and README | Every new key checked against Settings › Annotate › Tool shortcuts and listed in the README |
| Full check | Unit tests, a Release build and a review of redaction safety: export renders that prove hidden pixels stay hidden |

## Rules for every task

- Logic goes in `ClearShotKit` with unit tests; the app target holds only the UI wiring.
- Don't bump the document version in a feature task; record the new fields in the PR description. M3 bumps it once.
- New fields decode with a default, so existing documents still open.
- A new plain-letter key must not collide with a tool letter. When it does, it works only with a selection, or takes a modifier.
- Large pictures (6K displays, scrolling captures up to 16 383 px) must stay responsive: work on the cached buffer, cap flood fills, and do heavy work off the main thread.
