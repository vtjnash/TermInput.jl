# A frame onto the terminal: how it is written, and when not to write one.
#
# `render` makes the rows; this is the bytes that put them on the screen. It
# knows nothing about what is in them - every rule here is about a terminal.

"""
    frame_bytes(rows, title = "", cursor = nothing; h = 0, top = 1, region = :reset,
                inline = nothing) -> Vector{UInt8}

One frame - `render`'s rows, top to bottom - as the bytes the terminal is sent,
in one write. `title` goes after the rows as it is (an `OSC 2` the host built,
or `""`), and `cursor`, a 1-based `(row, col)` in the frame, is where the
terminal's own cursor is put and shown; `nothing` leaves it hidden, for a frame
that draws its own. `h` is how many lines the frame owns, and rows the frame did
not bring, up to it, are cleared too; `0` is the frame's own.

Where it goes is one of three:

  * **The screen**, the default: rows written from line `top`, which is `1` for
    a full-screen frame, and the scroll region reset first.
  * **A strip of it**, with `region = :keep`: rows from line `top` and the
    scroll region left as the host set it - a status strip pinned under output
    that goes on scrolling above it. A line outside the region is one a delete
    or an insert does nothing on, so each row's line is erased (`\\e[2K`)
    rather than deleted and put back; see below for what that costs.
  * **Under the cursor**, with `inline = n`: no line numbers at all. The cursor
    goes up `n` lines and the frame is written from the start of that line, a
    newline between rows, so a frame taller than what is left of the screen
    scrolls it; and it is left under the frame, at the start of the line after
    it, with everything below that cleared. `n` is what the last frame left
    above the cursor's line: `0` for the first, its row count after one drawn
    with no `cursor`, and `cursor[1] - 1` after one that put it - the frame is
    a function of its arguments, so remembering which is the host's. A prompt
    asked in the middle of a program's output draws this way, and no rows at
    all is the last frame taken off. The scroll region is never touched,
    since resetting it moves the cursor.

A row is a [`Row`](@ref), written by StyledStrings in its faces - whatever the
stream, since what turns colour on is the faces a host put there, and a row
with none writes no escape at all - or a `String`, written as it is; see
[`writerow`](@ref) for a verbatim piece of one.

Three things about the write, none of them about what is in the frame:

  * **One write.** `print(a, b, c)` on a `TTY` is a write per argument, and
    between any two the terminal may draw. A `TTY` is unbuffered, so the
    buffer is made here and handed over whole.
  * **The cursor is hidden before the first row and shown after the frame.**
    Shown at the end of one frame, it was still shown at the start of the
    next, and a terminal that drew between the first row and the caret's
    row showed it at the top left on the way.
  * **Synchronized output**, DEC private mode 2026, around the whole thing: a
    terminal that knows it (kitty, wezterm, foot, alacritty, iTerm2, Windows
    Terminal, tmux 3.4 and up in its panes) holds the frame until the closing
    sequence and draws it once, which is the end of a torn frame at any size;
    one that does not ignores an unknown mode, which is what the standard
    says to do. Nothing on this side can hold the terminal otherwise: a pty
    is four kilobytes on Linux, so a frame is several reads however it was
    written.

**On the screen, every row is its line deleted and written again**: `\\e[M` at
that row, which
takes the line out and pulls the ones below it up, and `\\e[L` there, which puts
a blank line back and pushes them down again, so the row is written on a blank
line and every other line is where it was. A hyperlink leaves a marker on the
line it was drawn on in xterm.js, which frees one only when its line is deleted
or trimmed, and the alternate screen trims nothing - so a row overwritten in
place, or erased, kept every link it ever held. Thirty links a frame was 30000
markers after a thousand frames, and leaving the alternate screen disposed of
them all in time quadratic in the count: 5 s then, 100 s after four thousand
(`@xterm/headless` 6.1 beta, 2026-09-28). VS Code runs that xterm in its pty
host, and a pty host that misses its heartbeat for 12 s is restarted with every
terminal in it - which was quitting a full-screen program over Remote-SSH. An
`id` on the link only bounds it by url and row, which a scrolled page outgrows;
a delete bounds it by what is on the screen. One row at a time, and never a
clear, which is a blank frame and a flicker on every key. A strip or an inline
frame erases instead, and is the host's to keep short of links: it is not the
alternate screen, whose lines are never trimmed, and a line it cannot know is
in the scroll region is one a delete would not touch.

**Not a scroll region of the one row.** A region is two lines at the least, by
DEC's definition of it, and tmux ignores one a line tall (3.5, 2026-09-30), so the
`\\e[M` under it deleted in the whole screen: each row pulled the rest up one,
the row after it was written over what had been two rows down, and a row that
did not cover its line - a verbatim piece stops at its last written cell -
showed the frame before at half height past its end. The
region is reset once, before the first row, since a delete or an insert does
nothing on a line outside it.

**Auto-wrap is off while the frame is written** (DECAWM, `\\e[?7l`), and on
again at its end, so a program run after it sees the terminal as it was. A
row wider than the screen - one a measure got wrong, or a pane's between a
resize and its program catching up - wraps onto the next line with it on, and
pushes the rest of the frame down a row; with it off the terminal writes the
extra over the last column and the frame stays where it is. With no wrap there
is no pending wrap either, the state writing the last column leaves the cursor
in and that terminals disagree about: xterm.js counts it past the last column,
Terminal.app keeps it *on* the last column, where an erase after a full row
took the right border off every row. Nothing is erased after a row regardless,
and each row starts by putting the cursor at its line.
"""
function frame_bytes(rows::AbstractVector{<:AbstractString}, title::AbstractString = "",
                     cur::Union{Nothing,Tuple{Int,Int}} = nothing; h::Int = 0,
                     top::Int = 1, region::Symbol = :reset,
                     inline::Union{Nothing,Int} = nothing)
    region in (:reset, :keep) ||
        throw(ArgumentError("region is :reset or :keep, not $(repr(region))"))
    io = IOBuffer()
    cio = IOContext(io, :color => true)
    print(io, "\e[?2026h\e[?25l\e[?7l")
    n = max(h, length(rows))
    if inline !== nothing
        inline > 0 && print(io, "\e[", inline, "A")
        print(io, "\r")
        for i in 1:n
            print(io, i == 1 ? "\e[2K" : "\r\n\e[2K")
            i <= length(rows) && writerow(cio, rows[i])
        end
        # Under the frame, and nothing of a taller one before it left there.
        n > 0 && print(io, "\r\n")
        print(io, "\e[J\e[?7h", title)
        if cur !== nothing
            up = n - cur[1] + (n > 0)
            up > 0 && print(io, "\e[", up, "A")
            print(io, "\e[", cur[2], "G\e[?25h")
        end
    else
        region === :reset && print(io, "\e[r")
        for i in 1:n
            print(io, "\e[", top + i - 1, region === :reset ? "H\e[M\e[L" : "H\e[2K")
            i <= length(rows) && writerow(cio, rows[i])
        end
        print(io, "\e[?7h", title)
        cur === nothing || print(io, "\e[", top + cur[1] - 1, ";", cur[2], "H\e[?25h")
    end
    print(io, "\e[?2026l")
    take!(io)
