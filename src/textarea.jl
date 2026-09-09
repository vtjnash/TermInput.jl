# A small multi-line text area, and the contract a host drives it through.
#
# `render` is a pure function of the widget and a size, and `handle!` takes one
# key code and returns what happened. Neither reads stdin, owns a terminal or
# knows what a view stack is, because a host has all three already - and a
# widget that insisted on its own would be a widget you cannot put in the
# program you are writing.

"""What a widget did with a key.

  * `:ok`         it handled it, and the frame should be drawn again
  * `:submit`     the text is finished - [`submission`](@ref) is what to take
  * `:cancel`     escape, or an empty line accepted; nothing was submitted
  * `:unhandled`  not a key this widget binds, so it is the host's

`:unhandled` is the one worth designing around. A composer sits inside somebody
else's program, and that program has keys of its own it wants to work here -
dropping a template in, cycling a target, whatever it is. Rather than a table of
callbacks, anything this does not claim is handed straight back.
"""
const ACTIONS = (:ok, :submit, :cancel, :unhandled)

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
    handle!(ta, key)          # :ok | :submit | :cancel | :unhandled

Fields worth setting after construction: `status` is a line the footer shows
instead of the key hints - a host's answer to what just happened, cleared by the
next keystroke - and `hint` is those key hints, which a host that has claimed
keys of its own should add to.
"""
mutable struct TextArea
    title::String
    note::String
    buf::TextBuffer
    top::Int                 # first display row shown
    status::String
    hint::String
    allow_empty::Bool        # an approval needs no words; a comment does
    maxwidth::Int            # the widest the box is drawn, however wide the screen
    suspend::Any             # runs a closure with the terminal handed back
end

"""The key hints under an empty-handed text area."""
const TEXTAREA_HINT =
    "^s submit · ⌥e/^o \$EDITOR · ^w word · ^a/^e line · esc cancel"

"""
    TextArea(title, note = ""; initial, allow_empty, hint, maxwidth, suspend)

`initial` is what is already written - a draft being resumed, a template - and
the cursor starts at the end of it. `allow_empty` says whether `^s` on an empty
buffer submits or refuses: an approval needs no words, a comment does.

`suspend` is how the terminal is handed back while `\$EDITOR` runs; see
[`suspend`](@ref). The default runs the editor without handing anything over,
which is right when there is nothing to hand over and wrong in a raw-mode TUI -
so a host with a terminal should pass one.
"""
TextArea(title, note = ""; initial::AbstractString = "", allow_empty::Bool = false,
         hint::AbstractString = TEXTAREA_HINT, maxwidth::Int = 100,
         suspend = f -> f()) =
    TextArea(String(title), String(note), TextBuffer(initial), 1, "", String(hint),
             allow_empty, maxwidth, suspend)

text(v::TextArea) = text(v.buf)

"""What a `:submit` submitted: the text with the whitespace round it taken off.

Never the raw buffer. Somebody who has finished typing has almost always left a
newline behind them, and every consumer of this would otherwise have to know
that.
"""
submission(v) = String(strip(text(v)))

"""Is there anything in here worth not throwing away?

What a host asks when escape arrives: words that were typed and are nowhere else
are the one thing in a program worth a confirmation, and an empty buffer is not
one of them - a question about it would put a dialog in front of every composer
opened by mistake.
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
        i == crow && (line = drawcursor(line, ccol))
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

The keys, in the order they are tried: escape cancels, `^s` submits, `⌥e`/`^o`
open `\$EDITOR`, `↵` splits the line, and the rest is readline - `^w` and
alt-backspace by the two word rules, `^k`, `^u`, `^a`/`^e`, `^d`, the arrows,
home and end. Anything else printable is inserted as the bytes it arrived as.
"""
function handle!(v::TextArea, k::Int)
    k = unshift(k)
    v.status = ""
    b = v.buf
    if k == 27
        return :cancel
    elseif k == C_S
        if isblank(b) && !v.allow_empty
            v.status = "nothing to send — esc cancels"
            return :ok
        end
        return :submit
    elseif k in (K_EDIT, C_O)                       # hand it to $EDITOR
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
    elseif k == K_WORD_LEFT
        move!(b, :wordleft)
    elseif k == K_WORD_RIGHT
        move!(b, :wordright)
    elseif k in (C_A, K_HOME)
        move!(b, :home)
    elseif k in (C_E, K_END)
        move!(b, :end)
    elseif k == K_LEFT
        move!(b, :left)
    elseif k == K_RIGHT
        move!(b, :right)
    elseif k == K_UP
        move!(b, :up)
    elseif k == K_DOWN
        move!(b, :down)
    elseif printable(k)
        insert!(b, keychar(k))
    else
        return :unhandled
    end
    :ok
end
