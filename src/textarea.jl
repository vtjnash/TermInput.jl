# A small multi-line text area, and the contract a host drives it through.
#
# `render` is a pure function of the widget and a size, and `handle!` takes one
# key code and returns what happened. Neither reads stdin, owns a terminal or
# knows what a view stack is, because a host has all three already - and a
# widget that insisted on its own would be a widget you cannot put in the
# program you are writing.

"""
    ACTIONS

What `handle!` answers, for what a widget did with a key.

  * `:ok`         it used the key, and the frame should be drawn again
  * `:unhandled`  not a key this widget uses, so it is the host's

[`click!`](@ref), the mouse, answers one more - `:pick`, for a double click on
an option, which is the one gesture that is not a key and has to be decided
about all the same.

Two values, and the second is the one the design turns on. A text box holds
text and knows how to change it. It does not know what *finishing* means -
whether that is `^s` or `↵` or a button, whether an empty one may be submitted,
what escape costs, or whether escape should ask first - and a widget that
answered any of those would be answering them for every program that embeds it.
So the only keys it claims are the ones that edit text, everything else comes
straight back, and the host decides what to make of it.

That is also the answer to a host with keys of its own it wants working inside a
composer - dropping a template in, cycling a target, whatever it is. There is no
callback table to register with, because there is nothing to register with it.
"""
const ACTIONS = (:ok, :unhandled)

"""
    TextArea

A small multi-line text area.

Enough to write a comment, a commit message or a review without leaving the
program - insert, backspace, the arrows, home and end, and the readline keys
people's fingers already know - and no more. `⌥e` hands the buffer to `\$EDITOR`
for everything past that, which is where undo, search and your own keymap
already live and are not worth reimplementing here; that is the key the Julia
REPL binds to the same move. `^o` does it too, because a terminal that treats
Option as a compose key sends no Meta at all and would leave the editor
unreachable.

    ta = TextArea("Comment", "on src/parse.jl:42")
    write(stdout, frame_bytes(render(ta, 80, 24)))
    if handle!(ta, key) === :unhandled      # not an edit, so it is yours
        key == 19 && post(submission(ta))   # ...and this is what `^s` means
    end

Fields worth setting after construction: `status` is a line the footer shows
instead of the key hints - a host's answer to what just happened, cleared by the
next keystroke - and `hint` is those key hints, which a host has to add its own
keys to, since the widget does not know what they are. `focused` is whether it
has the terminal's cursor or a block where the cursor would be; see the
constructor.
"""
mutable struct TextArea
    title::String
    note::Row
    buf::TextBuffer
    top::Int                 # first display row shown
    status::String
    hint::String
    maxwidth::Int            # the widest the box is drawn, however wide the screen
    focused::Bool            # does it have the keyboard? see `render`
end

"""
    TEXTAREA_HINT

The key hints under a text area: the keys it actually owns, and no others.

How to finish and how to give up are not here because they are not the widget's
- a host that has bound them has to say so, which is what `hint` is for.
"""
const TEXTAREA_HINT = "⌥e/^o \$EDITOR · ^w word · ^a/^e line · ^y yank"

"""
    TextArea(title, note = ""; initial = "", hint = TEXTAREA_HINT, maxwidth = 100,
             focused = true)

A composer titled `title`, with `note` - what it is about, a line or several:
a string, or a vector of rows, see [`notetext`](@ref) - drawn quietly under the
title.

  * `initial`  what is already written - a draft being resumed, a template -
               with the cursor at the end of it
  * `hint`     the key hints under the box; a host that binds keys of its own
               over the widget's says so here
  * `maxwidth` the widest the box is drawn, however wide the screen. Wider than
               [`DIALOG_WIDTH`](@ref), because this is somewhere to write a
               paragraph rather than a question to answer
  * `focused`  whether it has the keyboard, and so the terminal's cursor -
               see [`caret`](@ref). `false` while a host has the keys somewhere
               else on the same screen: the widget then draws a block in
               reverse video where its cursor is, which says where typing will
               go when the keys come back without saying that they are here

How the terminal is handed back while `\$EDITOR` runs is not the widget's: it is
given with the key, to [`handle!`](@ref).
"""
TextArea(title, note = ""; initial::AbstractString = "",
         hint::AbstractString = TEXTAREA_HINT, maxwidth::Int = 100,
         focused::Bool = true) =
    TextArea(String(title), notetext(note), TextBuffer(initial), 1, "", String(hint),
             maxwidth, focused)

text(v::TextArea) = text(v.buf)

