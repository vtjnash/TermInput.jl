# A cut in a terminal's input, made by asking it something.
#
# Raw mode is what decides whose a byte is: in it the bytes are the loop's, out
# of it the prompt's or the child's. But the terminal goes on sending what it
# had to send - a report for every move of the pointer, the answer to a
# question - right up to the moment it reads the sequence that stops it, and
# there is no asking the kernel what is still queued: it does not say, for a
# tty. So turning the reports off and leaving raw mode in the same breath hands
# whatever was in flight to the next reader, as typing.
#
# The terminal can be asked instead. It answers in order, after everything it
# sent before, so reading up to its answer reads everything that was already
# on its way. Whether it answers at all is learnt once, from a question asked
# on the way in; a terminal that never does is never waited for again, and
# leaves as everything did before there was a fence.

"""
    FENCE_PATIENCE

Seconds to wait for the terminal's answer to [`FENCE_QUERY`](@ref) - from the
moment the first was asked, until one has been answered, and from each asking
after that. Seconds and not milliseconds, because over ssh a round trip is
anything from a millisecond to seconds and moves while it is measured; it is
the answer and not the clock that ends the wait, and the clock only stops a
link that has gone dead from holding the program for ever.
"""
const FENCE_PATIENCE = 3.0

# A question out, whose answer the next reader is to note.
function ask!(t::HeldTerminal)
    write(t.out, FENCE_QUERY)
    t.fences += 1
    nothing
end

# An answer read, wherever it was.
function answered!(t::HeldTerminal)
    t.fences = max(t.fences - 1, 0)
    t.answered = true
    nothing
end

# When to stop waiting for the answers out: `FENCE_PATIENCE` after the first
# question, while none has been answered, and after `from` once one has.
fence_deadline(t::HeldTerminal, from::Float64) =
    (t.answered ? from : t.asked) + FENCE_PATIENCE

# Gave up on what is out: forgotten, so nothing waits for it again - and a
# terminal that has never answered is not asked again either.
function gave_up!(t::HeldTerminal)
    t.fences = 0
    t.answered || (t.fence = false)
    nothing
end

# Read `t.in` up to the answer to a fence, dropping what comes before it. For
# `leave_terminal` and `suspend`, after the reports are off and before raw mode
# goes: nothing else may be reading.
function settle!(t::HeldTerminal)
    t.fence || return
    t.answered && ask!(t)
    deadline = fence_deadline(t, time())
    t.fences > 0 && drain!(t.in, t, deadline)
    t.fences > 0 && gave_up!(t)
    nothing
end

# A function of its own so that it is compiled for the stream it is handed.
function drain!(io::IO, t::HeldTerminal, deadline::Float64)
    while t.fences > 0 && wait_input(io, deadline - time())
        ev = try
            readevent(io)
        catch
            return                          # the terminal is gone: nothing to cut
        end
        ev isa FenceEvent && answered!(t)
    end
end

# Whether input has come within `secs`, without taking any of it. A stream
# that is not the event loop's - an `IOBuffer` - has all it will ever have.
#
# The wait is a task's, since a read cannot be given a timeout; it reads
# nothing, and the bytes it waits for stay where they are. One left waiting by
# a timeout keeps the stream reading from the kernel until something arrives,
# which a child the terminal is handed to would lose - so it is left only by a
# terminal that does not answer in `FENCE_PATIENCE`, which is then never asked
# again.
function wait_input(io::IO, secs::Float64)
    bytesavailable(io) > 0 && return true
    io isa Base.LibuvStream && secs > 0 || return false
    waiter = @async try
        eof(io)
    catch
        true
    end
    timedwait(() -> istaskdone(waiter), secs; pollint = 0.005) === :ok && bytesavailable(io) > 0
end

"""
    fence_in(t::HeldTerminal, bytes) -> Union{Nothing, FenceEvent}

The first answer to the fence in a raw read, taken out: a [`FenceEvent`](@ref)
whose `rest` is what the read held besides, in order - or `nothing` when the
read has none, or when no answer is being waited for. For a host that reads
some of its input undecoded, to pass on to a program it runs, from the read
it gives an [`InputReader`](@ref): the reader notes the answer, takes out any
more there are while more are waited for, and hands on the rest.

Only while one is waited for, because then it is ours: a program the input is
passed on to may ask the terminal the same question, and its answer, when
nothing here asked, is its own.
"""
function fence_in(t::HeldTerminal, bytes::AbstractVector{UInt8})
    t.fences > 0 || return nothing
    s = String(copy(bytes))
    m = match(FENCE_REPORT, s)
    m === nothing && return nothing
    i = m.offset
    j = i + ncodeunits(m.match)
    FenceEvent(String(something(m[1])), vcat(bytes[1:i-1], bytes[j:end]))
end
