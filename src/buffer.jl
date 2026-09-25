# The editing model, with no view attached and no loop around it.
#
# What a text area actually is: some lines, a cursor, and the operations
# readline taught everybody's fingers. None of that needs a screen, so none of
# it is allowed to know about one - `TextBuffer` is driven by calling functions
# on it, and a caller with an editing model but its own idea of how a box should
# look can stop reading here.
#
# Columns are counted in *characters*, not bytes and not display columns: `col`
# is 1 before the first character, `length(line) + 1` past the last. Bytes are
# wrong because a cursor lands between characters; display columns are wrong
# because a wide character is one place to be, not two. The one place widths
# matter is wrapping, which is `chunks` at the foot of this file.

"""A cursor over some lines of text.

`row` and `col` are 1-based, `col == 1` being before the first character of the
line. There is always at least one line, so an empty buffer is `[""]` and not
`String[]` - the cursor has to be somewhere.
"""
mutable struct TextBuffer
    lines::Vector{String}
    row::Int
    col::Int
    killed::String       # what the last run of kills took, for `^y`
    killing::Bool        # was the operation before this one a kill?
end

"""
    TextBuffer(s = "")

A buffer holding `s`, with the cursor at the end of it - which is where a
composer opened on an existing draft should start.

`\\r\\n` is normalised on the way in. It arrives from anything that has been
through a web form, and a line ending in a carriage return draws as one
character of rubbish at the end of every row.
"""
TextBuffer(s::AbstractString = "") =
    (b = TextBuffer([""], 1, 1, "", false); settext!(b, s); b)

"""The whole buffer as one string, lines joined by newlines."""
text(b::TextBuffer) = join(b.lines, "\n")

"""Replace everything, and put the cursor at the end."""
function settext!(b::TextBuffer, s::AbstractString)
    endkill!(b)
    ls = isempty(s) ? [""] : String.(split(replace(s, "\r\n" => "\n"), "\n"))
    b.lines = ls
    b.row = length(ls)
    b.col = length(last(ls)) + 1
    b
end

"""Is there anything here worth not throwing away?

The question a host asks before it decides whether escape needs confirming.
Whitespace does not count: a composer opened by mistake and escaped from
immediately has a newline in it as often as not.
"""
isblank(b::TextBuffer) = isempty(strip(text(b)))

"The line the cursor is on."
curline(b::TextBuffer) = b.lines[b.row]

"""Put the cursor somewhere legal.

Called after every operation rather than trusted to each of them: an operation
that shortens a line is the common case, and a cursor one past the end of a
line that is now shorter draws in a column that is not there.
"""
function clampcursor!(b::TextBuffer)
    isempty(b.lines) && push!(b.lines, "")
    b.row = clamp(b.row, 1, length(b.lines))
    b.col = clamp(b.col, 1, length(b.lines[b.row]) + 1)
    b
end

# --- the kill buffer --------------------------------------------------------
#
# One slot, not a ring. `^y` puts back what the last run of kills took, and
# `⌥y` - which would step back through earlier ones - is not here: a text area
# is a place to write a paragraph, and the second entry of a kill ring is
# somebody using it as their editor. `killed` is a plain string, so a host that
# wants a ring can keep one and set it.

"""Put `s` in the kill buffer.

Joined to what is already there when the operation before this one was also a
kill, which is what makes `^k^k^k` then `^y` give back three lines rather than
the last one. A *backward* kill goes on the front, so that `^w^w` yanks back in
the order it was typed rather than reversed.

Every other operation clears [`killing`](@ref TextBuffer), which is what ends a
run - so the accumulating is automatic for a caller driving the buffer directly
and needs no bookkeeping in the widget.
"""
function kill!(b::TextBuffer, s::AbstractString; backward::Bool = false)
    b.killed = !b.killing ? String(s) :
               backward ? string(s, b.killed) : string(b.killed, s)
    b.killing = true
    b
end

"""Anything that is not a kill ends the run the next one starts fresh from."""
endkill!(b::TextBuffer) = (b.killing = false; b)

# --- the two word rules -----------------------------------------------------

"""Column where the word before `col` starts, by one of readline's two rules.

Skip whatever does not count as a word immediately behind the cursor, then the
run that does. Which rule matters: `^w` is unix-word-rubout, delimited by
whitespace, and alt-backspace is backward-kill-word, delimited by anything
non-alphanumeric. On `/usr/local/lib` the first takes the whole path - there is
no whitespace to stop at - and the second takes only `lib`. Both are wanted,
which is why both keys exist, so `alnum` picks between them.
"""
function word_start(s::AbstractString, col::Int; alnum::Bool = false)
    inword(c) = alnum ? (isletter(c) || isnumeric(c)) : !isspace(c)
    cs = collect(s)
    i = min(col - 1, length(cs))
    while i >= 1 && !inword(cs[i]); i -= 1; end
    while i >= 1 && inword(cs[i]); i -= 1; end
    i + 1
