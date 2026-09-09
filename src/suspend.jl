# Handing the terminal to somebody else for a moment, and taking it back.
#
# A text area is enough to write a paragraph in and is not meant to be more
# than that: undo, search, syntax and your own keymap already exist in the
# editor you already use, and `⌥e` hands the buffer over to it - the same key
# the Julia REPL binds to the same move. What that needs is not an editor; it is
# a way to stop being the program that owns the terminal, which is a problem
# every TUI has and none of them has anywhere to put.

"""The escape sequences that turn mouse reporting on and off.

`1006` asks for SGR coordinates, without which columns past 223 are
unreportable; `1002` reports presses, releases and motion *while a button is
held*, which is exactly a drag and nothing more - `1003` would deliver a report
per cell of idle pointer movement.

Here because [`suspend`](@ref) has to put it back the way it found it, and a
host that owns the mouse should not have to keep a second copy of the two
strings in step with this one.
"""
mouse_reporting(on::Bool) = on ? "\e[?1006h\e[?1002h" : "\e[?1002l\e[?1006l"

"""
    suspend(f, term; mouse = false)

Give the terminal back for the duration of `f`, then take it again.

For handing stdin to a child process - `\$EDITOR`, mainly. Everything a TUI does
to the terminal is undone in order and redone after: mouse reporting off, raw
mode off, the cursor shown, the alternate screen released, so the child gets a
terminal that looks untouched and its own scrollback. `mouse` says whether the
host had mouse reporting on, since only it knows.

`term` is a `REPL.Terminals.TTYTerminal`, or `nothing` where there is no
terminal to hand over - a test, or a program whose output is a pipe. Everything
else still happens, which is what makes the escape sequences assertable without
a tty.

**Only safe to call from wherever input is read.** A reader task blocked in
`read(stdin)` will race the child for every keystroke the user types into it,
and the keystrokes it wins are gone. The rule for a host with a reader task is
that it must be parked between events rather than sitting in `read`, and that
this runs while it is parked.
"""
function suspend(f, term; mouse::Bool = false)
    mouse && print(mouse_reporting(false))
    term === nothing || REPL.Terminals.raw!(term, false)
    print("\e[?25h\e[?1049l")
    try
        f()
    finally
        print("\e[?1049h\e[?25l")
        term === nothing || REPL.Terminals.raw!(term, true)
        mouse && print(mouse_reporting(true))
    end
end

"""
    compose_external(suspend, initial) -> (text, note)

Hand `initial` to `\$EDITOR` in a temporary file, and take back whatever comes
out. `suspend` is a one-argument function that runs its argument with the
terminal given back - [`suspend`](@ref) bound to the host's own terminal, or
anything else that does the same job.

`InteractiveUtils.edit` is used rather than spawning `\$EDITOR` directly, so that
`JULIA_EDITOR` and the `define_editor` hooks apply and the editor that opens is
the one `edit()` would open at the REPL. It only waits for editors Julia knows
to be blocking, so a non-blocking one (`code` without `--wait`) returns
immediately and the file is read back unchanged. `note` is what to say about
that: an empty string when there is nothing to say, and otherwise a line for a
status bar. The text is never lost to it - a failed or instant edit gives back
what went in.
"""
function compose_external(suspend, initial::AbstractString)
    path = string(tempname(), ".md")
    write(path, initial)
    before = read(path, String)
    err = ""
    suspend() do
        try
            InteractiveUtils.edit(path)
        catch e
            err = first(sprint(showerror, e), 100)
        end
    end
    txt = try
        read(path, String)
    catch
        before
    end
    rm(path; force = true)
    isempty(err) ? (txt, txt == before ? "editor made no change" : "") : (before, err)
end
