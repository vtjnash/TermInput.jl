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
back what is on now.

`displaysize(t)` and `write(t, x)` are the output's, `readevent(t)` and
`input_waiting(t)` the input's.

`HeldTerminal(in, out)` is one nothing has been done to: every mode off, so
`leave_terminal` and `suspend` on it write only the cursor. For a host that
wants somewhere to write before it has entered, or after it has left - and a
test that wants the sequences in an `IOBuffer` without entering at all.
"""
mutable struct HeldTerminal
    in::IO
    out::IO
    tty::Union{Nothing,REPL.Terminals.TTYTerminal}   # for raw mode; `nothing` when `in` is no tty
    altscreen::Bool
    title::Bool
    mouse::Bool
    paste::Bool
end
HeldTerminal(in::IO, out::IO) = HeldTerminal(in, out, nothing, false, false, false, false)

"""
    enter_terminal(in = stdin, out = stdout; altscreen = false, title = false,
                   mouse = false, paste = false) -> HeldTerminal

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
  * `paste`     [`bracketed_paste`](@ref), which makes a paste one `PasteEvent`
                rather than keys - a `q` in it is not quitting

Anything but a tty is taken as it is and nothing is asked of it, so an
`IOBuffer` at either end is a terminal a test can read the sequences out of.
"""
function enter_terminal(in::IO = stdin, out::IO = stdout; altscreen::Bool = false,
                        title::Bool = false, mouse::Bool = false, paste::Bool = false)
    tty = in isa Base.TTY ?
        REPL.Terminals.TTYTerminal(get(ENV, "TERM", "xterm"), in, out, stderr) : nothing
    t = HeldTerminal(in, out, tty, altscreen, title, mouse, paste)
    write(out, string(altscreen ? "\e[?1049h" : "", "\e[?25l", title ? "\e[22;2t" : ""))
    tty === nothing || REPL.Terminals.raw!(tty, true)
    write(out, string(mouse ? mouse_reporting(true) : "", paste ? bracketed_paste(true) : ""))
    t
end

"""
    leave_terminal(t::HeldTerminal)

Undo what [`enter_terminal`](@ref) did, in the reverse order: the mouse and
the paste brackets off, raw mode off, the cursor shown, the alternate screen
left and the title put back.

It never throws. The commonest way to get here is the terminal having gone
away - the window closed, the connection dropped - and then every write is to
a descriptor that is closed. An exception from the `finally` this is called in
would replace whatever brought the loop there with one about handing back a
terminal that no longer exists; so each half is tried, and one that fails
does not stop the other.
"""
function leave_terminal(t::HeldTerminal)
    try
        t.mouse && write(t.out, mouse_reporting(false))
    catch
    end
    try
        t.tty === nothing || REPL.Terminals.raw!(t.tty, false)
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
"""
function suspend(f, t::HeldTerminal)
    write(t.out, string(t.mouse ? mouse_reporting(false) : "",
                        t.paste ? bracketed_paste(false) : ""))
    t.tty === nothing || REPL.Terminals.raw!(t.tty, false)
    write(t.out, string("\e[?25h", t.altscreen ? "\e[?1049l" : ""))
    try
        f()
    finally
        write(t.out, string(t.altscreen ? "\e[?1049h" : "", "\e[?25l"))
        t.tty === nothing || REPL.Terminals.raw!(t.tty, true)
        write(t.out, string(t.mouse ? mouse_reporting(true) : "",
                            t.paste ? bracketed_paste(true) : ""))
    end
end

Base.displaysize(t::HeldTerminal) = displaysize(t.out)
Base.write(t::HeldTerminal, x) = write(t.out, x)
readevent(t::HeldTerminal) = readevent(t.in)