end

"""
    writerow(io, row)

One row onto `io` where the cursor is, as [`frame_bytes`](@ref) writes each of
its rows: its faces by StyledStrings, and each `:verbatim` piece
([`verbatim`](@ref)) as it is, with a reset after it, since what it opened is
its own and the row goes on; then the cursor is moved to the column after its
width, and the rest of the row is written from there. For a host that places
its rows itself. `io` decides colour as anywhere else - an `IOContext` with
`:color => true` for the faces to be written.

Nothing measures what a verbatim piece drew: a program's row as its multiplexer
gave it keeps its trailing spaces only up to the last cell written, and is
narrower than its pane - which a line erased or deleted first is already blank
under.
"""
writerow(io::IO, s::AbstractString) = (print(io, s); nothing)
writerow(io::IO, s::SubString{<:AnnotatedString}) = writerow(io, row(s))
function writerow(io::IO, s::AnnotatedString)
    x = row(s)
    vs = verbatims(x)
    isempty(vs) && (print(io, x); return nothing)
    str = x.string
    col, i = 1, 1
    for (r, vw) in vs
        if first(r) > i
            piece = slice(x, i, first(r) - 1)
            print(io, piece); col += rowwidth(piece)
        end
        print(io, SubString(str, first(r), thisind(str, last(r))), "\e[0m")
        col += vw
        print(io, "\e[", col, "G")
        i = last(r) + 1
    end
    i <= ncodeunits(str) && print(io, slice(x, i, ncodeunits(str)))
    nothing
end

"""
    input_waiting(io) -> Bool
    input_waiting(t::HeldTerminal) -> Bool

Has the terminal sent input that no event has been read from yet? The test for
not drawing a frame: while it is true, another event is already here, and a
frame drawn now would be drawn over at once.

What it matters for is a burst - a paste into a terminal without bracketed
paste, or one into a program that takes it a key at a time, or a key held
down. Drawn after every key, 2700 characters of paste took 5.6 s under tmux;
drawn once they had run out, 0.02 s.

What has already arrived and is in the stream's buffer, never a wait for more:
Julia stops reading a stream nobody is waiting on, so this is the rest of the
last read, up to what the pty delivered at once, and false between keys typed
by hand - each of which still draws its frame.
"""
input_waiting(io::IO) = (bytesavailable(io)::Int) > 0   # `io` is any `IO`
input_waiting(t::HeldTerminal) = input_waiting(t.in)
