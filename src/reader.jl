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

Made from a `HeldTerminal`, it notes the terminal's answers to the fence - a
[`FenceEvent`](@ref) is read, noted on the terminal, and the read goes on for
the event it was armed for - so the host never sees one. A read of the host's
own that is undecoded finds the answer with [`fence_in`](@ref) and returns that;
the reader notes it, and hands the event on only for its `rest`.

[`suspend!`](@ref) stops it reading, from any task, so that something else can
read the terminal for a while; `resume!` lets it go on. `close(r)` lets it go
for good: it puts nothing more on `events`, and ends. A reader that is parked
stops where it is. One that is in its read cannot be stopped there, and would
otherwise take whatever is typed next - at the prompt the program returns to,
or in the reader the terminal is handed to. Made from a `HeldTerminal` entered
with `fence`, both ask the terminal for a cut, and the reader reads up to it,
dropping everything it reads before - stale by the time anybody could act on
it - and stops there; both wait for that, so that when they return nothing is
reading. Otherwise, or if the answer does not come in
[`FENCE_PATIENCE`](@ref), the reader stops when its read does, and drops what
it read.
"""
mutable struct InputReader{T}
    ready::Channel{T}            # host -> reader: read one event, with this
    task::Union{Nothing,Task}
    term::Union{Nothing,HeldTerminal}
    # The rest is the reader's state, and every field of it - and the
    # terminal's fence count - is read and written under `cond`'s lock, since
    # `suspend!` may come from any thread.
    cond::Threads.Condition
    closed::Bool
    held::Int                    # `suspend!`s not yet `resume!`d
    reading::Bool                # in its read, and not to be stopped there
    cutting::Bool                # reading on to a fence's answer, dropping all
end

function InputReader(read, in::IO, events::Channel, ::Type{T},
                     term::Union{Nothing,HeldTerminal} = nothing) where {T}
    r = InputReader{T}(Channel{T}(1), nothing, term, Threads.Condition(), false, 0, false, false)
    r.task = @async readloop(r, read, in, events)
    r
end
InputReader(read, t::HeldTerminal, events::Channel, ::Type{T}) where {T} =
    InputReader(read, t.in, events, T, t)
InputReader(in, events::Channel) = InputReader(readkeys, in, events, Nothing)

readkeys(io::IO, ::Nothing) = readevent(io)

# The task's body, and a function so that it is compiled for the read, the
# stream and the channel it was handed, which nothing outside it ever sees.
function readloop(r::InputReader, read, in::IO, events::Channel)
    while true
        arg = try
            take!(r.ready)
        catch
            return                          # closed: nobody wants more
        end
        # Until an event for the host: an arming lasts through a `suspend!`,
        # and what is read before its cut is nobody's.
        while true
            lock(r.cond)
            try
                # Held, and not reading on to a cut: nothing reads.
                while r.held > 0 && !r.cutting && !r.closed
                    wait(r.cond)
                end
                # Closed before the read, or at its cut: nothing more is ours.
                r.closed && !r.cutting && return
                r.reading = true
            finally
                unlock(r.cond)
            end
            ev = try
                read(in, arg)
            catch e
                # EOF because the terminal closed, EIO because the pty is gone.
                # The loop is waiting on its channel and nothing else is coming,
                # so it is told - unless it has already let go.
                closed = @lock r.cond begin
                    r.reading = r.cutting = false
                    notify(r.cond)
                    r.closed
                end
                closed || try
                    put!(events, EndEvent(e))
                catch
                end
                return
            end
            ev = @lock r.cond read_done!(r, ev)
            ev === nothing && continue
            try
                put!(events, ev)
            catch
                return
            end
            break
        end
    end
end

# The event just read, as the host is to have it, or `nothing` for none: an
# answer to the fence noted, and anything read while held or closed dropped.
# Under the lock.
function read_done!(r::InputReader, ev)
    r.reading = false
    t = r.term
    if ev isa FenceEvent && t !== nothing
        answered!(t)
        # A raw read can hold the answers to two questions at once: the one
        # asked on the way in, and a cut's.
        rest = ev.rest
        while !isempty(rest)
            f = fence_in(t, rest)
            f === nothing && break
            answered!(t)
            rest = f.rest
        end
        if t.fences == 0 && r.cutting
            r.cutting = false               # the cut: whoever waits for it
            notify(r.cond)
        end
        (r.held > 0 || r.closed || isempty(rest)) && return nothing
        return FenceEvent(ev.attrs, rest)
    end
    r.held > 0 || r.closed ? nothing : ev
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

# Stop `r` reading, under its lock: a reader in its read is given a cut to
# read to, where the terminal answers, and waited for until it is there.
function cut!(r::InputReader)
    r.reading || return
    t = r.term
    (t === nothing || !t.fence) && return       # no stopping it: it drops what it reads
    # The question asked on the way in, while it is unanswered, is one already.
    t.answered && try
        ask!(t)
    catch
    end
    t.fences > 0 || return
    r.cutting = true
    deadline = fence_deadline(t, time())
    # A condition has no timeout, so a timer wakes the wait at the deadline.
    timer = Timer(max(deadline - time(), 0.0)) do _
        @lock r.cond notify(r.cond)
    end
    try
        while r.cutting && time() < deadline
            wait(r.cond)
        end
    finally
        close(timer)
    end
    if r.cutting                                # not answered in time
        r.cutting = false
        gave_up!(t)
        notify(r.cond)
    end
    nothing
end

"""
    suspend!(r::InputReader)
    suspend!(f, r::InputReader)

Stop `r` reading, so that something else can read the terminal - a child it is
handed to, a prompt, a reader of the host's own - until [`resume!`](@ref), or
for the duration of `f`. Callable from any task: it returns once nothing is
reading. A reader that is parked, or armed and not yet reading, does not read
until it is resumed. One that is in its read is given a cut to read to, on a
terminal entered with `fence`, and everything it reads up to it is dropped -
input meant for a screen that will have changed by the time anybody could act
on it. Without a fence, or with no answer in [`FENCE_PATIENCE`](@ref), there is
no stopping a read, and the next event the terminal sends is read and dropped.

An arming lasts through it: a reader armed when it is suspended reads the event
it was armed for once resumed, and `arm!` while it is suspended is kept for
then. Suspends nest, and the reader reads again once each has been resumed.

Only the reading is stopped. Whatever the host writes - its frames, and the
modes that [`suspend`](@ref) turns off and on - is the host's to keep from
landing in the middle of each other: `suspend!` on the task that draws, or
under the lock its drawing takes. Handing the terminal to a child is both:

    suspend!(reader) do
        suspend(term) do
            run(`vim \$path`)
        end
    end
"""
function suspend!(r::InputReader)
    @lock r.cond begin
        r.held += 1
        r.held == 1 && cut!(r)
    end
    nothing
end
function suspend!(f, r::InputReader)
    suspend!(r)
    try
        f()
    finally
        resume!(r)
    end
end

"""
    resume!(r::InputReader)

Undo one [`suspend!`](@ref): once each has been, `r` reads again - the event it
was armed for, if it was.
"""
function resume!(r::InputReader)
    @lock r.cond begin
        r.held = max(r.held - 1, 0)
        r.held == 0 && notify(r.cond)
    end
    nothing
end

function Base.close(r::InputReader)
    @lock r.cond begin
        r.closed = true
        cut!(r)
        notify(r.cond)
    end
    isopen(r.ready) && close(r.ready)
    nothing
end
