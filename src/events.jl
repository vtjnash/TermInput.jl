# Bytes from a terminal, as the events they are.
#
# `REPL.TerminalMenus.readkey` is what people reach for, and it is wrong in two
# ways that both matter to a widget. It cannot see a mouse report at all -
# `\e[<0;40;12M` is not a key - and it drops any sequence it does not recognise
# as a bare Escape, leaving the tail in the buffer to arrive as separate
# keystrokes. That is what makes Shift-Tab (`CSI Z`) read as Escape-then-Z, and
# a host that binds Escape to closing something closes it.
#
# Everything here is a pure function of a byte stream, so it can be driven from
# an `IOBuffer` rather than needing a terminal. It holds no mode and runs no
# loop: `readevent` reads one event and returns, and what calls it is the
# host's.

"""
    KeyEvent(code)

One key, as its code in the [`Keys`](@ref) vocabulary: what `handle!` takes.
[`K_NONE`](@ref) is a sequence that was read whole and is no key.
"""
struct KeyEvent
    code::Int
end

"""
    PasteEvent(text)

A bracketed paste: what arrived between `ESC [ 200 ~` and `ESC [ 201 ~`.

Text and never keys. With [`bracketed_paste`](@ref) on, a paste cannot be read
as commands - a `q` in it is not quitting and a tab in it is not moving the
focus - so it goes to `paste!` on whatever has somewhere to put text, and a host
with nowhere ignores it.
"""
struct PasteEvent
    text::String
end

"""
    MouseEvent(kind, button, x, y, mods)

One mouse report, with [`mouse_reporting`](@ref) on.

`kind` is `:press`, `:drag`, `:release`, `:wheelup` or `:wheeldown`; `x` and `y`
are 1-based screen columns and rows, as the terminal counts them, so they index
the frame `render` just drew - and are what `click!` takes. `mods` is a bit
each: 1 shift, 2 alt, 4 ctrl.
"""
struct MouseEvent
    kind::Symbol
    button::Int
    x::Int
    y::Int
    mods::Int
end

"""
    SchemeEvent(dark, bg, rest)

The terminal says whether its colours are dark or light, or what its background
is. Asked for by [`scheme_reports`](@ref).

`dark` is from `CSI ? 997 ; 1 n` (dark) or `; 2 n` (light): the answer to
`CSI ? 996 n` and, once `CSI ? 2031 h` is set, sent again by itself whenever it
changes (xterm.js from the 6.1 betas, which is VS Code's terminal; tmux from
3.6; the spec is contour's, "color palette update notifications"). `nothing`
when the report was the other kind.

`bg` is from `OSC 11 ; <colour> ST`, the answer to [`BG_QUERY`](@ref), exactly
as the terminal spelled the colour; `""` for a scheme report. Not a judgement of
dark or light - that is what 997 says outright - but a colour a host may have
somewhere to pass on, a program it runs that asks the same question.

An event of its own and not a key, because it is not something anybody typed
and nothing binds it: what a host does with dark or light - a theme, a redraw,
nothing - is the host's. Either answer comes whenever the terminal sends it and
a terminal that does not know the question says nothing, so nothing should
wait for one.

`rest` is always empty from [`readevent`](@ref). It is for a host that reads
some of its input undecoded - to pass it on to a program it runs - and takes a
report out of a raw read with [`SCHEME_REPORT`](@ref) and [`BG_REPORT`](@ref):
`rest` is then what the read held besides the report, in order.
"""
struct SchemeEvent
    dark::Union{Nothing,Bool}
    bg::String
    rest::Vector{UInt8}
end
SchemeEvent(dark::Bool, rest::Vector{UInt8}) = SchemeEvent(dark, "", rest)

"""
    BG_QUERY

Asks for the terminal's background colour: `OSC 11 ?`. The answer is a
[`SchemeEvent`](@ref) with its `bg` set.
"""
const BG_QUERY = "\e]11;?\e\\"

