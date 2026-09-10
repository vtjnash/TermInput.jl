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

## Every readline key, and what became of it

The claim is "the readline keys people's fingers already know", so here is the
whole emacs-mode binding set and what each one does here. **Not relevant** means
the key is about something this is not - a shell's history, a full-screen
program's screen, a region between a mark and the point.

The two widgets do not bind the same set, and where they differ the cell says
which. Everything a `TextArea` binds and a `LineInput` does not comes back as
`:unhandled`, so it is the host's to use.

| key | readline calls it | here |
|---|---|---|
| `^b` `^f` | backward-char, forward-char | ✅ and the arrows |
| `^p` `^n` | previous-history, next-history | ✅ `TextArea` only, as previous-line / next-line, and so are `↑`/`↓`. A `LineInput` has no second line to reach and no history to walk, so all four come back |
| `^a` `^e` | beginning-of-line, end-of-line | ✅ and Home / End |
| `⌥b` `⌥f` | backward-word, forward-word | ✅ and ctrl-arrows |
| `^d` | delete-char | ✅ and Delete. Not end-of-file on an empty buffer: escape is how you leave |
| `⌫` | backward-delete-char | ✅ |
| `^t` | transpose-chars | ✅ |
| `⌥t` | transpose-words | ⬜ skipped - `^t` is muscle memory and this one is not |
| `⌥u` `⌥l` `⌥c` | upcase-word, downcase-word, capitalize-word | ⬜ skipped - trivial to add if somebody wants them |
| `^k` | kill-line | ✅ and it takes the line break when the tail is empty |
| `^u` | unix-line-discard | ✅ back to the start of the line - readline's rule, not zsh's kill-whole-line |
| `^w` | unix-word-rubout | ✅ delimited by whitespace |
| `⌥⌫` | backward-kill-word | ✅ delimited by anything non-alphanumeric, which is the whole reason it is a second key |
| `⌥d` | kill-word | ✅ |
| `^y` | yank | ✅ one slot, and a *run* of kills is one yank |
| `⌥y` | yank-pop | ⬜ skipped - the second entry of a kill ring is somebody using this as their editor. `killed` is a plain string, so a host can keep a ring and set it |
| `^_` `^x^u` | undo | ⬜ skipped - `⌥e` opens `$EDITOR`, where undo, search and your own keymap already are. The biggest of the deliberate omissions, and the one to revisit first |
| `^q` `^v` | quoted-insert | ⬜ skipped - it needs the host's decoder to hand over the next key undecoded, which is a contract this does not have yet |
| `↵` `^j` | accept-line | ✅ splits the line in a `TextArea`; accepts in a `LineInput`, and an empty one is a `:cancel` rather than a submission of nothing |
| `^s` | forward-search-history | ❌ not relevant - no history. `TextArea` binds it to submit instead, since the key that finishes a multi-line buffer cannot be `↵`; a `LineInput` leaves it alone. Note that it is XOFF under terminal flow control, so a host has to have cleared `IXON` for it to arrive at all |
| `^r` | reverse-search-history | ❌ not relevant - no history, and nothing binds it, so it is free for a host |
| `^g` | abort | ✅ same as escape |
| `^l` | clear-screen | ❌ not relevant - the host draws the frame and owns the screen |
| `^c` | (SIGINT, not a binding) | ❌ not relevant - the host owns the signal |
| `⌥<` `⌥>` `⌥.` | history motion, yank-last-arg | ❌ not relevant - no history |
| `^x^e` | edit-and-execute-command | ✅ `TextArea` only, as `⌥e` and `^o` - `⌥e` is what the Julia REPL binds to the same move. A one-line field has nothing worth opening an editor for |
| `^@` `^x^x` `^w`-as-kill-region | set-mark, exchange-point-and-mark, kill-region | ❌ not relevant - there is no mark and no region |
| `^]` `⌥^]` | character-search | ❌ not relevant |
| `↹` | complete | ❌ not relevant - there is nothing here to complete against |
| PgUp / PgDn | (not readline) | ⬜ skipped - paging needs to know how tall the box is, and `handle!` takes a key and no size |

Two-key chords are the reason several of those are skipped rather than absent:
nothing here holds state between keystrokes, so `^x`-anything would be the first
thing to need it.

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
