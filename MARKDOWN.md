# Plan: markdown to rows, in TermInput

Markdown turned into rows of exactly `w` columns by TermInput itself, from the
stdlib's parse tree, so that `wl` can stop depending on Term.jl. Written
2026-09-29, against `wl` at `de1b582` and TermInput at `5ee7b4b`. Check items
off as they land; the ones marked **(worklog)** are in the host.

## Why

Term does two things for `wl`: `parse_md` → `apply_style` for every comment
body (`render_md` in `cli/src/browse/markdown.jl`, `show_md` in `ui.jl`), and
highlighting a Julia code block it draws itself. Everything else it touches -
`TERM_THEME[]`, `CodeTheme`, and `Boxes` in TermInput's `boxstyle` - exists only
to feed those two.

Most of the markdown code in `wl` works around the layer in the middle, where
Term turns the tree into `{…}` markup and the markup into escapes:

| workaround | why it exists | after |
|---|---|---|
| `term_md`'s `{{` → `{` | Term's markup is braces | gone |
| `style_code_spans`, `MD_CODE_SENTINEL` | a code span is found in Term's output by a colour nobody else uses | gone: a span is styled as it is written |
| `plain_term` | Term wraps everything in its own resets | gone: no style asked for, no escape written |
| `unwrap_map`, `WIDE_MD` and the second render | Term wraps before we see the text, so a copy has to recover the paragraph by rendering again at 2000 columns and aligning | gone: the renderer knows which row came from which written line |
| `for_term`'s nested tables | Term centres a table beside a bullet | gone: a table is drawn at its indent |
| `for_term`'s `hard_breaks` | Term reflows a newline, GitHub does not | a keyword |
| `[term]` and `[code]` in `theme.jl` | Term's two palettes, set from ours | our own table, read directly |
| the table width bug, FedeClaudi/Term.jl#314 | a table ignores the width | fitted from the start |

And Term costs 0.35 s of every launch through Highlights importing `Pkg`.

Nothing is lost on the Julia `wl` runs on. Term highlights Julia and nothing
else (`tree_sitter_julia_jll` is its only grammar), and only in the blocks it
draws itself: a top-level fenced block is already its own `:plain` node and
"never through Term" (`body_nodes!`), so only indented blocks, blocks nested in
a list or quote, and `wl`'s command line were ever highlighted. Julia's own
highlighter covers the same language from 1.12. The one loss is on 1.11, which
`cli/Project.toml` still allows, where those blocks go plain. The gain is that
highlighting becomes a function the host can call, so the top-level fenced
blocks can have it too (step 9).

## Shape

The same as the rest of the package: a pure function of the input and a size,
no loop, no stdin, no global it reads mid-render.

```julia
using TermInput, Markdown

md = Markdown.parse(body)                        # the host parses; see below
rs = markdown_rows(md, 80; style = st, breaks = true)
rs[i].text     # the row: exactly 80 display columns, escapes inline
rs[i].src      # the written line it came from, unstyled - what a copy yields
rs[i].first    # whether this row starts that line
```

- [ ] **`markdown_rows(md::Markdown.MD, w; style, breaks) -> Vector{MDRow}`**,
      in `src/markdown.jl`, exported. The name is specific enough to export
      under the package's own rule. Rows, not a joined string: every host
      splits one straight back, and the source map is per row.
- [ ] **`MDRow(text, src, first)`**, public. `src` and `first` together are
      what `unwrap_map` produces today, so the host's copy path keeps working
      by construction.
- [ ] **`MarkdownStyle`**, public: a struct of escape pairs, one field per
      thing that is styled (below), empty by default. Passed in, not held in
      a `Ref`, so a render depends on nothing but its arguments. An empty
      field writes nothing, which is what `plain_term` does today. `CHROME[]`
      is the precedent for a global, and this does not follow it: the host
      has a theme already, and building one struct from it on each theme
      change is cheaper than a second global to keep in step.
- [ ] **`breaks::Bool = false`**: a newline inside a paragraph's text is a
      line break, as GitHub draws a comment, rather than a space, as a
      document is read. Julia's `Markdown` keeps the newline in the text since
      1.14; before that the text has none, so the keyword has nothing to act
      on and the default reading is what you get.

