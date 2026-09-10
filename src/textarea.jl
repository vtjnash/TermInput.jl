# A small multi-line text area, and the contract a host drives it through.
#
# `render` is a pure function of the widget and a size, and `handle!` takes one
# key code and returns what happened. Neither reads stdin, owns a terminal or
# knows what a view stack is, because a host has all three already - and a
# widget that insisted on its own would be a widget you cannot put in the
# program you are writing.

"""What a widget did with a key.

  * `:ok`         it used the key, and the frame should be drawn again
  * `:unhandled`  not a key this widget uses, so it is the host's

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

"""A small multi-line text area.

Enough to write a comment, a commit message or a review without leaving the
program - insert, backspace, the arrows, home and end, and the readline keys
people's fingers already know - and no more. `⌥e` hands the buffer to `\$EDITOR`
for everything past that, which is where undo, search and your own keymap
already live and are not worth reimplementing here; that is the key the Julia
REPL binds to the same move. `^o` does it too, because a terminal that treats
Option as a compose key sends no Meta at all and would leave the editor
unreachable.

    ta = TextArea("Comment", "on managers.jl:544")
    print(render(ta, 80, 24))
    if handle!(ta, key) === :unhandled      # not an edit, so it is yours
        key == 19 && post(submission(ta))   # ...and this is what `^s` means
    end

Fields worth setting after construction: `status` is a line the footer shows
instead of the key hints - a host's answer to what just happened, cleared by the
next keystroke - and `hint` is those key hints, which a host has to add its own
keys to, since the widget does not know what they are.
"""
mutable struct TextArea
    title::String
    note::String
    buf::TextBuffer
    top::Int                 # first display row shown
    status::String
    hint::String
    maxwidth::Int            # the widest the box is drawn, however wide the screen
    suspend::Any             # runs a closure with the terminal handed back
    focused::Bool            # does it have the keyboard? see `render`
end

"""The key hints under a text area: the keys it actually owns, and no others.

How to finish and how to give up are not here because they are not the widget's
- a host that has bound them has to say so, which is what `hint` is for.
"""
const TEXTAREA_HINT = "⌥e/^o \$EDITOR · ^w word · ^a/^e line · ^y yank"

"""
    TextArea(title, note = ""; initial, hint, maxwidth, suspend)

`initial` is what is already written - a draft being resumed, a template - and
the cursor starts at the end of it.

`suspend` is how the terminal is handed back while `\$EDITOR` runs; see
[`suspend`](@ref). The default runs the editor without handing anything over,
which is right when there is nothing to hand over and wrong in a raw-mode TUI -
so a host with a terminal should pass one.
"""
TextArea(title, note = ""; initial::AbstractString = "",
         hint::AbstractString = TEXTAREA_HINT, maxwidth::Int = 100,
         suspend = f -> f(), focused::Bool = true) =
    TextArea(String(title), String(note), TextBuffer(initial), 1, "", String(hint),
             maxwidth, suspend, focused)

text(v::TextArea) = text(v.buf)

"""The text with the whitespace round it taken off - what a host takes when it
decides the widget is finished.

A convenience and not a rule: somebody who has finished typing has almost always
left a newline behind them, and every consumer of [`text`](@ref) would otherwise
have to know that. `text` is still there for a host that wants the buffer as it
stands.
"""
submission(v) = String(strip(text(v)))

"""Is there anything in here worth not throwing away?

What a host asks when escape arrives, and before it submits. Words that were
typed and are nowhere else are the one thing in a program worth a confirmation,
and an empty buffer is not one of them - a question about it would put a dialog
in front of every composer opened by mistake. Whether an empty one may be
submitted at all is the same question from the other side, and the same answer:
the host's.
"""
isblank(v::TextArea) = isblank(v.buf)

# --- drawing ----------------------------------------------------------------

function render(v::TextArea, w::Int, h::Int)
    b = dialogbox(w; width = v.maxwidth)
    bh = max(3, h - 8)                 # rows of text inside the box
    rows, crow, ccol = bufferrows(v.buf, b.iw)
    v.top = clamp(v.top, 1, max(1, length(rows)))
    crow < v.top && (v.top = crow)
    crow > v.top + bh - 1 && (v.top = crow - bh + 1)
    v.top = clamp(v.top, 1, max(1, length(rows) - bh + 1))

    out = [b.head(v.title)]
    for l in awrap(v.note, b.iw)
        push!(out, b.row(l, "\e[2m"))
    end
    push!(out, b.row(""))
    for i in v.top:(v.top + bh - 1)
        line = i <= length(rows) ? rows[i] : ""
        # No cursor while the keyboard is somewhere else. A host that draws this
        # beside something else - the browser this was split out of draws a
        # composer next to the diff it is about - has two things on screen and
        # one of them has the keys; two cursors would say neither does. `focused`
        # defaults to true, so a widget that is the only thing on screen, which
        # is every other use of this, never has to say so.
        i == crow && v.focused && (line = drawcursor(line, ccol))
        push!(out, b.row(line))
    end
    push!(out, b.foot())
    push!(out, b.hint(isempty(v.status) ? v.hint : v.status))
    centred(out, w, h)
end

"""Put a block on display column `ccol` of `line`, in reverse video.

The cursor is *drawn* rather than placed. A TUI hides the terminal's own cursor
for the whole run - most of what it draws owes nothing to where the terminal
thinks it is - and turning it back on here would leave it to be put back by
every path out of this widget, including the ones that throw.

`ccol` is a **display** column, because that is what a wrapped row can offer:
the row was cut at a width, so where the cursor sits in it is a width too. The
walk below is what keeps the three counts apart - a byte index into a line with
an accent in it throws, and a character index into one with a CJK character in
it draws the block a column to the left of where the terminal will put it.
"""
function drawcursor(line::AbstractString, ccol::Int)
    io, acc, i = IOBuffer(), 0, firstindex(line)
    while i <= lastindex(line) && acc + textwidth(line[i]) <= ccol - 1
        acc += textwidth(line[i])
        write(io, line[i])
        i = nextind(line, i)
    end
    pre = String(take!(io))
    at, post = if i <= lastindex(line)
        # A blank under the block, so a cursor past the end of the line is
        # still somewhere: `\e[7m\e[0m` paints nothing at all.
        (string(line[i]), String(SubString(line, nextind(line, i))))
    else
        (" ", "")
    end
    string(pre, "\e[7m", at, "\e[0m", post)
end

"""The display column the cursor is in, for a cursor counted in characters."""
displaycolumn(line::AbstractString, col::Int) =
    textwidth(String(first(line, max(0, col - 1)))) + 1

# --- keys -------------------------------------------------------------------

"""
    handle!(v::TextArea, k) -> Symbol

Hand one key code to the text area. See [`ACTIONS`](@ref) for what comes back.

Every key it claims edits the text. `⌥e`/`^o` open `\$EDITOR`, `↵` splits the
line, and the rest is readline - the kills (`^k`, `^u`, `^w`, `⌥⌫`, `⌥d`) and
`^y` to put them back, `^t`, the motions (`^b`/`^f`/`^p`/`^n`, `^a`/`^e`, the
arrows, home and end) and `^d`. Anything else printable is inserted as the bytes
it arrived as, and anything else at all comes back as `:unhandled` - escape and
`^s` included, since finishing is not a text box's to define. The README has the
whole readline table, including what is deliberately not here.
"""
function handle!(v::TextArea, k::Int)
    k = unshift(k)
    v.status = ""
    b = v.buf
    if k in (K_EDIT, C_O)                           # hand it to $EDITOR
        (txt, note) = compose_external(v.suspend, text(b))
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