"""
    scheme_reports(on) -> String

The sequences that ask for [`SchemeEvent`](@ref)s - dark or light now, again
on each change as it happens, and the background colour now - and that stop
them. Off while the terminal is handed to somebody else ([`suspend`](@ref)),
whose input a report would land in, and asked again after, since the scheme
may have changed while it was away.
"""
scheme_reports(on::Bool) = on ? string("\e[?2031h\e[?996n", BG_QUERY) : "\e[?2031l"

"""
    SCHEME_REPORT

The dark-or-light report, `CSI ? 997 ; 1|2 n`, as a `Regex` whose one capture
is `1` for dark and `2` for light. For a host taking one out of input it reads
undecoded; [`readevent`](@ref) decodes it itself.
"""
const SCHEME_REPORT = r"\e\[\?997;([12])n"

"""
    BG_REPORT

The answer to [`BG_QUERY`](@ref), ended by `BEL` or `ST` as the terminal likes,
as a `Regex` whose one capture is the colour. The colour is held to what a host
could pass on intact: printable, and short enough for a multiplexer's own
buffer (tmux's is 128 bytes).
"""
const BG_REPORT = r"\e\]11;([\x21-\x7e]{1,100})(?:\a|\e\\)"

"""
    readevent(io) -> KeyEvent | PasteEvent | MouseEvent | SchemeEvent

Read one input event from a terminal in raw mode. Blocks for the first byte,
and - once `ESC [` or `ESC ]` has been seen and a sequence is therefore
certain - for the rest of that sequence, however many reads it takes.

A sequence it cannot place is consumed whole and comes back as
`KeyEvent(K_NONE)`, which nothing binds. That is the point of it: a half-read
sequence is worse than an ignored one, because its tail arrives as
plausible-looking keystrokes.

What it reads is the dialect terminals speak by default, and xterm's:

  * a byte, or a UTF-8 sequence carried as the bytes it was - see
    [`K_BASE`](@ref) - never decoded, so nothing is thrown away
  * `CSI` and `SS3` keys - the arrows, Home, End, Page Up and Down, Delete,
    Shift-Tab - with xterm's modifiers: alt or ctrl on a horizontal arrow is
    the word, and shift on a vertical one is [`K_SUP`](@ref)/[`K_SDOWN`](@ref)
  * the three spellings of Alt that are all in use - see below
  * SGR mouse reports ([`MouseEvent`](@ref)), bracketed pastes
    ([`PasteEvent`](@ref)), and the scheme and background reports
    ([`SchemeEvent`](@ref))

A bare Escape is told from the head of a sequence by whether anything is
already waiting behind it: a terminal writes a sequence in one write, and a
person pressing Escape then `[` does not.

It never decides anything by the clock, so it can be driven from an `IOBuffer`.
A host that reads keys some other way - a multiplexer that has already put
them in one form, the kitty keyboard protocol, something that is not a terminal
at all - writes its own and keeps the widgets.
"""
function readevent(io::IO)
    b = read(io, UInt8)
    if b >= 0x80
        # Whatever arrived, carried as the bytes it was. Assembling the sequence
        # here - rather than handing each byte on separately - is what keeps
        # every widget dealing in characters: left as bytes, an accented letter
        # inserted three separate nothings. But it is assembled and not
        # *decoded*, because a codepoint cannot hold what a terminal can send:
        # see `K_BASE`.
        #
        # The framing is Julia's, so a sequence stored in a buffer is read back
        # out of it as the same one `Char`. `0xF8` and above lead nothing, a
        # continuation byte with no lead is itself, and a sequence whose
        # continuation never came is its lead byte alone - which is why the next
        # byte is looked at and not taken.
        n = b >= 0xf8 ? 0 : b >= 0xf0 ? 3 : b >= 0xe0 ? 2 : b >= 0xc0 ? 1 : 0
        k = Int(b)
        for _ in 1:n
            eof(io) && break
            (peek(io, UInt8) & 0xc0) == 0x80 || break
            k = (k << 8) | Int(read(io, UInt8))
        end
        return KeyEvent(k)
    end
    b == 0x1b || return KeyEvent(Int(b))
    # A bare 27 is Escape; 27 with bytes behind it heads a sequence.
    bytesavailable(io) == 0 && return KeyEvent(27)
    a = read(io, UInt8)
    # `ESC ]` heads an OSC, as `ESC [` heads a CSI, and is read to its end
    # whenever it arrives: the answer to `BG_QUERY` comes when the terminal
    # sends it, and the part of it not yet here would otherwise be keys. Alt-]
    # is spent on that.
    a == UInt8(']') && return read_osc(io)
    if a != UInt8('[') && a != UInt8('O')
        # ESC-prefixed: the terminal is sending Meta/Alt as "escape, then the
        # key". Which of the three spellings below arrives depends on the
        # terminal and its settings, and they are all in use - Terminal.app
        # sends `ESC b` for Alt-Left, iTerm in Esc+ mode sends `ESC ESC [ D`,
        # and everything sends `ESC DEL` for Alt-Backspace.
        a == 0x7f && return KeyEvent(K_WORD_BACK)
        a == UInt8('b') && return KeyEvent(K_WORD_LEFT)
        a == UInt8('f') && return KeyEvent(K_WORD_RIGHT)
        # `ESC d` is kill-word, the mirror of alt-backspace. The text widgets
        # bind both, and the difference between them is the whole reason
        # readline has two.
        a == UInt8('d') && return KeyEvent(K_WORD_KILL)
        # The REPL binds `\ee` to edit_input - the same move `K_EDIT` makes, so
        # the same key.
        a == UInt8('e') && return KeyEvent(K_EDIT)
        if a == 0x1b && bytesavailable(io) > 0
            # `ESC ESC [ D`: the second ESC opens the arrow's own sequence, so
            # it is the head of a CSI and not a byte to step over.
            c = read(io, UInt8)
            if c == UInt8('[') || c == UInt8('O')
                ev = read_csi(io)
                ev isa KeyEvent && ev.code == K_LEFT && return KeyEvent(K_WORD_LEFT)
                ev isa KeyEvent && ev.code == K_RIGHT && return KeyEvent(K_WORD_RIGHT)
            end
        end
        return KeyEvent(K_NONE)
    end
    read_csi(io)
