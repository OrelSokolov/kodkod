# File type icons

16x16 colored SVG badges (rounded square + white glyph) for the file tree.
Colors loosely follow the GitHub language colors where they exist.

## Extension mapping (matches `EXT_ICONS` in `src/file_tree.cr`)

| Icon                     | Extensions |
|--------------------------|------------|
| `crystal.svg`            | `.cr` |
| `ruby.svg`               | `.rb` |
| `python.svg`             | `.py` |
| `rust.svg`               | `.rs` |
| `c.svg`                   | `.c` |
| `cpp.svg`                | `.cc`, `.cpp`, `.h` |
| `javascript.svg`         | `.js` |
| `typescript.svg`         | `.ts` |
| `go.svg`                 | `.go` |
| `java.svg`               | `.java` |
| `zig.svg`                | `.zig` |
| `sql.svg`                | `.sql` |
| `shell.svg`              | `.sh`, `.bash`, `.zsh`, `.fish` |
| `json.svg`               | `.json` |
| `yaml.svg`               | `.yml`, `.yaml` |
| `toml.svg`               | `.toml` |
| `xml.svg`                | `.xml` |
| `markdown.svg`           | `.md` |
| `text.svg`               | `.txt`, `.log`, `.lock`, `.conf`, `.ini` |
| `image.svg`              | `.png`, `.jpg`, `.jpeg`, `.gif`, `.svg`, `.webp`, `.bmp`, `.ico` |
| `archive.svg`            | `.zip`, `.tar`, `.gz`, `.xz`, `.a`, `.o`, `.so`, `.wasm` |
| `file.svg`               | fallback for unknown extensions |

Glyphs are plain fills/strokes (no `<text>`), so they rasterize fine with
nanosvg. `.pem` currently maps to `braces` in `EXT_ICONS`; if a dedicated
key/cert icon is wanted later, add it here and reuse `json.svg`-style braces.