Parsing stays the host's. `wl`'s `GFM_FLAVOR` (`gfm_table`'s alignment fix)
and `escape_source` (intraword `_`, shortcodes) are about GitHub, not the
terminal, and they give the renderer an ordinary `Markdown.MD`. **Open:**
whether a GFM flavor belongs in TermInput for other hosts - not until a
second one wants it.

### How a row is built

A block renders to a list of *runs* - `(text, style)` - per written line, and
the line is wrapped with `awrap` at the width left after its indent and
prefix. `awrap` already carries the SGR in force across a break, so a code
span or a link that wraps is closed at the end of one row and reopened on the
next with no rearming by the caller. Every row is then `apad`ed to `w`.

`src` is the line's runs with their text joined and no styles, taken before
the wrap. That is the whole of the source map, and the reason the second
render goes away.

Widths are `awidth`, which is display columns and treats a grapheme as one
unit, never `length` or a count of `Char`s.

## Every element, and what it becomes

What the stdlib's `Markdown` (1.14) can hand over, and what each draws as.
Unknown elements - one a later Julia adds, or one an older one lacks - fall
back to `Markdown.plain` of the element, unstyled, so a version skew costs
styling and never text.

| element | drawn as |
|---|---|
| `Paragraph` | wrapped prose; `breaks` decides a newline in it |
| `Header{n}` | one line in `h1`…`h6`; nothing else carries the level, so the style has to |
| `Bold`, `Italic`, `Strikethrough` | `bold`, `italic`, `strike` around the runs, nested as written |
| `Code` (inline) | `code` around the text, with the backticks kept in `code_tick` - they are part of what a copy produces, as today |
| `Code` (block) | indented two, no border, `codeblock` padded to the width so the block reads as one; lines are hard-wrapped, never reflowed; highlighted when its language has a highlighter (below) |
| `Link` | the label in `link`; the url is the host's, since `wl` already lifts urls to footnotes before rendering (`delink`) and draws OSC 8 at the frame |
| `Image` | its alt text in `link`, the same way |
| `List` | `•` or the number, right-aligned to the widest number, with a hanging indent; a loose list has a blank row between items; nested lists indent by the marker's width |
| `BlockQuote` | `│ ` in `quote` on every row, the content wrapped at `w - 2` |
| `Admonition` | a `│ ` bar and the title in the category's style (`note`, `tip`, `warning`, `danger`, `info`, else `note`); `wl`'s themes already name these five |
| `Table` | box-drawn at its indent, header in `table_head`, rules in `table_rule`; alignment `:l`/`:c`/`:r` per column; fitted to the width - columns start at their widest cell and the widest are narrowed first, down to a floor, with cells wrapped rather than cut |
| `HorizontalRule` | `─` across the width in `rule` |
| `LineBreak` | ends the row |
| `LaTeX` | the source, in `latex` |
| `Footnote` | the reference as `[^n]` in `footnote`; a definition as a paragraph led by it |
| `HTMLBlock`, `HTMLInline` | the source, in `html` - GitHub sanitises most of it away, and the terminal cannot do better than show what was written |

- [ ] The renderer, one method per element, dispatching on the element's
      type. The tree's content vectors are `Vector{Any}`, so that dispatch
      is dynamic whichever way it is written; `TRIM.md` has `wl` far enough
      from `--trim=safe` that this is not what to optimise for, and an
      `isa` chain would be the change if it ever is.
- [ ] The box characters come from TermInput's own table (the step below),
      `boxstyle()` for the table's box.

## Highlighting: Julia on 1.12 and later, a stub otherwise

- [ ] **`highlight(lang, code) -> Vector{Tuple{UnitRange{Int},Symbol}}`**,
      public: byte ranges of `code` and the face each is in. The method in
      TermInput is the stub - no ranges, so the block is drawn in
      `codeblock` alone - for every language, and for Julia on a Julia older
      than 1.12.
- [ ] **`TermInputHighlightExt`**, a package extension on
      `JuliaSyntaxHighlighting` (a stdlib since 1.12, and a dependency of
      `Markdown` there, so loading `Markdown` is what triggers it). It adds
      the Julia method: `lang` of `julia`, `jl` or `jldoctest`, or empty,
      calls `JuliaSyntaxHighlighting.highlight(code)` and reads the `:face`
      annotations off the `AnnotatedString` it returns.

      How the extension adds a method without overwriting the stub, which
      precompilation refuses: the stub is `highlight(::AbstractString,
      ::AbstractString)` and the extension's is `(::AbstractString,
      ::String)`, strictly more specific. A call is static either way. Not a
      `Dict` of highlighters that the extension fills in its `__init__`:
      that is a stored function, and "TermIFrame takes no functions from its
      host" is the same rule.
- [ ] **Faces to styles.** `MarkdownStyle` has a `code` dictionary keyed by
      the face name without `julia_`: `keyword`, `funcdef`, `funcall`,
      `macro`, `string`, `string_delim`, `char`, `cmd`, `regex`, `symbol`,
      `number`, `bool`, `comment`, `operator`, `comparator`, `assignment`,
      `type`, `typedec`, `builtin`, `error`, and so on (the list is in
      `JuliaSyntaxHighlighting/src/`). A face with no entry falls back
      through a fixed table - `string_delim` → `string`, `rainbow_paren_n`
      and the other brackets → `parentheses`, `opassignment` → `assignment`
      → `operator`, `typedec` → `type`, `bool` → `number` - and then to
      nothing.
- [ ] **Say so in the README**: highlighting is Julia's own highlighter where
      the running Julia has one, and a stub everywhere else - other
      languages, and Julia before 1.12. A host that wants more can add a
      method for its own language string; nothing in TermInput needs to
      change for it.
- [ ] Check that a weak dependency on a stdlib the running Julia lacks
      resolves on 1.10 and 1.11 (TermInput's compat is 1.10) and simply never
      loads. If it does not, the stub is all there is before 1.12 either
      way, and the compat moves or the extension moves into the host.

## Steps

1. [x] **TermInput owns its box characters.** `boxstyle()` reads
       `Term.Boxes.BOXES` by `TERM_THEME[].box`; the handful of boxes a theme
       can name become a table here - the shipped themes name only `ROUNDED`
       (`box`) and `MINIMAL_HEAVY_HEAD` (`tb_box`), and `SQUARE`, `HEAVY` and
       `DOUBLE` are worth having beside them, and the
       box is an argument or a field of `CHROME`, not Term's theme. Term
       leaves TermInput's `Project.toml` and the README's "What Term gives
       it" section goes. This is worth doing on its own.
       *Landed as* `Box`, `BoxLine` and `BOXES` (the five, with `head`,
       `head_row` and `row` for a table and no footer lines), with the box a
       field of `CHROME`, so a host sets it beside the weights;
       `boxstyle(name)` looks one up and falls back to `ROUNDED`. A host
       that assigns `CHROME[]` gives all five fields now.
2. [ ] **`src/markdown.jl`**: `markdown_rows`, `MDRow`, `MarkdownStyle`, the
       elements above.
3. [ ] **Tests, with no tty**: one per element, per nesting (a table in a
       list, a code span split across a wrap, a list in a quote), the source
       map (a paragraph wrapped over three rows is one `src`, `first` on the
       first), every row exactly `w` columns, and wide characters and
       combining marks measured as the terminal draws them.
4. [ ] **The extension** and its test, run only where `JuliaSyntaxHighlighting`
       exists.
5. [ ] **(worklog)** `render_md` and `show_md` call `markdown_rows`.
       `nodelines` takes `src`/`first` off the rows; `unwrap_map`, `WIDE_MD`,
       `term_md`, `style_code_spans`, `MD_CODE_SENTINEL`, `plain_term` and
       `for_term` go, `hard_breaks` becoming `breaks = true`.
6. [ ] **(worklog)** `theme.jl` builds a `MarkdownStyle` from the theme.
       `[term]` becomes `[markdown]`, keeping the `md_*` names that already
       say what they are and dropping Term's own (`tb_*`, `emphasis_light`,
       `text_accent`); `[code]`'s tree-sitter capture names become the face
       names above - the three shipped themes are edited, and a theme naming
       a key that is gone is reported the way an unknown one is now.
7. [ ] **(worklog)** `cli/test/suite/markdown.jl` (88 tests) is the acceptance
       test: its assertions are about what GitHub shows, and they should
       hold. Those that assert Term's own drawing - a code block's panel,
       the table's box - are rewritten to the new drawing, one by one, not
       in bulk.
8. [ ] **(worklog)** Term leaves `cli/Project.toml` and both manifests (the
       precompile one stays `cli/`'s plus one entry). DESIGN.md's *Term.jl*
       section goes, and its *Julia's Markdown* one says what the renderer
       relies on; the 0.35 s launch line is re-measured and replaced with
       what launch costs now.
9. [ ] **(worklog)** A top-level fenced block's `:plain` node is drawn
       through `highlight` when its language has one, which it never was
       through Term. Last, and separately, since it changes what the browser
       shows rather than how it is drawn.

## For the agent doing this

- Read `../AGENTS.md` and `../DESIGN.md` first (this checkout is a
  submodule of `wl`); DESIGN.md's *Term.jl* and *Julia's Markdown* sections
  are the behaviours the renderer has to keep or replace.
- Steps 1-4 are commits here, in this repository's style: a lowercase prose
  summary with no prefix, a prose body, via `git commit -F`. Steps 5-9 are
  commits in `wl` (`worklog: summary`), each bumping the submodule to the
  TermInput commit it needs.
- Tests: `julia --project=. test/runtests.jl` here, and
  `julia --project=cli cli/test/runtests.jl` from `wl`'s checkout. The 1.10
  and 1.11 checks in *Highlighting* use `julia +1.10` and `julia +1.11`
  (juliaup has both).
- Tick each box here as it lands, and put anything decided along the way in
  this file, not only in a commit message. When every box is ticked, what is
  still true moves into DESIGN.md and the README and this file is deleted.

## Not doing

- A markdown *parser*. The stdlib's is what `wl` already works around
  (`gfm_table`, `escape_source`), and a second parser is a second set of
  those.
- Highlighting other languages. A host that wants one adds a method.
- Links as OSC 8 inside the renderer. `wl` draws them at the frame, for
  reasons in DESIGN.md (a url Term wrapped, and xterm.js's link markers);
  moving that is a separate change once there is no Term wrapping to work
  around.