end

# The body of an OSC, with its `ESC ]` already read, to `BEL` or `ST`: the
# background colour as a `SchemeEvent`, and any other OSC as nothing. A body
# past any answer's length, or an `ESC` that is not `ST`, ends it where it is.
function read_osc(io::IO)
    body = UInt8[0x1b, UInt8(']')]
    while length(body) < 160 && !eof(io)
        c = read(io, UInt8)
        push!(body, c)
        c == 0x07 && break
        if c == 0x1b
            eof(io) && break
            push!(body, read(io, UInt8))
            break
        end
    end
    m = match(BG_REPORT, String(body))
    m === nothing || m.offset != 1 ? KeyEvent(K_NONE) : SchemeEvent(nothing, String(something(m[1])), UInt8[])
end

# The body of a CSI sequence, with its `ESC [` already read.
function read_csi(io::IO)
    params, fin = UInt8[], 0x00
    while true
        c = read(io, UInt8)
        # A mouse report ends at `M` or `m` and nowhere else. xterm.js sends
        # `<0;NaN;NaNm` for a button let go over a terminal it cannot place,
        # and ended at the first byte that could end any other sequence - the
        # `N` - the rest arrived as keys, `m` among them.
        mouse = !isempty(params) && params[1] == UInt8('<')
        if mouse ? (c == UInt8('M') || c == UInt8('m')) : (c >= 0x40 && c <= 0x7e)
            fin = c
            break
        end
        push!(params, c)
        length(params) > 32 && return KeyEvent(K_NONE)    # not a sequence a terminal sends
    end
    fin == UInt8('~') && params == b"200" && return read_paste(io)
    decode_csi(String(params), Char(fin))
