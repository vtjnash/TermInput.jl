# TermInput.jl

Text input for the terminal: a line to answer a question in, a box to write a
paragraph in, a list to pick one of and a question only a named key answers,
drawn wherever your own TUI puts them.

The name is the design. An HTML `<input>`, `<textarea>` and `<select>` are a
place to type or choose inside a page that is not about typing: the page owns
the layout, the element owns the caret and the keys, and what comes back out is
a string or an option. This is that, for a terminal.

```julia
using TermInput
import TermInput: render, handle!, text

ta = TextArea("Comment", "on src/parse.jl:42")
print(render(ta, 80, 24))               # `h` rows of exactly `w` columns
if handle!(ta, key) === :unhandled      # not an edit, so it is yours
    key == 19 && post(submission(ta))   # ...and this is what `^s` means
end
```

Nothing here reads stdin, holds raw mode, or runs a loop. A host has all three
already, and a widget that insisted on its own would be one you cannot put in
the program you are writing.

Nor does it decide when you are finished. The keys a widget claims are the
ones that edit its text or move its cursor, and what `^s` or `↵` or escape mean
over the top of that is the host's. A `Choice` does not pick either: `↵` and
its digits come back, and `picked(c, k)` says which option they would pick, so
what picking *does* stays the host's too.

## The picker and the question