end

"Column just past the word after `col`, by the same rule in the other direction."
function word_end(s::AbstractString, col::Int; alnum::Bool = false)
    inword(c) = alnum ? (isletter(c) || isnumeric(c)) : !isspace(c)
    cs = collect(s)
    i = max(col, 1)
    while i <= length(cs) && !inword(cs[i]); i += 1; end
    while i <= length(cs) && inword(cs[i]); i += 1; end
    i
end

# --- moving -----------------------------------------------------------------

"""
    move!(b, where) -> TextBuffer

Move the cursor. `where` is one of `:left`, `:right`, `:up`, `:down`, `:home`,
`:end`, `:wordleft`, `:wordright`, `:bufstart`, `:bufend`.

Horizontal movement crosses line boundaries and vertical movement keeps the
column it can - both of which are what every editor does, and both of which are
easy to leave out and then miss.
"""
function move!(b::TextBuffer, where::Symbol)
    clampcursor!(b)
    endkill!(b)
    l, n = curline(b), length(curline(b))
    if where === :left
        b.col > 1 ? (b.col -= 1) :
        b.row > 1 && (b.row -= 1; b.col = length(b.lines[b.row]) + 1)
    elseif where === :right
        b.col <= n ? (b.col += 1) :
        b.row < length(b.lines) && (b.row += 1; b.col = 1)
    elseif where === :up
        b.row > 1 && (b.row -= 1; b.col = min(b.col, length(b.lines[b.row]) + 1))
    elseif where === :down
        b.row < length(b.lines) && (b.row += 1; b.col = min(b.col, length(b.lines[b.row]) + 1))
    elseif where === :home
        b.col = 1
    elseif where === :end
        b.col = n + 1
    elseif where === :wordleft
        # At the front of a line, the word before the cursor is on the line
        # above - the same rule as `:left`, which is what makes holding the key
        # down walk backwards through a paragraph rather than stopping.
        b.col > 1 ? (b.col = word_start(l, b.col; alnum = true)) :
        b.row > 1 && (b.row -= 1; b.col = length(b.lines[b.row]) + 1)
    elseif where === :wordright
        b.col <= n ? (b.col = word_end(l, b.col; alnum = true)) :
        b.row < length(b.lines) && (b.row += 1; b.col = 1)
    elseif where === :bufstart
        b.row = 1; b.col = 1
    elseif where === :bufend
        b.row = length(b.lines); b.col = length(last(b.lines)) + 1
    end
    clampcursor!(b)
end

# --- changing ---------------------------------------------------------------

"Everything on the cursor's line before the cursor, and everything after it."
split_at_cursor(b::TextBuffer) =
    (String(first(curline(b), b.col - 1)),
     String(curline(b)[nextind(curline(b), 0, b.col):end]))

"""
    insert!(b, c) -> TextBuffer

Put one character in at the cursor and step over it.

`c` is whatever `keychar` handed back, which may not be a codepoint anybody
would recognise - see `Keys.K_BASE`. It is inserted as the bytes it is, because
they are the bytes somebody typed or pasted.
"""
function Base.insert!(b::TextBuffer, c::AbstractChar)
    clampcursor!(b); endkill!(b)
    head, tail = split_at_cursor(b)
    b.lines[b.row] = string(head, c, tail)
    b.col += 1
    b
end

"""Split the line at the cursor, leaving the cursor at the front of the new one."""
function newline!(b::TextBuffer)
    clampcursor!(b); endkill!(b)
    head, tail = split_at_cursor(b)
    b.lines[b.row] = head
    Base.insert!(b.lines, b.row + 1, tail)
    b.row += 1; b.col = 1
    b
end

"""
    insertblock!(b, s) -> TextBuffer

Drop several lines in at once - a quote, a template, a suggestion - splitting
the line the cursor is on, exactly as typing them would have.

An *empty* buffer takes the block whole with a blank line under it instead, so
the cursor ends up below the block rather than after it: text dropped into
nothing is what you are about to write under, not into.
"""
function insertblock!(b::TextBuffer, s::AbstractString)
    clampcursor!(b); endkill!(b)
    ins = String.(split(replace(String(s), "\r\n" => "\n"), "\n"))
    if length(b.lines) == 1 && isempty(b.lines[1])
        b.lines = vcat(ins, [""])
        b.row = length(b.lines)
    else
        head, tail = split_at_cursor(b)
        b.lines[b.row] = head
        for (j, x) in enumerate(ins)
            Base.insert!(b.lines, b.row + j, x)
        end
        Base.insert!(b.lines, b.row + length(ins) + 1, tail)
        b.row += length(ins) + 1
    end
    b.col = 1
    b