end

# The rest of a bracketed paste, its start marker already read: everything up
# to the end marker, which is waited for - once the start has arrived the end is
# certain, however many reads the text between takes.
function read_paste(io::IO)
    buf = UInt8[]
    stop = b"\e[201~"
    while !(length(buf) >= length(stop) && view(buf, length(buf)-length(stop)+1:length(buf)) == stop)
        eof(io) && return PasteEvent(String(buf))
        push!(buf, read(io, UInt8))
    end
    PasteEvent(String(resize!(buf, length(buf) - length(stop))))
end

function decode_csi(params::String, fin::Char)
    startswith(params, "<") && (fin == 'M' || fin == 'm') &&
        return decode_mouse(params[2:end], fin == 'M')
    # `CSI 1;3D` is Alt-Left: the second parameter carries the modifiers, as
    # 1 + shift + 2·alt + 4·ctrl. Either alt or ctrl on an arrow means the word,
    # which is what both of them do everywhere else.
    parts = split(params, ';')
    mod = length(parts) >= 2 ? something(tryparse(Int, String(parts[2])), 1) : 1
    byword = (mod - 1) & 0x06 != 0
    # Shift is the one modifier the vertical arrows carry a meaning for, and it
    # is the same one it has in every list anybody has ever selected in.
    shifted = (mod - 1) & 0x01 != 0
    fin == 'A' && return KeyEvent(shifted ? K_SUP : K_UP)
    fin == 'B' && return KeyEvent(shifted ? K_SDOWN : K_DOWN)
    fin == 'C' && return KeyEvent(byword ? K_WORD_RIGHT : K_RIGHT)
    fin == 'D' && return KeyEvent(byword ? K_WORD_LEFT : K_LEFT)
    fin == 'H' && return KeyEvent(K_HOME)
    fin == 'F' && return KeyEvent(K_END)
    fin == 'Z' && return KeyEvent(K_STAB)
    fin == 'n' && params in ("?997;1", "?997;2") && return SchemeEvent(params[end] == '1', UInt8[])
    if fin == '~'
        # `CSI 5 ~` and `CSI 5 ; 2 ~` are the same key, modified.
        n = tryparse(Int, String(first(split(params, ';'))))
        n == 1 && return KeyEvent(K_HOME)
        n == 3 && return KeyEvent(K_DEL)
        n == 4 && return KeyEvent(K_END)
        n == 5 && return KeyEvent(K_PGUP)
        n == 6 && return KeyEvent(K_PGDN)
        n == 7 && return KeyEvent(K_HOME)
        n == 8 && return KeyEvent(K_END)
    end
    KeyEvent(K_NONE)
end

# The body of an SGR mouse report (`CSI < b ; x ; y M|m`).
#
# The button byte packs the button in its low two bits, the modifiers above
# them, motion at 32 and the wheel at 64 - so a wheel notch is button 64/65 and
# a drag is the button number plus 32. `m` as the final byte means release; the
# wheel only ever reports `M`.
function decode_mouse(body::AbstractString, pressed::Bool)
    p = split(body, ';')
    length(p) == 3 || return KeyEvent(K_NONE)
    b, x, y = tryparse(Int, p[1]), tryparse(Int, p[2]), tryparse(Int, p[3])
    (b === nothing || x === nothing || y === nothing) && return KeyEvent(K_NONE)
    kind = if b & 64 != 0
        (b & 3) == 0 ? :wheelup : (b & 3) == 1 ? :wheeldown : :other
    elseif !pressed
        :release
    elseif b & 32 != 0
        :drag
    else
        :press
    end
    kind === :other && return KeyEvent(K_NONE)
    mods = ((b & 4) != 0 ? 1 : 0) | ((b & 8) != 0 ? 2 : 0) | ((b & 16) != 0 ? 4 : 0)
    MouseEvent(kind, b & 3, x, y, mods)
end
