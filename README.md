# kodkod

<p align="center"><img src="assets/kodkod.png" alt="kodkod logo" width="168"></p>

A code editor (VSCode/Zed-like) built on
[egui-cr](../egui.cr): a rope buffer for huge files, syntax
highlighting via the [highlight.cr](../myshards/highlight.cr) shard
(a 1:1 port of the highlight.js 11 engine, 37 common languages), a
lazy-loading file tree, an image viewer tab (PNG/SVG), and a basic
VIM modal layer.

## Build & run

```sh
shards install          # once (egui-cr comes in as a path dependency)
rake build:dev          # → bin/kodkod (fast iteration)
./bin/kodkod            # or: ./bin/kodkod file.cr --dir .
rake spec               # headless spec suite, no GPU needed
```

A dev build runs 10-100× slower than release (no `--release`). For
everyday use:

```sh
rake build:release      # shipped binary
OPT=-O3 rake build:dev  # middle ground: optimized, no full release
```

The native egui-cr static library is built automatically on first
build (or set `EGUI_DIR` if egui.cr lives elsewhere).

## Keyboard

| Keys | Action |
| --- | --- |
| Ctrl+N / Ctrl+O / Ctrl+Shift+O | new tab / open file / open folder |
| Ctrl+P | go to file (fuzzy search over the workspace) |
| Ctrl+S / Ctrl+Shift+S | save / save as |
| Ctrl+W / Ctrl+Q | close tab / quit |
| Ctrl+Tab / Ctrl+Shift+Tab | next / previous tab |
| Ctrl+F | find (Enter/Shift+Enter = next/prev) |
| Ctrl+Comma | settings (font size, theme, hidden files…) |
| F5 | refresh explorer |
| Ctrl+Alt+V | toggle VIM mode |

## VIM mode

Modes: normal / insert / visual / command. Supported: motions
(`h j k l 0 ^ $ w b e gg G {n}G`), operators (`x r dd D yy cc C`),
change/delete (`cw dw …` counts included), put (`p P`), visual —
charwise `v` (inclusive) and linewise `V`, motions extend the
selection, `d y c` operate, `o` swaps the ends — undo/redo (`u
Ctrl+R`), registers (`"ayl`
etc.), `:` command line (`:w :q :wq :q! :{n}`), one unnamed +
lettered registers.

## Architecture

```
src/
  kodkod.cr          entry point
  app.cr             shell: tabs, explorer, menus, search, status bar
  code_editor.cr     the editor widget (gutter, scrollbars, virtual rows)
  editor_buffer.cr   buffer + caret/selection state, re-highlights on edit
  vim_mode.cr        modal input layer over the widget's caret cells
  file_tree.cr       lazy-loading directory tree
  quick_open.cr      Sublime-style Ctrl+P fuzzy file finder
                      (fuzzy.cr is the scorer)
  file_viewer.cr     the image tab: PNG (stb_image) / SVG (NanoSVG),
                     wheel zoom, drag pan, double-click refits
  rope.cr            the text buffer (piece-free rope; huge files)
  syntax/
    syntax.cr        facade: flat (scope, text) tokens over highlight.cr
    palette.cr       scope → color
    grammars/        crystal (highlight.js has none); the other 37
                     languages come from the shard
spec/                122 examples, headless (no GPU)
```

Syntax highlighting is delegated to the highlight.cr shard (a path
dependency, `../myshards/highlight.cr`): 37 common languages out of
the box, plus kodkod's own Crystal grammar registered into the
shard's HLJS instance at require time. Highlighting re-runs per edit
and is disabled beyond 512 KB (`HIGHLIGHT_MAX_CHARS` in
`editor_buffer.cr`).
