# A frame onto the terminal: how it is written, and when not to write one.
#
# `render` makes the rows; this is the bytes that put them on the screen. It
# knows nothing about what is in them - every rule here is about a terminal.

"""
    frame_bytes(rows, title = "", cursor = nothing; h = 0) -> Vector{UInt8}

One full-screen frame - `render`'s rows, top to bottom - as the bytes the
terminal is sent, in one write. `title` goes after the rows as it is (an
`OSC 2` the host built, or `""`), and `cursor`, a 1-based `(row, col)`, is
where the terminal's own cursor is put and shown; `nothing` leaves it hidden,
for a frame that draws its own. `h` is the screen's height, and rows the frame
did not bring, up to it, are cleared too; `0` is the frame's own.

A row is a [`Row`](@ref), written by StyledStrings in its faces - whatever the
stream, since what turns colour on is the faces a host put there, and a row
with none writes no escape at all - or a `String`, written as it is.

A `:verbatim` piece of a row ([`verbatim`](@ref)) is written as it is, with a
reset after it, since what it opened is its own and the row goes on; then the
cursor is moved to the column after its width, and the rest of the row is
written from there. Nothing measures what the piece drew: a program's row as
its multiplexer gave it keeps its trailing spaces only up to the last cell
written, and is narrower than its pane - which the row just deleted is already
blank under.

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

**Every row is its line deleted and written again**: the scroll region set to
that row alone, `\\e[M` there, and the row. A hyperlink leaves a marker on the
line it was drawn on in xterm.js, which frees one only when its line is deleted
or trimmed, and the alternate screen trims nothing - so a row overwritten in
place, or erased, kept every link it ever held. Thirty links a frame was 30000
markers after a thousand frames, and leaving the alternate screen disposed of
them all in time quadratic in the count: 5 s then, 100 s after four thousand
(`@xterm/headless` 6.1 beta, 2026-09-28). VS Code runs that xterm in its pty
host, and a pty host that misses its heartbeat for 12 s is restarted with every
terminal in it - which was quitting a full-screen program over Remote-SSH. An
`id` on the link only bounds it by url and row, which a scrolled page outgrows;
a delete bounds it by what is on the screen. One row at a time, so a terminal
that draws mid-frame shows that row blank and nothing else moved, which is all
an erase ever showed; never a clear, which is a blank frame and a flicker on
every key.

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
and each row starts by setting the scroll region, which homes the cursor.
"""
function frame_bytes(rows::AbstractVector{<:AbstractString}, title::AbstractString = "",
                     cur::Union{Nothing,Tuple{Int,Int}} = nothing; h::Int = 0)
    io = IOBuffer()
    cio = IOContext(io, :color => true)
    print(io, "\e[?2026h\e[?25l\e[?7l")
    for i in 1:max(h, length(rows))
        print(io, "\e[", i, ";", i, "r\e[", i, "H\e[M")
        i <= length(rows) && writerow(cio, rows[i])
    end
    print(io, "\e[r\e[?7h", title)
    cur === nothing || print(io, "\e[", cur[1], ";", cur[2], "H\e[?25h")
    print(io, "\e[?2026l")
    take!(io)
end

"""One row onto a frame: its faces by StyledStrings, and each verbatim piece
as it is, closed, with the cursor moved past its width."""
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
input_waiting(io::IO) = bytesavailable(io) > 0
input_waiting(t::HeldTerminal) = input_waiting(t.in)