end

"""
    paste!(b, s) -> TextBuffer

Put `s` in at the cursor as text, however many lines it is, and leave the
cursor after it - where typing it would have.

What a bracketed paste delivers, and so not keys: a tab or a newline in it is
the character and nothing else. A terminal sends a pasted line break as `\\r`,
so each of `\\r\\n`, `\\r` and `\\n` is one. Every other control character is
dropped, since the buffer is drawn as it stands and an escape in it would be a
command to the terminal.
"""
function paste!(b::TextBuffer, s::AbstractString)
    clampcursor!(b); endkill!(b)
    s = replace(String(s), "\r\n" => "\n", '\r' => '\n')
    s = filter(c -> c == '\n' || c == '\t' || !iscntrl(c), s)
    isempty(s) && return b
    ins = String.(split(s, "\n"))
    head, tail = split_at_cursor(b)
    b.lines[b.row] = string(head, ins[1])
    for (j, x) in enumerate(ins[2:end])
        Base.insert!(b.lines, b.row + j, x)
    end
    b.row += length(ins) - 1
    b.col = length(b.lines[b.row]) + 1
    b.lines[b.row] *= tail
    b
end

"""Join the line the cursor is on onto the one above, cursor at the seam."""
function joinup!(b::TextBuffer)
    b.row > 1 || return b
    l = curline(b)
    prev = b.lines[b.row - 1]
    b.col = length(prev) + 1
    b.lines[b.row - 1] = string(prev, l)
    deleteat!(b.lines, b.row)
    b.row -= 1
    b
end

"""Delete the character before the cursor, joining lines when there is none."""
function backspace!(b::TextBuffer)
    clampcursor!(b); endkill!(b)
    l = curline(b)
    if b.col > 1
        b.lines[b.row] = string(first(l, b.col - 2), l[nextind(l, 0, b.col):end])
        b.col -= 1
        b
    else
        joinup!(b)
    end
end

"""Delete the character under the cursor, pulling the next line up when there is
none - which is what makes `^d` at the end of a line the inverse of `↵`."""
function deletechar!(b::TextBuffer)
    clampcursor!(b); endkill!(b)
    l, n = curline(b), length(curline(b))
    if b.col <= n
        b.lines[b.row] = string(first(l, b.col - 1), l[nextind(l, 0, b.col + 1):end])
    elseif b.row < length(b.lines)
        b.lines[b.row] = string(l, b.lines[b.row + 1])
        deleteat!(b.lines, b.row + 1)
    end
    b
end

"""`^k` (kill-line): everything from the cursor to the end of the line, or - on
an empty tail - the line break itself, which is what makes `^k^k` take a whole
line and its newline with it."""
function killline!(b::TextBuffer)
    clampcursor!(b)
    l, n = curline(b), length(curline(b))
    if b.col <= n
        kill!(b, l[nextind(l, 0, b.col):end])
        b.lines[b.row] = String(first(l, b.col - 1))
    elseif b.row < length(b.lines)
        kill!(b, "\n")
        b.lines[b.row] = string(l, b.lines[b.row + 1])
        deleteat!(b.lines, b.row + 1)
    end
    b
end

"""`^u` (unix-line-discard): from the cursor back to the start of the line.

Readline's rule, not zsh's - zsh binds `^u` to kill-whole-line, and the two only
differ when the cursor is not at the end of the line, which is exactly when
somebody meant one of them in particular.
"""
function killtostart!(b::TextBuffer)
    clampcursor!(b)
    l = curline(b)
    b.col > 1 || return b
    kill!(b, String(first(l, b.col - 1)); backward = true)
    b.lines[b.row] = String(l[nextind(l, 0, b.col):end])
    b.col = 1
    b
end

"""
    deleteword!(b; alnum = false) -> TextBuffer

`^w` (unix-word-rubout) and `⌥⌫` (backward-kill-word): the word before the
cursor. `alnum` picks the rule - see [`word_start`](@ref) - and at column 1
there is no word behind the cursor on this line, so the line break is what is
killed and the lines join, the way backspace joins them.
"""
function deleteword!(b::TextBuffer; alnum::Bool = false)
    clampcursor!(b)
    l = curline(b)
    ws = word_start(l, b.col; alnum = alnum)
    if ws < b.col
        kill!(b, String(l[nextind(l, 0, ws):prevind(l, nextind(l, 0, b.col))]);
              backward = true)
        b.lines[b.row] = string(first(l, ws - 1), l[nextind(l, 0, b.col):end])
        b.col = ws
        b
    elseif b.row > 1
        kill!(b, "\n"; backward = true)
        joinup!(b)
    else
        b
    end
