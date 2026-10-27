# Editor View Modes — v2 architecture (functional core, imperative shell)

Instant, toggleable display modes that visually hide parts of the code
(type annotations, whole code blocks) without touching the buffer.
Copy/undo/search keep operating on the full text.

**v1 shipped and misbehaved** (unstable scrolling, mixed coordinate
systems, a crash on blank lines): folding was bolted onto a widget
whose scroll/window/caret math was all doc-line-based, producing two
intertwined coordinate systems, state split across widget instance
vars, buffer caches and memory cells, and pixel scrolling with no
anchor. v2 is the redesign. UX change from v1: **a folded block
collapses to ONE display row** (`def foo(...) ...` — the `end` line
is part of the fold).

## Principle

Rendering is a pure function of (document, settings, state):

```
DisplayDoc  = project(rope, lang, settings, reveals)   — pure, cached
WindowState = handle(DisplayDoc, events, prev_state)   — pure
Paint       = draw(DisplayDoc, WindowState)            — no decisions
```

The widget is a thin shell: read state once → compute → paint →
write state once. No mid-frame mutations.

## 1. DisplayDoc — the single projection layer

`src/display_doc.cr`. Two levels:

- **Structure** (cheap, whole document, cached by
  `{rope.version, lang, hide flags, reveal gen}`): `row_of` (doc line
  → display row; hidden lines park on their header's row),
  `line_at` (display row → doc line), `rows_count`, `folded_header?`,
  `block_near`. A folded block occupies ONE row: hidden lines are
  `(header...stop]` — the body AND the `end`.
- **Materialized rows** (per visible row, needs fonts): runs carrying
  BOTH the content-x span and the doc column span. Painting and
  hit-testing go through the SAME run list, so they cannot disagree.
  Rows persist across frames (stored on the cached DisplayDoc, keyed
  by font size) — clicks between frames hit-test the real geometry.
  v1's fragment map lived on a widget instance that is rebuilt every
  frame, so its click path silently fell back to full-text measures.

The run-level elision (annotations → dim `...`) and the fold marker
are both just runs the materializer emits; markers carry `c0 == c1`
(line end) for hit-testing.

This replaces: `FoldMap`'s mapping arrays, `@line_frags`, the
`HMODE_SALT`/`SCRLQ_SALT` cells, `x_at_col`/`col_at_x`/`col_x` triple
(one locate/hit pair over runs remains, plus the identity fallback).

## 2. One coordinate boundary

doc↔display conversion exists in exactly two places:
`hit_test(x, y) → doc offset` (clicks, caret entry) and
`locate(doc offset) → (row, x)` (caret paint, selection, jumps).
Everything else iterates display rows or doc lines exclusively.

## 3. Scroll anchor

Scroll state = pixel offset PLUS an anchor: the doc line of the top
visible row. Every frame, before use, v_off is re-derived from the
anchor through the CURRENT structure (`row_of(anchor) * line_h +
intra-row fraction`) — so toggling modes, reveals and edits never
jump the view. `scroll_to_line` maps doc→row directly through
`buffer.display` (it takes the buffer now) — the pending-request
hack dies.

## 4. State

`EditorState` fields (caret, anchor, sticky col, scroll) stay in egui
memory cells — that storage is the imperative shell the class API
(vim layer, status bar, quick-open) already reads. The widget treats
them read-only until the single persist point; all mutations (snap,
reveal, follow) are transforms applied there.

View-mode flags live on `EditorBuffer` (`hide_annotations`,
`hide_blocks`) — they are per-document projection inputs like `lang`;
the app writes them when settings change, so every consumer
(`display`, `vertical_line`, `goto_line` reveal) sees one truth
without reaching into a widget instance or a memory cell.

## 5. Invariants (property-tested)

- `locate(hit_test(x)) == x` round-trip on materialized rows;
- the painted caret x equals `locate(caret)`;
- the display window covers the viewport exactly;
- the top-row anchor's screen position survives toggles/reveals/edits;
- no exceptions on any input class: empty file, blank lines,
  one-line files, EOF without newline, huge files, any caret/scroll.

Fuzz spec: random documents × random edits × random toggles × random
scrolls, asserting the invariants.

## Migration order

1. `DisplayDoc` (structure with fold-to-one-row, materialization API)
   + buffer integration; parity specs for identity projection.
2. Widget consumption rewrite (single window loop, hit-test via rows,
   scroll anchor); delete the v1 machinery.
3. `scroll_to_line`/`vertical_line` through `buffer.display`.
4. Invariant + fuzz specs.
5. UX follow-ups (reveal-on-enter, gutter fold affordances) — later.

## Status

- v1: implemented, then found unstable (kept in git history; this
  document supersedes its "shipped notes").
- v2: SHIPPED. DisplayDoc is the single projection (fold-to-one-row:
  body and `end` hide behind the header), rows materialize onto the
  buffer-cached doc so paint and hit-test share one run list, the
  scroll anchor (TOP_SALT) re-derives v_off through the current
  structure every frame, and the class API (scroll_to_line with a
  buffer, vertical_line, goto_line reveal) reads the buffer's own
  flags — no mode-flag or pending-request memory cells remain.
  Verified: 287 specs green (round-trip and scroll-anchor invariants,
  a 180-frame fuzz over edits × toggles × scrolls × jumps), `rake`
  builds.
