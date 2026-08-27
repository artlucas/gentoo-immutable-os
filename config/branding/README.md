# Branding assets (build-only — none of these files ship in the image)

Sources for the boot splash. Stage 40 renders the `*.in` templates and rasterises every SVG to
PNG with `rsvg-convert` into a **work directory**, then `make-splash-assets.py` composes those
PNGs into the two artefacts that do ship:

| artefact | where it goes | which window of the boot it covers |
|---|---|---|
| `splash.bin` (sprite tiles) | `/usr/share/<distro>/` on the root filesystem | first modeset → greeter, drawn by `config/splash/splash.c` |
| `splash-<ver>.bmp` | the UKI's `.splash` PE section | firmware → first modeset, blitted by `systemd-stub` |

Neither the SVGs nor the PNGs enter the image. That is the point: the splash ships as
pre-composited pixels, so the image needs no font, no image decoder and no text engine at boot.

They live here rather than under `config/rootfs/` because they are build inputs, not image
content — the same reason `config/keys/` is where it is.

Everything here is text on purpose. `tests/run-tests.sh` byte-scans every file in the repo for
CR bytes, so a committed PNG or TTF would fail the offline suite; keeping the sources vector
also means the splash rescales for any panel instead of being pinned to one resolution.

| file | what it is |
|---|---|
| `slab-{top,mid,bot}.svg` | one slab of the logomark each, on an identical `0 0 64 64` canvas so the PNGs stack in register. Face opacities 0.6 / 1.0 / 0.82 and the teal fill are baked into the alpha channel; the theme's `SetOpacity()` multiplies on top |
| `wordmark.svg` | "immos" in Archivo Bold, **glyphs converted to `<path>`** — see below |
| `status-left.svg.in` | bottom-left field; `@SPLASH_STATUS_LEFT@` is composed in stage 40 from `UPDATE_CHANNEL` and `VERSION` |
| `status-right.svg` | bottom-right "PRESS ESC FOR DETAILS" hint |
| `outline-wordmark.py` | the one-time generator for `wordmark.svg` (not run by the build) |
| `make-splash-assets.py` | composes **both** shipped artefacts from the PNGs above. Run once by stage 40, after the rasterise pass |

`make-splash-assets.py` produces both outputs from one `compose_block()` on purpose. The two
halves of the splash meet on screen at the first modeset, so any drift in geometry or brightness
between them shows up exactly there, as a jump. It also holds the layout constants (`MARK_BOX`,
`GAP`, `PAD_X`, `PAD_Y`) that used to be duplicated in the Plymouth theme script.

Assets are authored at the **1920×1080 design baseline** in CSS pixels and rasterised at 4×
(`BRANDING_ZOOM` in `scripts/lib/common.sh`); the generator divides by its own `ASSET_ZOOM`.
Do not change the zoom in one place only — `tests/test-splash-assets.sh` asserts the two agree.

## Design provenance

Immos Design System handoff → `project/templates/bootsplash/Bootsplash.dc.html`,
`project/components/feedback/Spinner.jsx` (animation "B · Layer pulse"),
`project/assets/logomark.svg`, `project/tokens/{colors,semantic,theme-palettes}.css`.

Resolved token values (dark theme, teal accent): background `#0a0d11` (`--surface-sunken`),
logomark `#0e9c8a` (`--accent`), wordmark `#f6f7f9` (`--text-strong`), status text `#66707f`
(`--text-subtle`).

## Regenerating the wordmark

Archivo is not packaged in Gentoo, so the wordmark is outlined **once**, by hand, and the
result is committed — that is what keeps the build font-free. Redo it only if the brand
wordmark changes:

```sh
pip install fonttools
curl -sL -o archivo.zip \
  https://github.com/Omnibus-Type/Archivo/archive/refs/heads/master.zip
unzip -o archivo.zip 'Archivo-master/fonts/ttf/Archivo-Bold.ttf'
python3 config/branding/outline-wordmark.py \
  Archivo-master/fonts/ttf/Archivo-Bold.ttf > config/branding/wordmark.svg
```

Archivo is OFL-1.1 (Copyright 2020 The Archivo Project Authors). Only glyph outlines end up in
the repo, and the font binary is never redistributed.

The status bar is set in IBM Plex Mono, which **is** packaged (`media-fonts/ibm-plex`, stable
amd64, OFL-1.1) — the builder installs it for `rsvg-convert` to find, and it does not enter the
image. Those two SVGs deliberately use an over-wide canvas with the text anchored to the edge
the splash aligns that field to, so nothing depends on knowing the font's advance width: the
surplus canvas is transparent and always falls towards the screen centre.
