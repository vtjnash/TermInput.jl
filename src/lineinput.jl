# One line of text, asked for in a box.
#
# The same editing model as the text area with the line-splitting keys left out,
# which is what makes the two agree about `^w` and alt-backspace without anybody
# having to keep two tables in step.
#
# A widget and not a `readline`, because a TUI holds the terminal in raw mode
# for the whole of its run: anything that wants a line of input has to go
# through the host's own event stream rather than reaching for stdin, and a
# program that reached for stdin here would race its own reader task for the
# keystrokes.

"""Ask for one line of text.

    li = LineInput("Snooze until", "a date, or a number of days")
    print(render(li, 80, 24))
    if handle!(li, key) === :unhandled     # not an edit, so it is yours
        key in (13, 10) && accept(submission(li))
    end

`↵` is not bound, which is the one place this differs from [`TextArea`](@ref)
for a reason other than the second line: there it splits the line, and here
there is no line to split, so it comes back like every other key the widget has
no edit for. What it *means* - accept, or accept-unless-empty, or nothing - is
the host's, the same as everywhere else.
"""
mutable struct LineInput
    title::String
    note::String
    buf::TextBuffer
    status::String
    hint::String
    maxwidth::Int
end

"""The key hints under a line input: the keys it actually owns, and no others.

How to accept and how to give up are not here because they are not the widget's
- a host that has bound them has to say so, which is what `hint` is for.
"""
const LINEINPUT_HINT = "^w word · ^a/^e line · ^y yank"

"""
    LineInput(title, note = ""; initial, hint, maxwidth)
"""
LineInput(title, note = ""; initial::AbstractString = "",
          hint::AbstractString = LINEINPUT_HINT, maxwidth::Int = 100) =
    LineInput(String(title), String(note), TextBuffer(oneline(initial)), "",
              String(hint), maxwidth)

"""Whatever arrived, as one line. A newline in a one-row field is not a
character to draw: the frame is clamped by *element*, so one element holding a
newline prints as two rows, the screen scrolls, and every mouse report after it
names a row that has moved."""
oneline(s::AbstractString) = replace(replace(String(s), "\r\n" => " "), '\n' => ' ', '\r' => ' ')

text(v::LineInput) = text(v.buf)
isblank(v::LineInput) = isblank(v.buf)

"Where the cursor is, as a column in the line. 1 is before the first character."
column(v::LineInput) = v.buf.col

function render(v::LineInput, w::Int, h::Int)
    b = dialogbox(w; width = v.maxwidth)
    line = curline(v.buf)
    out = [b.top(), b.row(v.title, CHROME[].strong), b.row("")]
    for l in awrap(v.note, b.iw)
        push!(out, b.row(l, CHROME[].quiet))
    end
    push!(out, b.row(string("> ", drawcursor(line, displaycolumn(line, v.buf.col)))))
    push!(out, b.foot())
    push!(out, b.hint(isempty(v.status) ? v.hint : v.status))
    centred(out, w, h)
end

"""
    handle!(v::LineInput, k) -> Symbol

Hand one key code to the line input. See [`ACTIONS`](@ref) for what comes back.

The same keys as [`TextArea`](@ref) less the ones that need a second line: `↵`
has no line to split, and `^p`/`^n` have no line to move to. There is no history
here for them to walk either, which is what readline gives them, so all of them
are handed back for a host that has somewhere to go.
"""
function handle!(v::LineInput, k::Int)
    k = unshift(k)
    v.status = ""
    b = v.buf
    if k in (127, 8)
        backspace!(b)
    elseif k in (K_DEL, C_D)
        deletechar!(b)
    elseif k == C_U
        killtostart!(b)
    elseif k in (C_W, K_WORD_BACK)
        deleteword!(b; alnum = k == K_WORD_BACK)
    elseif k == K_WORD_KILL
        killwordforward!(b)
    elseif k == C_K
        killline!(b)
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
    elseif printable(k)
        insert!(b, keychar(k))
    else
        return :unhandled
    end
    :ok
end