end

"""
    killwordforward!(b) -> TextBuffer

`⌥d` (kill-word): from the cursor to the end of the word in front of it, by the
alphanumeric rule - the mirror of `⌥⌫`, and the reason both exist is that the
word behind you and the word in front of you are separately worth removing.
"""
function killwordforward!(b::TextBuffer)
    clampcursor!(b)
    l, n = curline(b), length(curline(b))
    we = word_end(l, b.col; alnum = true)
    if we > b.col && b.col <= n
        kill!(b, String(l[nextind(l, 0, b.col):prevind(l, nextind(l, 0, we))]))
        b.lines[b.row] = string(first(l, b.col - 1), l[nextind(l, 0, we):end])
    elseif b.col > n && b.row < length(b.lines)
        kill!(b, "\n")
        b.lines[b.row] = string(l, b.lines[b.row + 1])
        deleteat!(b.lines, b.row + 1)
    end
    b
end

"""
    yank!(b) -> TextBuffer

`^y`: put the last run of kills back at the cursor, which ends up after it.

Several lines go in as several lines, since that is what `^k^k` took. There is
no `⌥y` to step further back - see the note above the kill buffer.
"""
function yank!(b::TextBuffer)
    clampcursor!(b)
    isempty(b.killed) && return endkill!(b)
    parts = split(b.killed, '\n')
    head, tail = split_at_cursor(b)
    if length(parts) == 1
        b.lines[b.row] = string(head, parts[1], tail)
        b.col += length(parts[1])
    else
        b.lines[b.row] = string(head, parts[1])
        for (j, x) in enumerate(parts[2:end])
            insert!(b.lines, b.row + j, String(x))
        end
        b.row += length(parts) - 1
        b.col = length(last(parts)) + 1
        b.lines[b.row] = string(b.lines[b.row], tail)
    end
    endkill!(b)
end

"""
    transpose!(b) -> TextBuffer

`^t`: drag the character before the cursor forward over the one under it, and
the cursor with it. At the end of the line it swaps the last two instead, which
is readline's rule and is the case people actually hit - the typo is behind you
by the time you notice it.
"""
function transpose!(b::TextBuffer)
    clampcursor!(b)
    endkill!(b)
    cs = collect(curline(b))
    n = length(cs)
    i = b.col > n ? n : b.col      # the character at the cursor, or the last one
    (n < 2 || i < 2) && return b
    cs[i - 1], cs[i] = cs[i], cs[i - 1]
    b.lines[b.row] = String(cs)
    b.col = min(i + 1, n + 1)
    b
end

# --- where the cursor is on a wrapped screen --------------------------------

"""Split a line into fixed-width pieces, exactly as a text area draws it.

Not [`awrap`](@ref): that one carries ANSI state across the break and its wrap
points are its own business. Here the wrap has to be predictable in the *other*
direction - from a character offset to the row and column it lands on - so the
rule is the simplest one there is, and the text area owns it.
"""
function chunks(s::AbstractString, w::Int)
    w <= 0 && return [String(s)]
    isempty(s) && return [""]
    out, io, acc = String[], IOBuffer(), 0
    for c in s
        cw = textwidth(c)
        if acc + cw > w
            push!(out, String(take!(io))); acc = 0
        end
        write(io, c); acc += cw
    end
    push!(out, String(take!(io)))
    out
end

"""
    bufferrows(b, w) -> (rows, crow, ccol)

Every line of `b` wrapped to `w` columns, and where the cursor lands among the
result: `crow` indexes `rows`, `ccol` is a 1-based column within that row.

This is the mapping that makes a soft-wrapped text area behave. Getting it
wrong is not subtle - the cursor draws on the wrong row - but it is easy to get
wrong in exactly one place, at the end of a line whose width is a multiple of
the wrap: there the character offset says the cursor is at column `w + 1` of a
row that ended, and the answer is the row after it, which does not exist yet.
Every editor makes one, and so does this.
"""
function bufferrows(b::TextBuffer, w::Int)
    # A width of zero is a box with no room in it, which a host can ask for on
    # its way through a resize. One column is a legal answer; a modulo by zero
    # is not.
    w = max(1, w)
    rows, crow, ccol = String[], 1, 1
    for (i, l) in enumerate(b.lines)
        cs = chunks(l, w)
        if i == b.row
            pre = textwidth(String(first(l, max(0, b.col - 1))))
            pre > 0 && pre % w == 0 && length(cs) == pre ÷ w && push!(cs, "")
            crow = length(rows) + pre ÷ w + 1
            ccol = pre % w + 1
        end
        append!(rows, cs)
    end
    (rows, crow, ccol)
end