"""
    paste!(v::TextArea, s) -> TextArea

A paste, as the text it is - see [`paste!(::TextBuffer, ::AbstractString)`](@ref)."""
paste!(v::TextArea, s::AbstractString) = (paste!(v.buf, s); v)

"""
    submission(widget) -> String

The text with the whitespace round it taken off - what a host takes when it
decides the widget is finished.

A convenience and not a rule: somebody who has finished typing has almost always
left a newline behind them, and every consumer of [`text`](@ref) would otherwise
have to know that. `text` is still there for a host that wants the buffer as it
stands.
"""
submission(v) = String(strip(text(v)))

"""
    isblank(widget) -> Bool

Is there anything in here worth not throwing away? For a `TextArea` or a
`LineInput`, and the `TextBuffer` under either.

What a host asks when escape arrives, and before it submits. Words that were
typed and are nowhere else are the one thing in a program worth a confirmation,
and an empty buffer is not one of them - a question about it would put a dialog
in front of every composer opened by mistake. Whether an empty one may be
submitted at all is the same question from the other side, and the same answer:
the host's.
"""
isblank(v::TextArea) = isblank(v.buf)

# --- drawing ----------------------------------------------------------------

render(v::TextArea, w::Int, h::Int) = first(framed(v, w, h))
caret(v::TextArea, w::Int, h::Int) = last(framed(v, w, h))

function framed(v::TextArea, w::Int, h::Int)
    b = dialogbox(w; width = v.maxwidth)
    bh = max(3, h - 8)                 # rows of text inside the box
    rows, crow, ccol = bufferrows(v.buf, b.iw)
    _, v.top, _ = listwindow(length(rows), crow, v.top, bh)

    out = Row[b.head(v.title)]
    for l in rowwraplines(v.note, b.iw)
        push!(out, b.row(l, b.chrome.quiet))
    end
    push!(out, b.row(""))
    k = 0
    for i in v.top:(v.top + bh - 1)
        line = i <= length(rows) ? row(rows[i]) : row("")
        # The terminal's cursor where the keys are, and a block where they are
        # not. A host that draws this beside something else - a composer next
        # to the diff it is about - has one cursor to give, and gives it to the
        # side with the keys; the block on the other is where typing goes when
        # they come back. `focused` defaults to true, so a widget that is the
        # only thing on screen never has to say so.
        if i == crow
            k = length(out) + 1
            v.focused || (line = drawcursor(line, ccol))
        end
        push!(out, b.row(line))
    end
    push!(out, b.foot())
    push!(out, b.hint(isempty(v.status) ? v.hint : v.status))
    (centred(out, w, h), v.focused && k > 0 ? centredat(out, k, ccol, b, w, h) : nothing)
end

"""Put a block on display column `ccol` of `line`, in reverse video.

A cursor *drawn* rather than placed: the mark for a cursor that does not have
the keys, since a terminal has one cursor and it goes where they are - see
[`caret`](@ref). A block cannot blink and ignores the shape the user chose for
theirs, which is right for a place typing is not going.

`ccol` is a **display** column, because that is what a wrapped row can offer:
the row was cut at a width, so where the cursor sits in it is a width too. The
walk below is what keeps the three counts apart - a byte index into a line with
an accent in it throws, and a character index into one with a CJK character in
it draws the block a column to the left of where the terminal will put it.
"""
function drawcursor(line::AbstractString, ccol::Int)
    x = row(line)
    str = x.string
    acc, i = 0, firstindex(str)
    while i <= lastindex(str) && acc + textwidth(str[i]) <= ccol - 1
        acc += textwidth(str[i])
        i = nextind(str, i)
    end
    pre = slice(x, 1, i - 1)
    # A blank under the block, so a cursor past the end of the line is still
    # somewhere: reverse video over nothing paints nothing at all.
    i > lastindex(str) && return rowcat(pre, faced(" ", CURSOR))
    j = nextind(str, i)
    rowcat(pre, faced(slice(x, i, j - 1), CURSOR), slice(x, j, ncodeunits(str)))
end

"""The block a cursor without the keys is drawn as: reverse video, whatever a
host's theme says - see [`CHROME`](@ref)."""
const CURSOR = Face(inverse = true)

