# TermInput.jl

Text input for the terminal: a line to answer a question in and a box to write a
paragraph in, drawn wherever your own TUI puts them.

The name is the design. An HTML `<input>` and `<textarea>` are a place to type
inside a page that is not about typing: the page owns the layout, the element
owns the caret and the keys, and what comes back out is a string. This is that,
for a terminal.

```julia
using TermInput
import TermInput: render, handle!, text

ta = TextArea("Comment", "on managers.jl:544")
print(render(ta, 80, 24))              # `h` rows of exactly `w` columns
act = handle!(ta, key)                 # :ok | :submit | :cancel | :unhandled
act === :submit && post(submission(ta))
```

Nothing here reads stdin, holds raw mode, or runs a loop. A host has all three
already, and a widget that insisted on its own would be one you cannot put in
the program you are writing.

## What it does that a `readline` does not

* **It is a function of state and a size.** `render(v, w, h)` returns `h` rows
  of exactly `w` display columns and nothing else - no cursor moves, no
  clearing, no assumption about where on the screen it is. That is what lets a
  composer be drawn in a column beside something else, and it is why the whole
  of this package can be tested without a tty.
* **A key it does not claim comes back.** `handle!` answers `:unhandled` rather
  than swallowing the key, so a host's own bindings keep working inside
  somebody else's composer. There is no callback table to register with.
* **The editing model is separate from the view.** `TextBuffer` is lines, a
  cursor, and the operations - `insert!`, `newline!`, `backspace!`,
  `deleteword!`, `killline!`, `move!` - with no screen attached. A program that
  wants the editing and not the box stops there.
* **Both readline word rules, because they differ.** `^w` is unix-word-rubout,
  delimited by whitespace; alt-backspace is backward-kill-word, delimited by
  anything non-alphanumeric. On `/usr/local/lib` the first takes the whole path
  and the second takes only `lib`. Both are wanted, which is why both keys
  exist.
* **The cursor lands where the terminal will put it.** A soft-wrapped text area
  has to map a character offset to the row and column it draws at - `bufferrows`
  - and three counts have to be kept apart to do it: bytes, characters and
  display columns. A byte index into a line with an accent in it throws; a
  character index into one with a CJK character in it draws the block a column
  to the left of the terminal's own.
* **Nothing typed is thrown away.** A key code is *the bytes that arrived*,
  packed big-endian, not a codepoint - see `Keys.K_BASE`. A `Char` in Julia is
  four bytes of UTF-8 held as they came, and arbitrary binary survives a round
  trip through a `String` intact; it is only `codepoint` that refuses, and
  there is no reason to call it. So a paste of anything at all comes out of the
  buffer as the bytes that went in.
* **`⌥e` gives up and opens `$EDITOR`.** A text area is enough to write a
  paragraph in and is not meant to be more: undo, search, syntax and your own
  keymap already exist in the editor you already use. `suspend` is what hands
  the terminal over and takes it back, which is a problem every TUI has and
  none of them has anywhere to put.

## What Term gives it

The border is drawn with Term's box characters, following
`Term.TERM_THEME[].box` - so a composer opened over a screen of `Term.Panel`s
is bordered the way they are, and changing the theme moves all of it.

The measuring is this package's own, and deliberately so. `Panel` measures
*markup*, which is wrong here in both directions at once. A title or a note a
host has already styled with raw SGR is counted as characters, so a line that
fits is wrapped and the panel elides its own tail. And a buffer full of prose is
not markup at all, so a `{` somebody typed is read as a tag and silently
deleted - which is the more damaging half, because what is lost is what was
written. So `awidth`, `afit`, `apad` and `awrap` work against real display
widths, and Term supplies the glyphs. They are exported, since a host laying a
widget out beside something else has the same problem one step out.

## How this differs from `Term.Live`'s `InputBox`

Term has a widget of its own, and the honest summary is that they are not the
same widget. `InputBox` collects keystrokes; this edits text.

| | `InputBox` | here |
|---|---|---|
| cursor | none - characters append at the end | a cursor you can move |
| arrows, home, end | not bound | bound |
| readline keys | none | `^a` `^e` `^k` `^u` `^w` `^d`, alt-backspace, alt-arrows |
| delete | the last character only | before the cursor, under it, by word, by line |
| multi-line | `↵` appends a newline; no wrapping, no row mapping | soft wrap, and the cursor mapped onto the wrapped row |
| finishing | `esc` quits the app; the text is read off the field | `:submit` / `:cancel` back to the caller |
| measuring | `Panel`, so markup | display width |
| input | `readkey` under `bytesavailable`, polled | one key code, from whatever loop the host has |

The last row is the one that decides the others: a widget cannot have a cursor
until something can tell Left from Escape-then-`[`-then-`D`, and this one takes
a key code from a host that has already done that.

## Configuration

| | |
|---|---|
| `TextArea(title, note; initial, allow_empty, hint, maxwidth, suspend)` | the composer |
| `LineInput(title, note; initial, hint, maxwidth)` | one line in a box |
| `v.status` | a line the footer shows instead of the hints, cleared by the next key |
| `v.hint` | those hints; a host that has claimed keys should add to it |
| `TERM_THEME[].box` | Term's, and the box these are drawn in |

## Tests

```bash
julia --project=. test/runtests.jl
```

Everything, with no tty and no setup: `render` is pure, `handle!` takes a key
code, and the one thing that touches a real terminal - `suspend` - is asserted
on the escape sequences it writes. The `$EDITOR` path is driven through
`InteractiveUtils.define_editor` rather than by installing an editor.

## License

MIT. Copyright (c) 2026 JuliaHub, Inc. and Jameson Nash.
