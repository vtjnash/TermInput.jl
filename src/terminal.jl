# The terminal a loop draws on: put into the modes a widget needs, and put back.
#
# A loop that drives a widget has to set half a dozen modes on the way in and
# undo every one of them on the way out, however the way out happens - and the
# commonest way is a terminal that has already gone away, where every write to
# it throws. Getting that wrong leaves a shell in raw mode with the mouse on,
# which is a terminal somebody has to `reset`. So the pair is here, and returns
# a value that says what was done, which is what `suspend` then undoes and
# redoes. The loop itself stays the host's.

"""
    HeldTerminal

A terminal [`enter_terminal`](@ref) has put into the modes a loop needs: what
it reads from, what it writes to, and which modes it set, so that
[`leave_terminal`](@ref) and [`suspend`](@ref) undo exactly those.

`t.mouse` is whether mouse reporting is on. It is the one mode a host may turn
on and off during a run - owning the mouse costs the terminal's own selection,
so it is worth a key - and a host that does writes [`mouse_reporting`](@ref)
itself and sets `t.mouse` to match, so that `suspend` and `leave_terminal` put
back what is on now. `t.motion` is whether that reporting includes the
pointer's moves with no button held, and a host that turns the mouse back on
asks for the same: `mouse_reporting(true; t.motion)`.

`displaysize(t)` and `write(t, x)` are the output's, `readevent(t)` and
`input_waiting(t)` the input's.

`HeldTerminal(in, out)` is one nothing has been done to: every mode off, so
`leave_terminal` and `suspend` on it write only the cursor. For a host that
wants somewhere to write before it has entered, or after it has left - and a
test that wants the sequences in an `IOBuffer` without entering at all.

`t.fence` is whether the terminal is asked for a cut in its input - see
`enter_terminal`'s `fence` - and the three after it are the asking's:
`t.fences` the questions out whose answers have not been read, `t.answered`
whether any ever has been, and `t.asked` when the first went out.
"""
mutable struct HeldTerminal
    in::IO
    out::IO
    tty::Union{Nothing,REPL.Terminals.TTYTerminal}   # for raw mode; `nothing` when `in` is no tty
    altscreen::Bool
    title::Bool
    mouse::Bool
    paste::Bool
    focus::Bool
    motion::Bool
    fence::Bool
    fences::Int
    answered::Bool
    asked::Float64
end
HeldTerminal(in::IO, out::IO) =
    HeldTerminal(in, out, nothing, false, false, false, false, false, false, false, 0, false, 0.0)

"""
    enter_terminal(in = stdin, out = stdout; altscreen = false, title = false,
                   mouse = false, motion = false, paste = false, focus = false,
                   fence = false) -> HeldTerminal

Put the terminal into the modes a loop driving a widget needs, in one write,
and say what was done. Leave with [`leave_terminal`](@ref), in a `finally`.

Always: raw mode, where `in` is a tty, so that a key arrives when it is
pressed and as the bytes it is; and the cursor hidden, since a widget draws
its own and a frame shows the terminal's where it is wanted.

  * `altscreen` the alternate screen, so the host has the whole of it and the
                shell's scrollback is as it was when it leaves. Off for a host
                drawing inline, under a prompt
  * `title`     the terminal's title saved on its title stack, for a host that
                sets its own, so that the one it had comes back on the way out.
                A terminal without a stack keeps the last one set until its
                shell's prompt sets the next
  * `mouse`     [`mouse_reporting`](@ref), which reports presses, releases and
                drags as `MouseEvent`s
  * `motion`    with `mouse`, the pointer's moves with no button held as well,
                as `:move` events, for a host that shows what it rests on
  * `paste`     [`bracketed_paste`](@ref), which makes a paste one `PasteEvent`
                rather than keys - a `q` in it is not quitting
  * `focus`     [`focus_reporting`](@ref), which reports the focus gained and
                lost as `FocusEvent`s - and, from xterm.js, the focus as it is
                whenever a terminal puts its modes back, which is when the
                mouse needs asking for again
  * `fence`     a cut in the input before raw mode goes, so that what the
                terminal had already sent - a mouse report from before the
                mouse went off, the answer to a question - is read here and
                not by the prompt or the child the terminal goes to next. See
                below

Anything but a tty is taken as it is and nothing is asked of it, so an
`IOBuffer` at either end is a terminal a test can read the sequences out of.

## The fence

There is no asking the kernel what is still on its way: a report the terminal
sent before it saw the mouse go off is in flight, or in the tty's queue, and
leaving raw mode then hands it to whoever reads next as typing - `^[[<35;40;12M`
at the prompt, or keys to `\$EDITOR`. What can be asked is the terminal: it
answers [`FENCE_QUERY`](@ref) after everything it sent before, so once the
answer has been read nothing older is left. [`leave_terminal`](@ref) and
[`suspend`](@ref) ask, after the reports go off and before raw mode does, and
read up to the answer, dropping what came before it - which, a round trip
after a quitting key, is reports and answers and rarely anything typed.

Whether the terminal answers at all is found out once, here: the question is
asked on the way in, after raw mode, and not waited for. Its answer is read by
whatever reads next. Until it has come, leaving waits for it - for at most
`FENCE_PATIENCE` seconds from when it was asked, since a round trip over ssh is
anything from a millisecond to seconds and there is no measuring it - and a
terminal that has not answered by then is never asked again, and leaves as it
always has. One that has answered is asked again at each leaving, and waited
for up to `FENCE_PATIENCE` more, which only a link gone dead runs out.

Off by default, because the answer is an event - [`FenceEvent`](@ref) - and is
only taken out of the input by a reader that knows the terminal:
`readevent(t)` on the `HeldTerminal`, or an [`InputReader`](@ref) made from it.
A host that reads `in` directly sees it, and leaving waits out the patience for
an answer it read and did not note. Only where `in` and `out` are both ttys,
and the same one: a question written to a terminal whose answers go to
somebody else's input is a keystroke typed into that.
"""
function enter_terminal(in::IO = stdin, out::IO = stdout; altscreen::Bool = false,
                        title::Bool = false, mouse::Bool = false, motion::Bool = false,
                        paste::Bool = false, focus::Bool = false, fence::Bool = false)
    tty = in isa Base.TTY ?
        REPL.Terminals.TTYTerminal(get(ENV, "TERM", "xterm"), in, out, stderr) : nothing
    fence = fence && tty !== nothing && sametty(in, out)
    t = HeldTerminal(in, out, tty, altscreen, title, mouse, paste, focus, motion,
                     fence, 0, false, 0.0)
    write(out, string(altscreen ? "\e[?1049h" : "", "\e[?25l", title ? "\e[22;2t" : ""))
    tty === nothing || REPL.Terminals.raw!(tty, true)
    # The question after raw mode, or its answer would be echoed and held for a
    # newline.
    write(out, string(mouse ? mouse_reporting(true; motion) : "", paste ? bracketed_paste(true) : "",
                      focus ? focus_reporting(true) : "", fence ? FENCE_QUERY : ""))
    fence && (t.fences = 1; t.asked = time())
    t