"""
    field(line, col, w) -> (Row, Int)

A line in `w` columns with the cursor at character column `col`, scrolled
sideways so the cursor is on screen, and the display column in the row the
cursor is at. What a `LineInput` and a `Choice`'s query are drawn with, for a
host that draws a field of its own - a search typed into a status line - and
wants it to behave the same: it puts the terminal's cursor at that column, as
[`caret`](@ref) says for a widget, or draws the block with [`drawfield`](@ref).

A `LineInput` and a `Choice`'s query are one row, and the box cuts a line
longer than that at its end - which is where the cursor is while typing. So a
cursor that would be cut takes the line with it: the front goes, a `…` says so,
and the cursor sits at the right. Nothing is kept between frames to do it: it
is a function of the line and the cursor, as the rest of a frame is.
"""
function field(line::AbstractString, col::Int, w::Int)
    s = shown(line)
    cs = collect(s)
    k = clamp(col - 1, 0, length(cs))             # characters before the cursor
    cw = k < length(cs) ? textwidth(cs[k + 1]) : 1
    width(r) = sum(textwidth, r; init = 0)
    fits = width(cs) + (k == length(cs) ? 1 : 0) <= w
    # The box cuts a long line to `w - 1` columns and a `…`, so the cursor has
    # to end before the last column to survive it.
    if !fits && w >= 3 && width(@view cs[1:k]) + cw > w - 1
        i = k + 1
        while i > 1 && 1 + width(@view cs[(i - 1):k]) + cw <= w - 1
            i -= 1
        end
        return (row(string("…", String(cs[i:end]))), 2 + width(@view cs[i:k]))
    end
    (row(s), displaycolumn(s, col))
end

"""
    drawfield(line, col, w) -> Row

[`field`](@ref) with a block in reverse video where its cursor is: a field that
does not have the terminal's cursor, and still says where typing goes.
"""
drawfield(line::AbstractString, col::Int, w::Int) = drawcursor(field(line, col, w)...)

"""The display column the cursor is in, for a cursor counted in characters."""
displaycolumn(line::AbstractString, col::Int) =
    textwidth(String(first(line, max(0, col - 1)))) + 1

# --- keys -------------------------------------------------------------------

"""
    handle!(v::TextArea, k; suspend = f -> f()) -> Symbol

Hand one key code to the text area. See [`ACTIONS`](@ref) for what comes back.

`suspend` is how the terminal is handed back while `\$EDITOR` runs: a
one-argument function that runs its argument and returns what it returns - see
[`suspend`](@ref). The default hands nothing over, which is right when there is
nothing to hand over and wrong in a raw-mode TUI, so a host with a terminal
passes one. An argument rather than a field, because it is a function: stored,
it is a field of no particular type and a dynamic call, which `--trim` cannot
compile; passed, the call is compiled for the function it is.

Every key it claims edits the text. `⌥e`/`^o` open `\$EDITOR`, `↵` splits the
line, and the rest is readline - the kills (`^k`, `^u`, `^w`, `⌥⌫`, `⌥d`) and
`^y` to put them back, `^t`, the motions (`^b`/`^f`/`^p`/`^n`, `^a`/`^e`, the
arrows, home and end) and `^d`. Anything else printable is inserted as the bytes
it arrived as, and anything else at all comes back as `:unhandled` - escape and
`^s` included, since finishing is not a text box's to define. The README has the
whole readline table, including what is deliberately not here.
"""
# `where F`: a function only passed on, never called here, is otherwise not
# specialised on, and the call it is passed to is dynamic after all.
function handle!(v::TextArea, k::Int; suspend::F = f -> f()) where {F}
    k = unshift(k)
    v.status = ""
    b = v.buf
    if k in (K_EDIT, C_O)                           # hand it to $EDITOR
        (txt, note) = compose_external(suspend, text(b))
        settext!(b, txt)
        v.status = note
    elseif k in (13, 10)
        newline!(b)
    elseif k in (127, 8)
        backspace!(b)
    elseif k in (K_DEL, C_D)
        deletechar!(b)
    elseif k == C_K
        killline!(b)
    elseif k == C_U
        killtostart!(b)
    elseif k in (C_W, K_WORD_BACK)
        deleteword!(b; alnum = k == K_WORD_BACK)
    elseif k == K_WORD_KILL
        killwordforward!(b)
    elseif k == C_Y
        yank!(b)
    elseif k == C_T
        transpose!(b)
    elseif k == K_WORD_LEFT
        move!(b, :wordleft)
    elseif k == K_WORD_RIGHT
        move!(b, :wordright)
    elseif k in (C_A, K_HOME)
        move!(b, :home)
    elseif k in (C_E, K_END)
        move!(b, :end)
    elseif k in (K_LEFT, C_B)
        move!(b, :left)
    elseif k in (K_RIGHT, C_F)
        move!(b, :right)
    elseif k in (K_UP, C_P)
        move!(b, :up)
    elseif k in (K_DOWN, C_N)
        move!(b, :down)
    elseif printable(k)
        insert!(b, keychar(k))
    else
        return :unhandled
    end
    :ok
end
