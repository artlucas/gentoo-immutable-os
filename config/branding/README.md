# Branding assets (build-only — none of these files ship in the image)

Sources for the Plymouth boot splash. Stage 40 renders the `*.in` templates, rasterises every
SVG to PNG with `rsvg-convert`, and installs the result plus the theme files into
`$TARGET/usr/share/plymouth/themes/<distro>/`. The SVGs themselves never enter the image.

They live here rather than under `config/rootfs/` for two reasons: they are build inputs, not
image content (same as `config/keys/`), and `render_dest_name()` rewrites `distro` in file
*basenames* only — a `config/rootfs/.../themes/distro/` **directory** would never be renamed.

Everything here is text on purpose. `tests/run-tests.sh` byte-scans every file in the repo for
CR bytes, so a committed PNG or TTF would fail the offline suite; keeping the sources vector
also means the splash rescales for any panel instead of being pinned to one resolution.

| file | what it is |
|---|---|
| `slab-{top,mid,bot}.svg` | one slab of the logomark each, on an identical `0 0 64 64` canvas so the PNGs stack in register. Face opacities 0.6 / 1.0 / 0.82 and the teal fill are baked into the alpha channel; the theme's `SetOpacity()` multiplies on top |
| `wordmark.svg` | "immos" in Archivo Bold, **glyphs converted to `<path>`** — see below |
| `status-left.svg.in` | bottom-left field; `@SPLASH_STATUS_LEFT@` is composed in stage 40 from `UPDATE_CHANNEL` and `VERSION` |
| `status-right.svg` | bottom-right "PRESS ESC FOR DETAILS" hint |
| `distro.plymouth.in` | theme manifest → `<distro>.plymouth` |
| `distro.script.in` | the theme itself → `<distro>.script` |
| `outline-wordmark.py` | the one-time generator for `wordmark.svg` (not run by the build) |
| `make-stub-bmp.py` | composes the `systemd-stub` `.splash` bitmap from the PNGs above, when `SPLASH_BACKEND` includes the stub. Run by stage 40, after the rasterise pass — same sources, same rasterisation, so the stub image and the Plymouth theme cannot drift |

Assets are authored at the **1920×1080 design baseline** in CSS pixels and rasterised at 4×;
the theme script scales by `scale / 4`. Do not change the zoom in one place only.

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