end

# Whether `out` writes to the terminal `in` reads: the same device, and not
# only two ttys.
function sametty(in::IO, out::IO)
    out isa Base.TTY || return false
    try
        stat(Base._fd(in)::RawFD).rdev == stat(Base._fd(out)::RawFD).rdev
    catch
        false
    end
end

# Raw mode on or off where `t` holds a tty. The field is copied first: a test of
# `t.tty` does not narrow the `t.tty` read after it.
function tty_raw!(t::HeldTerminal, on::Bool)
    tty = t.tty
    tty === nothing || REPL.Terminals.raw!(tty, on)
    nothing
end

"""
    leave_terminal(t::HeldTerminal)

Undo what [`enter_terminal`](@ref) did, in the reverse order: focus reports,
the mouse and the paste brackets off, the input read up to a fence where the
terminal was entered with one, raw mode off, the cursor shown, the alternate
screen left and the title put back.

Nothing may be reading `in` meanwhile: an [`InputReader`](@ref) is closed
first, and its `close` waits for it to be done.

It never throws. The commonest way to get here is the terminal having gone
away - the window closed, the connection dropped - and then every write is to
a descriptor that is closed. An exception from the `finally` this is called in
would replace whatever brought the loop there with one about handing back a
terminal that no longer exists; so each half is tried, and one that fails
does not stop the other.
"""
function leave_terminal(t::HeldTerminal)
    try
        write(t.out, string(t.focus ? focus_reporting(false) : "",
                            t.mouse ? mouse_reporting(false) : ""))
    catch
    end
    try
        settle!(t)
    catch
    end
    try
        tty_raw!(t, false)
    catch
    end
    try
        write(t.out, string(t.paste ? bracketed_paste(false) : "", "\e[?25h",
                            t.altscreen ? "\e[?1049l" : "", t.title ? "\e[23;2t" : ""))
    catch
    end
    nothing
end

"""
    suspend(f, t::HeldTerminal)

Give the terminal back for the duration of `f`, then take it again - undoing
and redoing exactly what [`enter_terminal`](@ref) did and what `t` says is on
now, the mouse included. The rest is [`suspend(f, term)`](@ref suspend), and so
is the rule about where it may be called from.

A terminal entered with `fence` is read up to one before it is handed over, as
on leaving, so the reports it sent before they went off are not keys to the
child.
"""
function suspend(f, t::HeldTerminal)
    write(t.out, string(t.focus ? focus_reporting(false) : "",
                        t.mouse ? mouse_reporting(false) : "",
                        t.paste ? bracketed_paste(false) : ""))
    settle!(t)
    tty_raw!(t, false)
    write(t.out, string("\e[?25h", t.altscreen ? "\e[?1049l" : ""))
    try
        f()
    finally
        write(t.out, string(t.altscreen ? "\e[?1049h" : "", "\e[?25l"))
        tty_raw!(t, true)
        write(t.out, string(t.mouse ? mouse_reporting(true; t.motion) : "",
                            t.paste ? bracketed_paste(true) : "",
                            t.focus ? focus_reporting(true) : ""))
    end
end

Base.displaysize(t::HeldTerminal) = displaysize(t.out)::Tuple{Int,Int}   # `out` is any `IO`
Base.write(t::HeldTerminal, x) = write(t.out, x)
# An answer to the fence is the terminal's business and not the host's: noted,
# and the next event read in its place.
function readevent(t::HeldTerminal)
    while true
        ev = readevent(t.in)
        ev isa FenceEvent || return ev
        answered!(t)
    end
end
