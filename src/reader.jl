# Reading a terminal from a task, one event at a time.
#
# A loop that blocks in `readevent` cannot also hear anything else - a fetch
# that finished, a timer, a resize - and a loop that polls for input spins, or
# never ends on a stream that sends nothing more. The way out is a task that
# reads and a channel the loop waits on, with everything else that wakes the
# loop put on the same channel.
#
# But a task that loops on `read` is always in `read`, and so it is still
# reading while the terminal is handed to `$EDITOR`: it races the child for
# every keystroke, and the ones it wins are gone. So this one reads one event
# each time it is armed and is parked between them. The loop arms it when it is
# ready for the next event, and while it has not, nothing is reading.

"""
    EndEvent(why = nothing)

Input has ended: the terminal went away - end of file, or the pty gone - and
nothing more will ever arrive. What an [`InputReader`](@ref) puts on its
channel in place of the error, which is `why`: an `EOFError` or an `IOError`
is the terminal, and anything else is a read that failed some other way,
which a host may want to say something about.

An event and not an exception, because the loop is waiting on a channel and an
exception in the reading task would leave it waiting there for ever. The
program is being wound up either way; the difference is whether it gets to
[`leave_terminal`](@ref) on the way out.
"""
struct EndEvent
    why::Any
end
EndEvent() = EndEvent(nothing)

"""
    InputReader(in, events::Channel)
    InputReader(t::HeldTerminal, events::Channel)

A task that reads one event from `in` each time it is armed ([`arm!`](@ref)),
puts it on `events`, and is parked until it is armed again.

The channel is the host's, so whatever else wakes its loop - a background job
landing, a timer, a resize - goes on the same one, and the loop waits in one
place with no polling. When reading fails, at end of file or on a terminal
that has gone, it puts an [`EndEvent`](@ref) and stops.

Parked is what makes [`suspend`](@ref) safe: between an event and the next
`arm!` nothing is reading the terminal, so a child it is handed to gets every
key. A host arms it once it has finished with the event before - which is
where a key that opens `\$EDITOR` is handled - and not twice for one event.

`close(r)` lets it go: a reader that is parked ends there, and one that is
reading ends when its read does, and puts nothing more on `events` either way.
"""
mutable struct InputReader
    in::IO
    events::Channel
    ready::Channel{Any}          # host -> reader: read one event, with this
    task::Union{Nothing,Task}
    closed::Bool
end

function InputReader(in::IO, events::Channel)
    r = InputReader(in, events, Channel{Any}(1), nothing, false)
    r.task = @async begin
        while true
            readone = try
                take!(r.ready)
            catch
                break                       # closed: nobody wants more
            end
            ev = try
                readone(r.in)
            catch e
                # EOF because the terminal closed, EIO because the pty is gone.
                # The loop is waiting on its channel and nothing else is
                # coming, so it is told - unless it has already let go.
                r.closed || try
                    put!(r.events, EndEvent(e))
                catch
                end
                break
            end
            r.closed && break
            try
                put!(r.events, ev)
            catch
                break
            end
        end
    end
    r
end
InputReader(t::HeldTerminal, events::Channel) = InputReader(t.in, events)

"""
    arm!(r::InputReader, read = readevent)

Let `r` read one event, with `read(in)` - [`readevent`](@ref), or a host's own
for a stretch of input it wants some other way, undecoded to pass on to a
program it runs, say. Which one is decided here, by the loop, where it knows
what is in front of it, and not by the reader, which is parked between events.

`read` is called in the world the reader's task was started in, so it has to
be a method that existed then: one defined later - a closure evaluated after
the reader was made, a method added at a REPL - is the host's to reach, with
`Base.Fix1(invokelatest, f)` if it wants that.
"""
arm!(r::InputReader, read = readevent) = (put!(r.ready, read); r)

function Base.close(r::InputReader)
    r.closed = true
    isopen(r.ready) && close(r.ready)
    nothing
end
