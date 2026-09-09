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
    handle!(li, key)          # :ok | :submit | :cancel | :unhandled

`↵` on an empty line is `:cancel` rather than a submission of nothing: a prompt
answered with nothing is a prompt somebody changed their mind in front of.
"""
mutable struct LineInput
    title::String
    note::String
    buf::TextBuffer
    status::String
    hint::String
    maxwidth::Int
end

"""The key hints under a line input."""
const LINEINPUT_HINT = "enter accept · ^w word · ^a/^e line · esc cancel"

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
    out = [b.top(), b.row(v.title, "\e[1m"), b.row("")]
    for l in awrap(v.note, b.iw)
        push!(out, b.row(l, "\e[2m"))
    end
    push!(out, b.row(string("> ", drawcursor(line, displaycolumn(line, v.buf.col)))))
    push!(out, b.foot())
    push!(out, b.hint(isempty(v.status) ? v.hint : v.status))
    centred(out, w, h)
end

"""
    handle!(v::LineInput, k) -> Symbol

Hand one key code to the line input. See [`ACTIONS`](@ref) for what comes back.
"""
function handle!(v::LineInput, k::Int)
    k = unshift(k)
    v.status = ""
    b = v.buf
    if k in (13, 10)
        return isblank(b) ? :cancel : :submit
    elseif k == 27
        return :cancel
    elseif k in (127, 8)
        backspace!(b)
    elseif k in (K_DEL, C_D)
        deletechar!(b)
    elseif k == C_U
        killtostart!(b)
    elseif k in (C_W, K_WORD_BACK)
        deleteword!(b; alnum = k == K_WORD_BACK)
    elseif k == C_K
        killline!(b)
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
    elseif printable(k)
        insert!(b, keychar(k))
    else
        return :unhandled
    end
    :ok
end
