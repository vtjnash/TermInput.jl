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
    InputReader(read, in, events::Channel, T::Type)

A task that reads one event from `in` each time it is armed ([`arm!`](@ref)),
puts it on `events`, and is parked until it is armed again. `in` may be a
[`HeldTerminal`](@ref), for its input.

The channel is the host's, so whatever else wakes its loop - a background job
landing, a timer, a resize - goes on the same one, and the loop waits in one
place with no polling. When reading fails, at end of file or on a terminal
that has gone, it puts an [`EndEvent`](@ref) and stops.

Parked is what makes [`suspend`](@ref) safe: between an event and the next
`arm!` nothing is reading the terminal, so a child it is handed to gets every
key. A host arms it once it has finished with the event before - which is
where a key that opens `\$EDITOR` is handled - and not twice for one event.

The first form reads with [`readevent`](@ref). The second reads with
`read(in, arg)`, where `arg::T` is what each `arm!` was given: for a host that
reads some of its input another way - undecoded, to pass on to a program it
runs - and decides which way for each event, when it arms the reader and knows
what is in front of it, rather than in the reader, which is parked between
events and would be deciding against whatever was there last time. `read`, `in`
and `events` are the task's alone and only `arg` is sent, so the reader's type
is `InputReader{T}` and the task is compiled for what it was given.

    r = InputReader(term, events, Bool) do io, raw
        raw ? readraw(io) : readevent(io)
    end
    arm!(r, forwarding)

`close(r)` lets it go: a reader that is parked ends there, and one that is
reading ends when its read does, and puts nothing more on `events` either way.
"""
mutable struct InputReader{T}
    ready::Channel{T}            # host -> reader: read one event, with this
    task::Union{Nothing,Task}
    closed::Bool
end

function InputReader(read, in::IO, events::Channel, ::Type{T}) where {T}
    r = InputReader{T}(Channel{T}(1), nothing, false)
    r.task = @async readloop(r, read, in, events)
    r
end
InputReader(read, t::HeldTerminal, events::Channel, ::Type{T}) where {T} =
    InputReader(read, t.in, events, T)
InputReader(in, events::Channel) = InputReader(readkeys, in, events, Nothing)

readkeys(io::IO, ::Nothing) = readevent(io)

# The task's body, and a function so that it is compiled for the read, the
# stream and the channel it was handed, which nothing outside it ever sees.
function readloop(r::InputReader, read, in::IO, events::Channel)
    while true
        arg = try
            take!(r.ready)
        catch
            break                           # closed: nobody wants more
        end
        ev = try
            read(in, arg)
        catch e
            # EOF because the terminal closed, EIO because the pty is gone.
            # The loop is waiting on its channel and nothing else is coming,
            # so it is told - unless it has already let go.
            r.closed || try
                put!(events, EndEvent(e))
            catch
            end
            break
        end
        r.closed && break
        try
            put!(events, ev)
        catch
            break
        end
    end
end

"""
    arm!(r::InputReader)
    arm!(r::InputReader, arg)

Let `r` read one event: with [`readevent`](@ref), or with the `read` it was made
with, handed `arg` - which is how the loop says, for this event, which way to
read it.
"""
arm!(r::InputReader{Nothing}) = arm!(r, nothing)
arm!(r::InputReader{T}, arg::T) where {T} = (put!(r.ready, arg); r)

function Base.close(r::InputReader)
    r.closed = true
    isopen(r.ready) && close(r.ready)
    nothing
end