A `Choice` is a list in a box with a `LineInput` at its head. Typing narrows
the list - by the lines under an option as well as the option - and the query
edits with every key a `LineInput` has. `↑`/`↓` and `^p`/`^n` move the cursor
an option at a time, and an option of several lines stays whole in the box
(`listwindow`, which is exported for a host's own lists). `numbered = true`
puts the first ten on `1`-`9` and `0`, for a list reached by memory rather than
by reading.

`picked` and `answer` are exported. `click!`, and a `Choice`'s `query`,
`query!`, `selected` and `matches`, are names a host is likely to have already,
so they are public and imported by name the way `render` and `handle!` are.

`click!(c, kind, x, y, at; window)` is the mouse, against where the last
`render` put the rows: a press moves the cursor, the wheel moves it three, a
double click answers `:pick` and a press outside the box `:unhandled`. The time
and the double click's window are arguments, since a terminal reports two
presses as two and a widget that read the clock could not be tested without
waiting.

A `Confirm` is the question a `Choice` of two would be the wrong answer to: the
yes is already under the cursor there, and `↵` takes it. Here only the keys it
names answer - `answer(c, k)` says which, 0 for no - and everything else is no,
escape included unless the question names it.

## What it does that a `readline` does not

* **It is a function of state and a size.** `render(v, w, h)` returns `h` rows
  of exactly `w` display columns and nothing else - no cursor moves, no
  clearing, no assumption about where on the screen it is. That is what lets a
  composer be drawn in a column beside something else, and it is why the whole
  of this package can be tested without a tty.
* **A key it does not claim comes back.** `handle!` answers `:unhandled` rather
  than swallowing the key, so a host's own bindings keep working inside
  somebody else's composer. There is no callback table to register with,
  because there is nothing to register with it - and "finished", "cancelled"
  and "may an empty one be sent" come back the same way, since a text box
  cannot answer those for every program that embeds one.
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

Every key here either edits the text or comes back as `:unhandled`. The keys
that *finish* - `^s`, `↵`, escape, `^g` - are in the table as **host's**: the
widget hands them over, and the row says what a host would sensibly do with
them. The two text widgets do not bind the same set either, and where they
differ the cell says which. A `Choice`'s query is a `LineInput`, so it binds
what a `LineInput` does, and the keys that would move it take the cursor
instead.

| key | readline calls it | here |
|---|---|---|
| `^b` `^f` | backward-char, forward-char | ✅ and the arrows |
| `^p` `^n` | previous-history, next-history | ✅ `TextArea` only, as previous-line / next-line, and so are `↑`/`↓`. A `LineInput` has no second line to reach and no history to walk, so all four come back. A `Choice` moves its cursor with them |
| `^a` `^e` | beginning-of-line, end-of-line | ✅ and Home / End |
| `⌥b` `⌥f` | backward-word, forward-word | ✅ and ctrl-arrows |
| `^d` | delete-char | ✅ and Delete. Not end-of-file on an empty buffer - leaving is the host's |
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
| `↵` `^j` | accept-line | ✅ splits the line in a `TextArea`, which is an edit. 🔸 host's in a `LineInput`, where there is no line to split, and in a `Choice`, where `picked` says which option it takes |
| `^s` | forward-search-history | ❌ not relevant - no history. 🔸 comes back, which is what lets a host make it the key that finishes a multi-line buffer, since `↵` cannot be. Note it is XOFF under terminal flow control, so a host has to have cleared `IXON` for it to arrive at all |
| `^r` | reverse-search-history | ❌ not relevant - no history, and nothing binds it, so it is free for a host |
| `^l` | clear-screen | ❌ not relevant - the host draws the frame and owns the screen |
| `^c` | (SIGINT, not a binding) | ❌ not relevant - the host owns the signal |
| `esc` `^g` | (esc is a terminal key; `^g` is abort) | 🔸 host's - abandoning a buffer is not something a text box should decide the cost of, and `isblank` is what to ask before deciding |
| `⌥<` `⌥>` `⌥.` | history motion, yank-last-arg | ❌ not relevant - no history |
| `^x^e` | edit-and-execute-command | ✅ `TextArea` only, as `⌥e` and `^o` - `⌥e` is what the Julia REPL binds to the same move. A one-line field has nothing worth opening an editor for |
| `^@` `^x^x` `^w`-as-kill-region | set-mark, exchange-point-and-mark, kill-region | ❌ not relevant - there is no mark and no region |
| `^]` `⌥^]` | character-search | ❌ not relevant |
| `↹` | complete | ❌ not relevant - there is nothing here to complete against |
| PgUp / PgDn | (not readline) | ⬜ skipped - paging needs to know how tall the box is, and `handle!` takes a key and no size |

Two-key chords are the reason several of those are skipped rather than absent:
nothing here holds state between keystrokes, so `^x`-anything would be the first
thing to need it.

## Markdown, as rows

`markdown_rows` draws a parsed `Markdown.MD` the way a widget is drawn: rows of
exactly `w` display columns, and nothing else. It is here because a comment in
a terminal program is a paragraph somebody wrote, drawn beside everything else
on the screen, and the rows have to fit that screen the way a text area does.

```julia
using TermInput, Markdown
import TermInput: MarkdownStyle

md = Markdown.parse(body)                      # the host parses
rs = markdown_rows(md, 80; style = MarkdownStyle(bold = ("\e[1m", "\e[22m")),
                   breaks = true)
rs[i].text     # the row: exactly 80 columns, escapes inline
rs[i].src      # the written line it came from, unstyled - what a copy yields
rs[i].first    # whether this row starts that line
```

* **The host parses.** A flavor is about where the markdown came from - GitHub's
  tables, its intraword underscores - and not about the terminal, so the
  renderer takes an ordinary tree.
* **Every row knows its line.** A paragraph wrapped over three rows is one
  `src`, with `first` on the first, so copying rows back out gives the lines as
  they were written, not as they were wrapped.
* **Styles are pairs, passed in.** `MarkdownStyle` is one `(on, off)` pair per
  thing that is styled - headings by level, emphasis, code spans and blocks,
  links, quotes, admonitions by category, tables, rules - all empty by default,
  which draws with no escapes at all. Each piece of a row is closed behind
  itself, so a code span that wraps is closed at the end of one row and opened
  on the next, and the padding is never painted.
* **`breaks = true`** makes a newline inside a paragraph a line break, as
  GitHub draws a comment, rather than a space, as a document is read. Julia's
  `Markdown` keeps the newline from 1.14; before that there is none to act on.
* **Tables fit.** A table is drawn in `style.box` at its indent - inside a list
  or a quote too - as wide as its cells, and when that is too wide the widest
  columns are narrowed first and their cells wrapped rather than cut.
* **Links are labels.** Where a url goes - a footnote, an OSC 8 link, nowhere -
  is the host's.
* **Anything unknown is its text.** An element a later Julia adds, or one an
  older one lacks, is drawn as `Markdown.plain` draws it, unstyled: a version
  skew costs styling and never text.

A code block is highlighted where its language has a highlighter:
`highlight(lang, code)` answers byte ranges and the face each is in, and
`style.faces` says how each face is drawn. The method here is a stub for every
language; a host that wants one adds a method for its own `lang`.

## The box, and the measuring

The border is drawn from `BOXES`, this package's own table of box characters -
`ROUNDED`, `SQUARE`, `HEAVY`, `DOUBLE` and `MINIMAL_HEAVY_HEAD`, by the names
Term gives them - and which one is `CHROME[].box`, set beside the weights it is
painted in. Nothing here depends on Term.

The measuring is this package's own, and deliberately so. Term's `Panel`
measures *markup*, which is wrong here in both directions at once. A title or a
note a host has already styled with raw SGR is counted as characters, so a line
that fits is wrapped and the panel elides its own tail. And a buffer full of
prose is not markup at all, so a `{` somebody typed is read as a tag and
silently deleted - which is the more damaging half, because what is lost is
what was written. So `awidth`, `afit`, `apad` and `awrap` work against real
display widths. They are exported, since a host laying a widget out beside
something else has the same problem one step out.

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
| finishing | `esc` quits the app; the text is read off the field | the host's - the key comes back and the host says what it meant |
| measuring | `Panel`, so markup | display width |
| input | `readkey` under `bytesavailable`, polled | one key code, from whatever loop the host has |

The last row is the one that decides the others: a widget cannot have a cursor
until something can tell Left from Escape-then-`[`-then-`D`, and this one takes
a key code from a host that has already done that.

## What is exported, and what is only public

Exported is what a host driving a widget writes on every call, under names
specific enough that it is unlikely to have them already: the four widgets and
their hints, `submission`, `isblank`, `picked`, `answer`, `listwindow`,
`TextBuffer`, `suspend` and `compose_external`, the escape sequences for the
mouse and bracketed paste, the measuring (`awidth`, `astrip`, `afit`, `apad`,
`amid`, `awrap`), `markdown_rows`, and the key vocabulary.

Public and not exported is the rest of the API, which is either a name a host
is likely to have already or one it uses once, where it sets a widget up:

* the widget protocol - `render`, `handle!`, `text`, `paste!`, `click!` - and a
  `Choice`'s `query`, `query!`, `selected` and `matches`
* `TextBuffer`'s operations - `settext!`, `curline`, `move!`, `newline!`,
  `insertblock!`, `backspace!`, `deletechar!`, `killline!`, `killtostart!`,
  `deleteword!`, `killwordforward!`, `kill!`, `yank!`, `transpose!`,
  `wordstart`, `wordend`, `bufferrows`
* the box - `dialogbox`, `centred`, `boxstyle`, `Box`, `BoxLine`, `BOXES`,
  `CHROME`, `DIALOG_WIDTH` - and
  what a host drawing a field or a list of its own shares with the widgets:
  `drawfield`, `column`, `oneline`, `notetext`, `doubled`, `DOUBLECLICK`,
  `ESCAPE`
* `MarkdownStyle`, `MDRow` and `highlight`, which a host drawing markdown
  builds, reads and extends
* `ACTIONS`, which is what `handle!` answers

```julia
import TermInput: render, handle!, text
```

`public` is Julia 1.11's; on 1.10 the same names are there, and simply not
marked.

## Configuration

Every widget is `Widget(title, note, ...)`. `note` is what is said under the
title, a string or a vector of rows (`notetext`), and is optional where nothing
follows it. Every widget has a `hint` - the keys it owns, which a host adds its
own to - and a `maxwidth`, `DIALOG_WIDTH` but for the `TextArea`.

| | |
|---|---|
| `TextArea(title, note = ""; initial, hint, maxwidth, focused)` | the composer, `TEXTAREA_HINT` and 100 columns by default |
| `handle!(ta, k; suspend)` | how the terminal is handed back while `$EDITOR` runs |
| `LineInput(title, note = ""; initial, hint, maxwidth)` | one line in a box, `LINEINPUT_HINT` |
| `Choice(title, note, labels; numbered, hint, maxwidth)` | one of a list, narrowed by a `LineInput` at its head, `CHOICE_HINT`; `picked(c, k)` says which option `↵` or a digit picks, and `click!(c, kind, x, y, at; window)` is the mouse |
| `Confirm(title, note, keys = ["yY"]; hint, maxwidth)` | a question only named keys answer, `CONFIRM_HINT`; `answer(c, k)` is which, 0 for no |
| `listwindow(hs, sel, top, inner)` | the rows of a list, `hs[i]` lines each, that fit a box with the cursor's whole |
| `v.status` | a line the footer shows instead of the hints, cleared by the next key; not on a `Confirm`, which the next key ends |
| `ta.focused` | whether a `TextArea` draws its cursor. Only there, because it is the one widget a host draws beside something else; a dialog is always the thing that has the keyboard |
| `v.hint` | those hints, which name only the keys the widget owns; a host has to add its own |
| `isblank(v)` | whether there is anything in it - what to ask before deciding what escape costs, or whether an empty one may be sent |
| `CHROME[]` | the weights it is painted in - `strong`, `quiet`, `focus` (a `Choice`'s cursor) and `reset` - and the `box` it is drawn with, one of `BOXES` |

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
