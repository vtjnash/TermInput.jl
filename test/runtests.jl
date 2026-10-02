# What can be tested without a terminal, which here is everything.
#
# `render` is a pure function of a widget and a size, `handle!` takes a key code
# and returns an action, and the editing model underneath both is a function of
# a buffer. `readevent` reads any stream, and an `IOBuffer` is one, so nothing
# needs a tty - and the one thing that touches a real terminal, `suspend`, is
# asserted on the escape sequences it writes to stdout.
#
#     julia --project=. test/runtests.jl

using Test
using TermInput
import TermInput: render, caret, handle!, text, chunks, drawcursor, field, drawfield, displaycolumn
# The public names that are not exported, as a host would import them.
import TermInput: settext!, curline, move!, newline!, insertblock!, paste!,
    backspace!, deletechar!, killline!, killtostart!, deleteword!, killwordforward!,
    kill!, yank!, transpose!, wordstart, wordend, bufferrows, boxstyle, dialogbox,
    centred, CHROME, ACTIONS, click!, query, query!, selected, matches, doubled,
    DOUBLECLICK, oneline, column, BOXES, Box, BoxLine, BG_QUERY, SCHEME_REPORT, BG_REPORT, HeldTerminal
import TermInput: Row, verbatim, linked, overlaid, rowhead, rowtail, rowlines, rowwraplines
import InteractiveUtils
import StyledStrings: Face, SimpleColor
import StyledStrings

# StyledStrings writes an attribute only when the terminfo for `TERM` has it,
# and a runner has no `TERM` - `dumb`, with no reverse video, dim or italics.
# These tests assert on the escapes, so the terminfo already loaded is told it
# has them: 1.11 reads it before any code runs, and 1.10's StyledStrings has no
# database of its own to read another from on Windows. It is the same struct in
# all three places - StyledStrings' global before 1.11, Base's global in 1.11,
# and Base's once-per-process value after.
let ti = isdefined(Base, :current_terminfo) ? Base.current_terminfo :
                                              StyledStrings.current_terminfo
    ti = applicable(ti) ? ti() : ti
    merge!(ti.strings, Dict(:enter_dim_mode => "\e[2m", :enter_italics_mode => "\e[3m",
                            :enter_reverse_mode => "\e[7m", :enter_strikeout_mode => "\e[9m"))
    merge!(ti.aliases, Dict(:dim => :enter_dim_mode, :smxx => :enter_strikeout_mode))
end

# What StyledStrings writes for a row, which is what a terminal is sent; and a
# frame of them, a row to a line.
ansi(r::AbstractString) = sprint(print, r; context = :color => true)
screen(rows::AbstractVector) = join(ansi.(rows), "\n")
const REV = Face(inverse = true)
# What a string of escapes says on the screen, as against how it looks; and the
# columns it takes there.
const SGR_OSC = r"\e\[[0-9;:]*[A-Za-z]|\e\][^\e]*\e[\\]"
unescaped(s::AbstractString) = replace(String(s), SGR_OSC => "")
cols(s::AbstractString) = textwidth(unescaped(s))
# What is on the screen under the terminal's cursor, where `caret` puts it: the
# character that starts at its column, or `nothing` - in the middle of a wide
# one, or off the end.
function cellat(v, w, h)
    r, c = caret(v, w, h)
    acc = 1
    for ch in unescaped(ansi(render(v, w, h)[r]))
        acc == c && return string(ch)
        acc += textwidth(ch)
        acc > c && return nothing
    end
    nothing
end

@testset "TermInput" begin

@testset "a name too long for its column is told apart at the end" begin
    # Names in a fixed column agree at the front and differ at the end far more
    # often than the other way round - branches under one owner prefix, urls
    # into one issue - so cutting at the tail draws a pair like that as the
    # *same string*, and a list whose job is telling two of something apart then
    # tells you nothing.
    a = "users/someone/tsa-tryheld-state"
    b = "users/someone/tsa-tryheld-other"
    @test rowfit(a, 26) == rowfit(b, 26)          # what eliding at the tail does
    @test rowmid(a, 26) != rowmid(b, 26)          # and what this does instead
    @test rowwidth(rowmid(a, 26)) == 26
    @test endswith(String(rowmid(a, 26)), "state") && startswith(String(rowmid(a, 26)), "users/")
    # Short enough is left exactly as it was.
    @test rowmid("patch-11", 26) == "patch-11" && rowmid("", 26) == ""
    @test rowmid("anything", 0) == ""
    # Never wider than asked, at any width worth drawing. Below three columns
    # there is no room for a head, a mark and a tail, and the arithmetic that
    # spends `w - 1` on each end would come back one column too wide.
    for w in 1:40, s in (a, b, "x", "abcdefgh")
        @test rowwidth(rowmid(s, w)) <= w
    end
    # A wide character is not split down the middle to make the count come out.
    @test rowwidth(rowmid("日本語のブランチ名前です", 11)) <= 11
end

@testset "a row of faces is measured, cut and wrapped by its text" begin
    # What StyledStrings writes for a row, which is what a terminal is sent.
    out(r) = sprint(print, r; context = :color => true)
    b, red = Face(weight = :bold), Face(foreground = SimpleColor(:red))
    # A face takes no columns: the width is the text's.
    @test rowwidth("plain") == 5 && rowwidth(faced("green", red)) == 5
    @test rowwidth(faced("日本", b)) == 4
    # A verbatim piece is as wide as it says, whatever is in it: somebody
    # else's escapes, never measured.
    v = verbatim("\e[31mxyz\e[0m", 3)
    @test rowwidth(v) == 3 && rowwidth(rowcat("ab", v, "cd")) == 7
    @test out(rowcat("ab", v)) == "ab\e[31mxyz\e[0m"
    # Fitting and padding, as for plain text.
    @test String(rowfit("abcdefgh", 4)) == "abc…" && String(rowfit("abc", 10)) == "abc"
    @test String(rowfit("abc", 0)) == "" && String(rowpad("ab", 5)) == "ab   "
    @test rowwidth(rowpad(faced("abcdefgh", b), 5)) == 5
    # A cut keeps the faces over what it kept, and the mark is in the face it
    # cut through; plain text cut short is still plain.
    f = rowfit(faced("abcdefgh", b), 4)
    @test out(f) == out(faced("abc…", b))
    @test out(rowfit("abcdefgh", 4)) == "abc…"
    @test out(rowcat("ab", faced("cdefgh", red))) != out(rowcat("ab", "cdefgh"))
    # The padding carries no face, so nothing is painted past the text.
    @test endswith(out(rowpad(faced("ab", Face(background = SimpleColor(:red))), 5)), "   ")
    # A verbatim piece is never cut into: it goes whole or not at all.
    r = rowcat("ab", v, "cd")
    @test String(rowhead(r, 4)) == "ab" && String(rowhead(r, 5)) == String(rowcat("ab", v))
    @test String(rowtail(r, 4)) == "cd" && String(rowfit(r, 4)) == "ab…"
    @test rowwidth(rowpad(r, 4)) <= 4 && rowwidth(rowpad(r, 9)) == 9
    # Eliding in the middle keeps the faces of what it keeps.
    @test ansi(rowmid(faced("users/someone/tsa-tryheld-state", b), 26)) ==
          ansi(faced(rowmid("users/someone/tsa-tryheld-state", 26), b))
    # Wrapping breaks at the last space that fits and drops it; a run wider
    # than the row is split, graphemes whole.
    @test String.(rowwrap("guard the remaining raw stderr writes that gate cleanup", 40)) ==
          ["guard the remaining raw stderr writes", "that gate cleanup"]
    @test String.(rowwrap("x"^10, 4)) == ["xxxx", "xxxx", "xx"]
    @test String.(rowwrap("ab cd", 4; hard = true)) == ["ab c", "d"]
    @test String.(rowwrap("e\u0301e\u0301e\u0301", 2)) == ["e\u0301e\u0301", "e\u0301"]
    # A face across the break is on both rows, and each row ends it: nothing
    # is open where a row ends, so padding it paints nothing.
    w = rowwrap(rowcat("aa ", faced("bbb ccc", red), " dd"), 6)
    @test String.(w) == ["aa bbb", "ccc dd"]
    @test out(w[1]) == out(rowcat("aa ", faced("bbb", red)))
    @test out(w[2]) == out(rowcat(faced("ccc", red), " dd"))
    # So is a link: every row's link is closed on that row.
    lk = rowwrap(rowcat("see ", linked("the linked words here", "https://x.example/a"), " after"), 12)
    @test length(lk) >= 3 && all(rowwidth(l) <= 12 for l in lk)
    @test all(count("\e]8;;https", out(l)) == count("\e]8;;\e\\", out(l)) for l in lk)
    @test count(l -> occursin("\e]8;;https", out(l)), lk) >= 2
    # A verbatim piece wider than the row is a row of its own, not split.
    vw = rowwrap(rowcat("a ", verbatim("\e[1mxxxxxx", 6), " b"), 4)
    @test String.(vw) == ["a", "\e[1mxxxxxx", "b"]
    # Lines, each wrapped; a newline is on no row.
    @test String.(rowwraplines("one two\nthree", 4)) == ["one", "two", "thre", "e"]
    @test String.(TermInput.rowlines(faced("a\n\nb", b))) == ["a", "", "b"]
    @test out(TermInput.rowlines(faced("a\nb", b))[2]) == out(faced("b", b))
    # Nothing lost or gained by a wrap but the spaces it broke at.
    for t in ("short", "", "a b c d e f g h i j k l m n o p q r s t",
              "https://github.com/JuliaLang/julia/pull/62841#issuecomment-372112478 see")
        for w in (5, 12, 40)
            rs = rowwrap(t, w)
            @test all(rowwidth(l) <= w for l in rs)
            @test replace(join(String.(rs)), " " => "") == replace(t, " " => "")
        end
    end
    # An empty face is no annotation, and so no escape at all.
    @test out(faced("plain", Face())) == "plain"
    # Over and under: a face laid under a row loses to the row's own where
    # both say a colour; one laid over wins.
    bg(c) = Face(background = SimpleColor(c))
    word = rowcat("a ", faced("b", bg(:red)))
    @test out(faced(word, bg(:blue))) == out(rowcat(faced("a ", bg(:blue)), faced("b", bg(:red))))
    @test out(TermInput.overlaid(word, 1:3, bg(:blue))) == out(faced("a b", bg(:blue)))
end

@testset "a key code is the bytes that arrived, and nothing is thrown away" begin
    # A key code used to be a codepoint, and the keys began at `0x110000`, one
    # past the last one. Both halves of that were wrong. A lead byte of `0xF0`
    # or above carries three bits and each continuation six, so a malformed
    # four-byte sequence assembles to as much as `0x1FFFFF`: `F4 90 80 80` came
    # out as exactly `K_LEFT`, and a paste of arbitrary bytes moved the cursor.
    #
    # Rejecting the malformed ones would have fixed that and still been wrong.
    # Julia does not need us to: a `Char` is four bytes of UTF-8 held as they
    # came, and arbitrary binary survives a round trip through a `String`
    # intact - it is only `codepoint` that refuses.
    @test K_BASE == 1 << 32
    @test !printable(K_LEFT) && !printable(K_BASE)
    for k in (K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP,
              K_PGDN, K_STAB, K_WORD_LEFT, K_WORD_RIGHT, K_WORD_BACK, K_EDIT,
              K_SUP, K_SDOWN)
        @test k > 0xFFFFFFFF
    end
    # `keychar` and `keycode` are inverses, over every width and over sequences
    # that are not characters at all.
    for c in ('a', 'é', '€', '😀', '\0', '\x7f')
        @test keychar(keycode(c)) === c
    end
    for bs in ((0x61,), (0xC3, 0xA9), (0xE2, 0x82, 0xAC), (0xF0, 0x9F, 0x98, 0x80),
               (0xF4, 0x90, 0x80, 0x80), (0xED, 0xA0, 0x80), (0xC0, 0x80), (0x80,), (0xF8,))
        # The bytes, packed big-endian, which is what a decoder hands over.
        k = foldl((a, b) -> (a << 8) | Int(b), bs; init = 0)
        @test collect(codeunits(string(keychar(k)))) == collect(UInt8[bs...])
        @test keycode(keychar(k)) == k
    end
    # Shift-Up in a widget with no selection to extend is the arrow it is drawn
    # on: a key that does nothing at all reads as a terminal that has stopped
    # responding.
    @test unshift(K_SUP) == K_UP && unshift(K_SDOWN) == K_DOWN
    @test unshift(Int('j')) == Int('j')
    # Reaching the vocabulary either way is the same constant.
    @test Keys.K_LEFT === K_LEFT && Keys.C_W === C_W
end

@testset "the bytes that arrived are the key, and nothing is thrown away" begin
    # What `readevent` hands over for anything past ASCII is the sequence as it
    # came, packed - never a codepoint, which some of these do not have and
    # others have one that was never typed.
    raw(bs...) = readevent(IOBuffer(UInt8[bs...])).code
    kept(bs...) = collect(codeunits(string(keychar(raw(bs...))))) == collect(UInt8[bs...])
    @test kept(0xF4, 0x90, 0x80, 0x80)      # out of range: once exactly `K_LEFT`
    @test kept(0xED, 0xA0, 0x80)            # a surrogate half
    @test kept(0xC0, 0x80)                  # an overlong NUL
    @test kept(0x80)                        # a continuation with no lead
    @test kept(0xF8)                        # never a lead byte at all
    @test kept(0xFF)
    @test kept(0xC3, 0xA9) && kept(0xE2, 0x82, 0xAC) && kept(0xF0, 0x9F, 0x98, 0x80)

    # One byte is its own code, so the bindings are what they always were.
    @test raw(UInt8('j')) == Int('j')
    @test readevent(IOBuffer("\r")) == KeyEvent(13)
    # Above that is the sequence, in order - always past `0xFF`, since the lead
    # byte of a multi-byte one is at least `0xC0` - and always below `K_BASE`.
    @test raw(0xC3, 0xA9) == 0xC3A9
    @test raw(0xF0, 0x9F, 0x98, 0x80) == 0xF09F9880
    @test all(raw(b...) > 0xFF for b in ((0xC3,0xA9), (0xE2,0x82,0xAC), (0xF0,0x9F,0x98,0x80)))
    @test all(raw(b...) < K_BASE for b in ((0xF4,0x90,0x80,0x80), (0xFF,), (0xF8,)))

    # The framing is Julia's own, so a sequence stored in a buffer is read back
    # out of it as the same one `Char`. `0xF8` leads nothing: those are four
    # keys, not one, and Julia reads those bytes back as four characters.
    io = IOBuffer(UInt8[0xF8, 0x80, 0x80, 0x80])
    @test [readevent(io).code for _ in 1:4] == [0xF8, 0x80, 0x80, 0x80]
    @test length(collect(String(UInt8[0xF8, 0x80, 0x80, 0x80]))) == 4
    # A sequence whose continuation never came is its lead byte alone, and the
    # byte that is not a continuation is left for the key it belongs to.
    io = IOBuffer(UInt8[0xE0, UInt8('A')])
    @test readevent(io).code == 0xE0
    @test readevent(io) == KeyEvent(Int('A'))

    # Typed into a buffer and taken back out, byte for byte - which is the whole
    # claim, since that is where a pasted sequence actually ends up.
    b = TextBuffer("abcd")
    b.col = 3
    insert!(b, keychar(raw(0xF4, 0x90, 0x80, 0x80)))
    @test collect(codeunits(text(b))) ==
          vcat(collect(codeunits("ab")), UInt8[0xF4,0x90,0x80,0x80], collect(codeunits("cd")))
    @test length(collect(text(b))) == 5       # one character, not four
    @test cols(text(b)) == 5                # and the layout survives it
end

@testset "a terminal's bytes, read as events" begin
    ev(s) = readevent(IOBuffer(s))
    @test ev("j") == KeyEvent(Int('j'))
    @test ev("\e") == KeyEvent(27)                   # bare escape
    @test ev("\e[A") == KeyEvent(K_UP)
    @test ev("\e[B") == KeyEvent(K_DOWN)
    @test ev("\eOA") == KeyEvent(K_UP)               # application cursor mode
    @test ev("\e[5~") == KeyEvent(K_PGUP)
    @test ev("\e[6~") == KeyEvent(K_PGDN)
    @test ev("\e[6;5~") == KeyEvent(K_PGDN)          # modified page-down
    @test ev("\e[Z") == KeyEvent(K_STAB)             # shift-tab
    # Alt/Meta has three spellings in the wild and all of them turn up.
    @test ev("\eb") == KeyEvent(K_WORD_LEFT)         # Terminal.app
    @test ev("\ef") == KeyEvent(K_WORD_RIGHT)
    @test ev("\e\x7f") == KeyEvent(K_WORD_BACK)      # alt-backspace, everywhere
    @test ev("\ed") == KeyEvent(K_WORD_KILL)         # alt-d, its mirror
    @test ev("\ee") == KeyEvent(K_EDIT)              # the REPL's own key for it
    @test ev("\e[1;3D") == KeyEvent(K_WORD_LEFT)     # CSI with a modifier
    @test ev("\e[1;5C") == KeyEvent(K_WORD_RIGHT)    # ctrl counts as by-word too
    @test ev("\e\e[D") == KeyEvent(K_WORD_LEFT)      # iTerm's Esc+
    @test ev("\e[1;2D") == KeyEvent(K_LEFT)          # shift is not by-word
    @test ev("\e[3~") == KeyEvent(K_DEL)
    @test ev("\e[299~") == KeyEvent(K_NONE)          # unknown, but consumed
    @test K_NONE < 0 && !printable(K_NONE)

    # A sequence must not leave its tail behind to arrive as keystrokes: this
    # is Shift-Tab, which `readkey` reads as Escape-then-`Z`.
    io = IOBuffer("\e[Zq")
    @test readevent(io) == KeyEvent(K_STAB)
    @test readevent(io) == KeyEvent(Int('q'))

    m = ev("\e[<0;40;12M")
    @test m isa MouseEvent && m.kind === :press && m.x == 40 && m.y == 12
    @test ev("\e[<0;40;12m").kind === :release
    @test ev("\e[<32;40;12M").kind === :drag         # button 0 + motion
    @test ev("\e[<64;5;5M").kind === :wheelup
    @test ev("\e[<65;5;5M").kind === :wheeldown
    @test ev("\e[<16;5;5M").mods == 4                # ctrl-click
    # xterm.js's report for a terminal it cannot place: consumed whole, and
    # not ended at the `N`, which left `aN;NaNm` to arrive as keys.
    io = IOBuffer("\e[<0;NaN;NaNmq")
    @test readevent(io) == KeyEvent(K_NONE)
    @test readevent(io) == KeyEvent(Int('q'))
    @test ev("\e[<0;40M") == KeyEvent(K_NONE)        # malformed
    # Shift is the one modifier the vertical arrows carry a key of their own
    # for, since it is what extends a selection. Alt and ctrl are not it.
    @test ev("\e[1;2A") == KeyEvent(K_SUP)
    @test ev("\e[1;2B") == KeyEvent(K_SDOWN)
    @test ev("\e[1;5A") == KeyEvent(K_UP)

    # A bracketed paste is one event and text, whatever keys it spells; the
    # key after it is a key again.
    io = IOBuffer("\e[200~q\tx\ry\e[201~j")
    @test readevent(io) == PasteEvent("q\tx\ry")
    @test readevent(io) == KeyEvent(Int('j'))
    # And a terminal that went away mid-paste gives what did arrive.
    @test ev("\e[200~half") == PasteEvent("half")
end

@testset "the terminal says dark or light, and what its background is" begin
    ev = readevent(IOBuffer("\e[?997;1n"))
    @test ev isa SchemeEvent && ev.dark && isempty(ev.rest) && ev.bg == ""
    ev = readevent(IOBuffer("\e[?997;2n"))
    @test ev isa SchemeEvent && !ev.dark
    @test readevent(IOBuffer("\e[?997;3n")) == KeyEvent(K_NONE)
    @test occursin(BG_QUERY, scheme_reports(true))
    @test scheme_reports(false) == "\e[?2031l"
    # The background colour by either terminator, and nothing of it left.
    for t in ("\a", "\e\\")
        io = IOBuffer(string("\e]11;rgb:1e1e/1e1e/1e1e", t, "j"))
        ev = readevent(io)
        @test ev isa SchemeEvent && ev.dark === nothing && ev.bg == "rgb:1e1e/1e1e/1e1e"
        @test readevent(io) == KeyEvent(Int('j'))
    end
    # Another OSC is consumed and nothing, and the key after it is a key.
    io = IOBuffer("\e]10;rgb:0/0/0\aj")
    @test readevent(io) == KeyEvent(K_NONE) && readevent(io) == KeyEvent(Int('j'))
    # An answer cut across two reads is still one answer, read to its end
    # whenever the rest arrives, and none of it is keys.
    r = Base.BufferStream()
    write(r, "\e]11;rgb:1e1e")
    t = @async readevent(r)
    sleep(0.1)
    @test !istaskdone(t)
    write(r, "/1e1e/1e1e\e\\j")
    ev = fetch(t)
    @test ev isa SchemeEvent && ev.bg == "rgb:1e1e/1e1e/1e1e"
    @test readevent(r) == KeyEvent(Int('j'))
    # The two patterns are what a host reading raw input takes a report out
    # of it with; what could not be passed on intact is not a colour.
    @test match(SCHEME_REPORT, "ab\e[?997;1ncd")[1] == "1"
    @test match(BG_REPORT, "\e]11;#000000\a")[1] == "#000000"
    @test match(BG_REPORT, "\e]11;a b\a") === nothing
end

@testset "word motion" begin
    @test wordstart("foo bar   ", 11) == 5      # over the spaces, then the word
    @test wordstart("foo bar", 8) == 5
    @test wordstart("foo", 1) == 1              # nothing behind the cursor
    @test wordend("foo bar", 1) == 4
    @test wordend("  foo bar", 1) == 6          # skip leading space first
    @test wordend("foo", 4) == 4
    # The two readline rules differ, and the difference is the point.
    @test wordstart("/usr/local/lib", 15) == 1                 # ^w: no space to stop at
    @test wordstart("/usr/local/lib", 15; alnum = true) == 12  # alt-bksp: just "lib"
    @test wordend("foo.bar", 1; alnum = true) == 4
end

@testset "the editing model, with no view attached" begin
    b = TextBuffer()
    @test b.lines == [""] && (b.row, b.col) == (1, 1) && isblank(b)

    for c in "hello"; insert!(b, c); end
    @test text(b) == "hello" && b.col == 6 && !isblank(b)
    newline!(b)
    for c in "world"; insert!(b, c); end
    @test text(b) == "hello\nworld" && (b.row, b.col) == (2, 6)

    move!(b, :up); move!(b, :home)
    @test (b.row, b.col) == (1, 1)
    move!(b, :end); @test b.col == 6
    move!(b, :down); @test (b.row, b.col) == (2, 6)   # down keeps the column
    # Horizontal movement crosses the line boundary in both directions.
    move!(b, :home); move!(b, :left)
    @test (b.row, b.col) == (1, 6)
    move!(b, :right); @test (b.row, b.col) == (2, 1)

    move!(b, :end); backspace!(b)
    @test text(b) == "hello\nworl"
    move!(b, :home); backspace!(b)                    # joins the lines
    @test text(b) == "helloworl" && (b.row, b.col) == (1, 6)
    killline!(b)
    @test text(b) == "hello"

    # Non-ASCII goes in as one character, not as its bytes.
    for c in "… é"; insert!(b, c); end
    @test text(b) == "hello… é" && b.col == length("hello… é") + 1
    # Including bytes that are not a character at all - a paste of anything at
    # all survives, because nothing was decoded on the way in.
    insert!(b, keychar(Int(0xF4908080)))
    @test collect(codeunits(text(b)))[end-3:end] == UInt8[0xF4, 0x90, 0x80, 0x80]
    backspace!(b)
    @test text(b) == "hello… é"

    # `^d` at the end of a line pulls the next one up: the inverse of `↵`.
    c = TextBuffer("one\ntwo")
    c.row, c.col = 1, 4
    deletechar!(c)
    @test text(c) == "onetwo" && (c.row, c.col) == (1, 4)
    # `^u` empties the line the cursor is on and leaves the rest alone.
    d = TextBuffer("keep\nthrow away")
    killtostart!(d)
    @test text(d) == "keep\n" && (d.row, d.col) == (2, 1)

    # The two word rules, through the operation that uses them.
    e = TextBuffer("alpha beta gamma")
    deleteword!(e)
    @test text(e) == "alpha beta "
    deleteword!(e; alnum = true)
    @test text(e) == "alpha "
    f = TextBuffer("/usr/local/lib")
    deleteword!(f; alnum = true)
    @test text(f) == "/usr/local/"
    deleteword!(f)                                    # ^w: the whole path at once
    @test text(f) == ""

    # At column 1 there is no word behind the cursor on this line, so it joins
    # upwards the way backspace does.
    g = TextBuffer("one\ntwo")
    move!(g, :home)
    deleteword!(g)
    @test text(g) == "onetwo" && (g.row, g.col) == (1, 4)

    # A cursor left past the end of a line that has since got shorter is put
    # back where a cursor can be, rather than throwing on the next keystroke.
    h = TextBuffer("abcdef")
    h.col = 99
    move!(h, :left)
    @test h.col == 6
end

@testset "what is killed can be put back" begin
    # One slot, not a ring, and a *run* of kills is one yank: `^k^k^k` then
    # `^y` gives back three lines rather than the last one.
    b = TextBuffer("one\ntwo\nthree")
    b.row, b.col = 1, 1
    killline!(b); killline!(b)          # the line, then the newline
    killline!(b); killline!(b)
    @test text(b) == "three"
    @test b.killed == "one\ntwo\n"
    move!(b, :end)
    yank!(b)
    @test text(b) == "threeone\ntwo\n"
    @test (b.row, b.col) == (3, 1)      # the cursor ends after what went in

    # Anything that is not a kill ends the run, so the next one starts fresh
    # rather than joining onto something typed a minute ago.
    c = TextBuffer("alpha beta")
    deleteword!(c)
    @test c.killed == "beta"
    insert!(c, 'x')
    deleteword!(c)
    @test c.killed == "x"

    # A backward kill goes on the *front*, so two of them yank back in the
    # order they were typed rather than reversed.
    d = TextBuffer("alpha beta gamma")
    deleteword!(d); deleteword!(d)
    @test d.killed == "beta gamma"
    settext!(d, "")
    yank!(d)
    @test text(d) == "beta gamma"

    # `^u` is readline's, not zsh's: from the cursor back to the start, which
    # only differs from the whole line when the cursor is not at the end - and
    # that is exactly when somebody meant one of them in particular.
    e = TextBuffer("keep this")
    e.col = 6
    killtostart!(e)
    @test text(e) == "this" && e.col == 1 && e.killed == "keep "
    @test text(killtostart!(TextBuffer("x"))) == ""

    # `⌥d` is the mirror of `⌥⌫`: the word in front of the cursor.
    f = TextBuffer("alpha beta")
    f.col = 1
    killwordforward!(f)
    @test text(f) == " beta" && f.killed == "alpha"
    # At the end of a line it takes the line break, the way `^k` does.
    g = TextBuffer("one\ntwo")
    g.row, g.col = 1, 4
    killwordforward!(g)
    @test text(g) == "onetwo" && g.killed == "\n"

    # Yanking nothing is not an insertion of nothing gone wrong.
    h = TextBuffer("x")
    yank!(h)
    @test text(h) == "x"

    # And what was killed survives being yanked, so it can go in twice.
    i = TextBuffer("word")
    deleteword!(i); yank!(i); yank!(i)
    @test text(i) == "wordword" && i.killed == "word"
end

@testset "^t drags a character over the one in front of it" begin
    b = TextBuffer("abc")
    b.col = 2
    transpose!(b)
    @test text(b) == "bac" && b.col == 3
    # At the end of the line it swaps the last two instead, which is the case
    # people actually hit: the typo is behind you by the time you notice it.
    c = TextBuffer("abc")
    transpose!(c)
    @test text(c) == "acb" && c.col == 4
    # Nothing to drag over, and nothing thrown.
    d = TextBuffer("abc"); d.col = 1
    @test text(transpose!(d)) == "abc"
    @test text(transpose!(TextBuffer("a"))) == "a"
    @test text(transpose!(TextBuffer())) == ""
    # Characters, not bytes.
    e = TextBuffer("aé")
    transpose!(e)
    @test text(e) == "éa"
end

@testset "a block goes in whole, or splits the line" begin
    # An empty buffer takes it whole, with a line under it: text dropped into
    # nothing is what you are about to write *under*, not into.
    b = TextBuffer()
    insertblock!(b, "```suggestion\nx = 1\n```")
    @test b.lines == ["```suggestion", "x = 1", "```", ""]
    @test (b.row, b.col) == (4, 1)

    # Otherwise at the cursor, splitting the line it is on - which is what puts
    # a second block under the first rather than inside it.
    c = TextBuffer("head tail")
    c.col = 6
    insertblock!(c, "one\ntwo")
    @test c.lines == ["head ", "one", "two", "tail"]
    @test (c.row, c.col) == (4, 1)

    # `\r\n` never reaches the buffer, however it arrives: a line ending in a
    # carriage return draws as a character of rubbish on the end of every row.
    d = TextBuffer("from\r\na form\r\n")
    @test d.lines == ["from", "a form", ""]
    insertblock!(TextBuffer("x"), "a\r\nb")
end

@testset "a paste is text, and the cursor ends after it" begin
    b = TextBuffer("head tail")
    b.col = 6
    paste!(b, "one\rtwo\r\nthree")
    @test b.lines == ["head one", "two", "threetail"]
    @test (b.row, b.col) == (3, 6)
    # A tab is kept; an escape, which would be a command to the terminal the
    # buffer is drawn on, is not.
    c = paste!(TextBuffer(), "a\tb\e[31mc\x7f")
    @test c.lines == ["a\tb[31mc"]
    # One line in a one-line field: breaks become spaces, and the one a copied
    # line ends on goes.
    li = LineInput("t")
    TermInput.paste!(li, "https://x/y\n")
    @test text(li) == "https://x/y"
    TermInput.paste!(li, " a\r\nb")
    @test text(li) == "https://x/y a b"
    # And only characters: a tab, which a text area keeps, is a jump the one
    # row does not draw, and an escape is a command to the terminal.
    li = LineInput("t")
    TermInput.paste!(li, "a\tb\e[31mc\x7f\n")
    @test text(li) == "ab[31mc"
    # A picker's query is one.
    c = Choice("t", "", ["ab", "cd"])
    TermInput.paste!(c, "a\tb\n")
    @test query(c) == "ab" && matches(c) == [1]
    ta = TextArea("t"; initial = "x")
    TermInput.paste!(ta, "\ny")
    @test text(ta) == "x\ny"
end

@testset "the cursor maps onto the rows that are drawn" begin
    b = TextBuffer("0123456789abcdefghij")
    rows, crow, ccol = bufferrows(b, 10)
    # A line whose width is an exact multiple of the wrap needs one more row for
    # the cursor to stand on, the way any editor gives you one.
    @test rows == ["0123456789", "abcdefghij", ""]
    @test (crow, ccol) == (3, 1)
    b.col = 12
    _, crow, ccol = bufferrows(b, 10)
    @test (crow, ccol) == (2, 2)

    # Several lines, and the row index counts from the top of the buffer.
    c = TextBuffer("ab\ncdefgh\nij")
    c.row, c.col = 2, 5
    rows, crow, ccol = bufferrows(c, 3)
    @test rows == ["ab", "cde", "fgh", "ij"]
    @test (crow, ccol) == (3, 2)

    # A width nothing can be drawn in is a width, not a division by zero.
    @test bufferrows(TextBuffer("x"), 0) isa Tuple

    # Wide characters are counted in columns, and never split down the middle.
    @test chunks("日本語です", 4) == ["日本", "語で", "す"]
    d = TextBuffer("日本語です")
    d.col = 3
    _, crow, ccol = bufferrows(d, 4)
    @test (crow, ccol) == (2, 1)
    # ...and a row a wide character did not fit on ends short, so the cursor is
    # found by the rows as they were cut, not by dividing by the width.
    e = TextBuffer("ab中")
    @test bufferrows(e, 3) == (["ab", "中"], 2, 3)
    e.col = 3
    @test bufferrows(e, 3) == (["ab", "中"], 2, 1)
    @test bufferrows(TextBuffer("a中"), 3) == (["a中", ""], 2, 1)

    # A control character is drawn as one column that says what it was, and
    # the text keeps it.
    f = TextBuffer("a\tb\e[31mc\r")
    @test first(bufferrows(f, 20)) == ["a b␛[31mc␍"]
    @test text(f) == "a\tb\e[31mc\r"
end

@testset "the cursor is drawn where the terminal would put it" begin
    # A byte index into a line with an accent in it throws; a character index
    # into one with a CJK character in it draws the block a column to the left
    # of where the terminal will put it. `ccol` is a display column, and the
    # block lands on the character occupying it.
    @test ansi(drawcursor("abc", 2)) == ansi(rowcat("a", faced("b", REV), "c"))
    @test String(drawcursor("héllo", 3)) == "héllo"
    @test String(drawcursor("日本語", 3)) == "日本語"
    # StyledStrings 1.0.3, the package on 1.10, cannot write a face after a
    # character of more than one byte: it cuts the text before it mid-character.
    @test ansi(drawcursor("日本語", 3)) == ansi(rowcat("日", faced("本", REV), "語")) broken = VERSION < v"1.11"
    # Past the end of the line there is a blank to stand on, so the cursor is
    # still somewhere: reverse video over nothing paints nothing at all.
    @test ansi(drawcursor("ab", 3)) == ansi(rowcat("ab", faced(" ", REV)))
    @test String(drawcursor("", 1)) == " "
    # Drawing the cursor adds no columns to a line it is inside of.
    for (s, c) in (("abc", 2), ("héllo", 4), ("日本語", 1), ("", 1))
        @test rowwidth(drawcursor(s, c)) == max(textwidth(s), c)
    end
    # A line with faces keeps them on either side of the block.
    @test ansi(drawcursor(faced("abc", Face(weight = :bold)), 2)) ==
          ansi(rowcat(faced("a", Face(weight = :bold)),
                      faced(faced("b", REV), Face(weight = :bold)),
                      faced("c", Face(weight = :bold))))
    @test displaycolumn("日本語", 3) == 5      # two wide characters behind it
    @test displaycolumn("abc", 1) == 1
end

@testset "the text area, driven by key codes" begin
    v = TextArea("comment", "on managers.jl:544")
    type!(s) = for c in s; handle!(v, keycode(c)); end

    type!("hello")
    @test text(v) == "hello"
    @test handle!(v, 13) === :ok                 # enter splits at the cursor
    type!("world")
    @test text(v) == "hello\nworld"

    # Finishing is not the widget's. `^s`, escape and `^g` are edits of
    # nothing, so they come back, and what they mean is decided over the top -
    # here, by a test standing in for a host.
    @test handle!(v, C_S) === :unhandled
    @test handle!(v, 27) === :unhandled
    @test handle!(v, C_G) === :unhandled
    # ...and this is what a host does with them. `submission` is the text with
    # the whitespace round it taken off, which is a convenience and not a rule.
    handle!(v, 13)
    @test submission(v) == "hello\nworld" && text(v) == "hello\nworld\n"

    # Whether an empty one may be sent is the same question from the other
    # side, and the same answer: `isblank` is what a host asks, and the widget
    # neither refuses nor allows.
    @test !isblank(v)
    @test isblank(TextArea("t"))
    @test isblank(TextArea("t"; initial = "  \n  "))

    # A key the widget does not use is handed straight back rather than
    # swallowed: that is how a program keeps its own keys working inside
    # somebody else's composer.
    e = TextArea("t")
    @test handle!(e, C_R) === :unhandled
    @test handle!(e, K_STAB) === :unhandled
    @test handle!(e, K_PGUP) === :unhandled
    @test handle!(e, keycode('y')) === :ok       # but a character is not
    # The status is a host's line, and the next keystroke clears it so that it
    # never outlives what it was about.
    e.status = "something a host said"
    handle!(e, keycode('x'))
    @test isempty(e.status)

    # The readline keys, and the two word rules through them.
    r = TextArea("t")
    for c in "alpha beta gamma"; handle!(r, keycode(c)); end
    handle!(r, C_W);           @test text(r) == "alpha beta "
    handle!(r, K_WORD_BACK);   @test text(r) == "alpha "
    handle!(r, C_A);           @test r.buf.col == 1
    handle!(r, C_E);           @test r.buf.col == 7
    handle!(r, K_WORD_LEFT);   @test r.buf.col == 1
    handle!(r, K_WORD_RIGHT);  @test r.buf.col == 6
    handle!(r, C_A); handle!(r, C_D)
    @test text(r) == "lpha "
    # Shift-arrows are the arrows here: there is no selection to extend.
    handle!(r, K_SDOWN)
    @test r.buf.row == 1

    # The emacs motion keys are the arrows under another name, which is what
    # readline binds them to and what a hand that never leaves the home row
    # reaches for.
    m = TextArea("t"; initial = "one\ntwo")
    m.buf.row, m.buf.col = 1, 1
    handle!(m, C_F); @test m.buf.col == 2
    handle!(m, C_B); @test m.buf.col == 1
    handle!(m, C_N); @test m.buf.row == 2
    handle!(m, C_P); @test m.buf.row == 1

    # A kill and a yank, through the keys.
    y = TextArea("t"; initial = "alpha beta")
    handle!(y, C_W)
    @test text(y) == "alpha "
    handle!(y, C_Y)
    @test text(y) == "alpha beta"
    handle!(y, C_T)
    @test text(y) == "alpha beat"                # the last two, swapped
end

@testset "the text area draws a frame of exactly the size asked for" begin
    v = TextArea("a title", "a note that is long enough to want wrapping at some widths")
    for c in "some text\nand a second line"; handle!(v, keycode(c)); end
    for (w, h) in ((80, 24), (120, 40), (60, 12), (40, 9), (200, 60))
        ls = split(screen(render(v, w, h)), "\n")
        @test length(ls) == h
        @test all(cols(l) == w for l in ls)
    end
    # The box stops widening long before the screen does, because a line of
    # prose 200 columns wide is not one anybody can read.
    wide = split(screen(render(v, 200, 24)), "\n")
    @test maximum(cols(unescaped(strip(l))) for l in wide) <= v.maxwidth

    # A buffer taller than the box scrolls to keep the cursor on screen, and
    # the frame stays exactly as tall.
    tall = TextArea("t"; initial = join(string.("line ", 1:200), "\n"))
    ls = split(screen(render(tall, 80, 24)), "\n")
    @test length(ls) == 24 && all(cols(l) == 80 for l in ls)
    @test any(l -> occursin("line 200", l), ls)      # the cursor's line is shown
    @test !any(l -> occursin("line 1 ", l), ls)
    tall.buf.row = 1
    ls = split(screen(render(tall, 80, 24)), "\n")
    @test any(l -> occursin("line 1", l), ls)

    # A note of several lines is several rows, and a tab or an escape in the
    # buffer is one column rather than a jump or a command.
    for v in (TextArea("T", "line1\nline2"), TextArea("T"; initial = "a\tb\e[31mc\r\td"))
        ls = split(screen(render(v, 40, 20)), "\n")
        @test length(ls) == 20 && all(cols(l) == 40 for l in ls)
    end

    # Whatever is in the buffer, including what a terminal sent and no
    # codepoint covers, comes back as columns rather than as an exception.
    odd = TextArea("t")
    for c in "日本語 é "; handle!(odd, keycode(c)); end
    insert!(odd.buf, keychar(Int(0xF4908080)))
    ls = split(screen(render(odd, 80, 24)), "\n")
    @test all(cols(l) == 80 for l in ls)
end

@testset "the line input" begin
    p = LineInput("where to", "a path, or nothing to stay here")
    for c in "/usr/local/lib"; handle!(p, keycode(c)); end
    @test text(p) == "/usr/local/lib"
    handle!(p, K_WORD_BACK)                      # alt-backspace: one component
    @test text(p) == "/usr/local/"
    handle!(p, C_A); @test p.buf.col == 1
    handle!(p, keycode('X'))
    @test text(p) == "X/usr/local/" && p.buf.col == 2
    handle!(p, C_E); handle!(p, 127)
    @test text(p) == "X/usr/local"
    handle!(p, C_W)                              # ^w: the whole path at once
    @test text(p) == ""

    # `↵` has no line to split here, so it comes back like every other key the
    # widget has no edit for - and what it means, including whether an empty
    # answer is one, is the host's.
    @test handle!(p, 13) === :unhandled && handle!(p, 10) === :unhandled
    for c in "  spaced  "; handle!(p, keycode(c)); end
    @test submission(p) == "spaced"
    @test handle!(p, 27) === :unhandled
    # There is no second line to reach, so the keys that would make one are the
    # host's - and `^p`/`^n`, which readline gives to the history, go back for a
    # host that has one.
    @test handle!(p, K_UP) === :unhandled
    @test handle!(p, K_PGDN) === :unhandled
    @test handle!(p, C_P) === :unhandled && handle!(p, C_N) === :unhandled
    @test handle!(p, C_S) === :unhandled
    # The rest of the editing is the text area's, including the kill buffer.
    p = LineInput("t")
    for c in "alpha beta"; handle!(p, keycode(c)); end
    handle!(p, C_W); handle!(p, C_Y)
    @test text(p) == "alpha beta"
    handle!(p, C_A); handle!(p, K_WORD_KILL)
    @test text(p) == " beta"
    @test handle!(p, C_G) === :unhandled

    # A newline in a one-row field is not a character to draw: the frame is
    # clamped by element, so one element holding a newline prints as two rows,
    # the screen scrolls, and every mouse report after it names a row that has
    # moved.
    @test text(LineInput("t"; initial = "two\nlines\r\nhere")) == "two lines here"

    for (w, h) in ((90, 24), (80, 10), (40, 8), (160, 50))
        ls = split(screen(render(p, w, h)), "\n")
        @test length(ls) == h && all(cols(l) == w for l in ls)
    end

    # A line longer than the box scrolls sideways to keep the cursor on it, and
    # a `…` says what went off the front. The cursor is the terminal's, so the
    # line it is on is the one `caret` names, and nothing is drawn there.
    long = LineInput("t"; initial = join('a':'z') * join('0':'9') * join('A':'J'))
    cursorline(v, w) = split(screen(render(v, w, 10)), "\n")[caret(v, w, 10)[1]]
    l = unescaped(cursorline(long, 30))
    @test cols(cursorline(long, 30)) == 30 && occursin("> …", l) && occursin("J  ", l)
    @test !occursin("\e[7m", screen(render(long, 30, 10)))
    @test cellat(long, 30, 10) == " "                     # after the `J`
    long.buf.col = 1
    @test occursin("> abc", unescaped(cursorline(long, 30))) && cellat(long, 30, 10) == "a"
    long.buf.col = 30
    l = unescaped(cursorline(long, 30))
    @test cellat(long, 30, 10) == "3" && occursin("3…", l) && occursin("> …", l)
    # A field a host draws: the row and the column its cursor is at, or the
    # row with a block there, for one that does not have the cursor.
    @test field("abc", 4, 10) == (TermInput.row("abc"), 4)
    @test field("日本語", 2, 10) == (TermInput.row("日本語"), 3)
    @test drawfield("abc", 4, 10) == drawcursor("abc", 4)
    @test String(first(field("abcdefghij", 11, 10))) == "…defghij" &&
          last(field("abcdefghij", 11, 10)) == 9
    @test String(drawfield("abcdefghij", 11, 10)) == "…defghij "
end

@testset "a choice, narrowed by typing" begin
    import TermInput: click!, query, query!, selected, matches, doubled
    c = Choice("Labels", "↵ toggles one", ["bug", "docs", "performance", "build\n  under it"])
    @test selected(c) == 1
    @test handle!(c, K_DOWN) === :ok && selected(c) == 2
    @test handle!(c, C_N) === :ok && handle!(c, C_P) === :ok && selected(c) == 2
    # Typing narrows, by the lines under an option too, and goes back to the
    # top of what is left; the query edits the way a line input does.
    for ch in "u"; handle!(c, keycode(ch)); end
    @test query(c) == "u" && matches(c) == [1, 4] && selected(c) == 1
    for ch in "nder"; handle!(c, keycode(ch)); end
    @test matches(c) == [4]
    handle!(c, C_W)
    @test query(c) == "" && length(matches(c)) == 4
    query!(c, "zzz")
    @test isempty(matches(c)) && selected(c) == 0 && picked(c, 13) == 0
    query!(c, "")
    # What picking means is the host's: `↵` and escape come back, and `picked`
    # says which option the key would pick.
    c.sel = 3
    @test handle!(c, 13) === :unhandled && picked(c, 13) == 3
    @test handle!(c, 27) === :unhandled && picked(c, 27) == 0
    # An unnumbered list takes a digit as a query; a numbered one hands it back,
    # and it picks that row, or nothing where there is none.
    handle!(c, keycode('5')); @test query(c) == "5"
    n = Choice("t", "", ["one", "two"]; numbered = true)
    @test handle!(n, keycode('2')) === :unhandled && picked(n, keycode('2')) == 2
    @test picked(n, keycode('5')) == 0 && query(n) == ""
    # A ranged list lights a run under shift and answers it as `chosen`; a
    # plain move lets it go, and an unranged list takes shift as the arrow.
    import TermInput: chosen
    r = Choice("t", "", ["a", "b", "c", "d"]; ranged = true)
    @test chosen(r) == [1]
    handle!(r, K_DOWN); handle!(r, K_SDOWN); handle!(r, K_SDOWN)
    @test chosen(r) == [2, 3, 4] && selected(r) == 4
    handle!(r, K_SUP); handle!(r, K_SUP); handle!(r, K_SUP)
    @test chosen(r) == [1, 2]
    @test handle!(r, 13) === :unhandled && chosen(r) == [1, 2]     # ↵ keeps it
    handle!(r, K_DOWN)
    @test chosen(r) == [2]
    handle!(n, K_SDOWN)
    @test chosen(n) == [2]
    # The default hint names only the keys the widget owns: picking and
    # escape come back, so saying what they do is the host's.
    @test occursin(CHOICE_HINT, screen(render(n, 80, 24)))
    @test !occursin("esc", CHOICE_HINT) && !occursin("↵", CHOICE_HINT)
    # A status is shown instead of the hint, and the next key clears it.
    n.status = "no labels to add"
    @test occursin("no labels to add", screen(render(n, 80, 24)))
    handle!(n, K_DOWN)
    @test isempty(n.status) && occursin(CHOICE_HINT, screen(render(n, 80, 24)))
    # A paste is one line of query.
    query!(c, ""); TermInput.paste!(c, "doc\n")
    @test query(c) == "doc" && matches(c) == [2]

    # The query scrolls sideways, as a line input does.
    query!(c, "x"^100)
    @test occursin("/ …xxx", unescaped(screen(render(c, 60, 20))))
    query!(c, "")

    # The frame, and where it put the rows, for the mouse.
    many = ["opt $i" * (iseven(i) ? "\n  under $i" : "") for i in 1:12]
    m = Choice("t", "", many; numbered = true)
    for (w, h) in ((90, 24), (80, 12), (160, 50))
        ls = split(screen(render(m, w, h)), "\n")
        @test length(ls) == h && all(cols(l) == w for l in ls)
    end
    ls = split(unescaped(screen(render(m, 80, 50))), "\n")
    @test m.omap[1:4] == [1, 2, 2, 3]
    r3 = findfirst(l -> occursin("3  opt 3", l), ls)
    @test r3 == first(m.orows) + 3
    @test click!(m, :press, 10, r3, 1.0) === :ok && selected(m) == 3
    @test click!(m, :press, 11, r3, 1.2) === :pick           # a double click
    @test click!(m, :press, 10, r3, 5.0; window = 0.1) === :ok
    @test click!(m, :press, 10, r3, 5.2; window = 0.1) === :ok   # too slow for that
    @test click!(m, :wheeldown, 10, r3, 6.0) === :ok && selected(m) == 6
    @test click!(m, :press, 10, first(m.boxrows) - 1, 7.0) === :unhandled
    @test doubled((1.0, 5, 5), 6, 5, 1.4, 0.5) && !doubled((1.0, 5, 5), 7, 5, 1.4, 0.5)

    # A note of two lines is two rows, and the options - and the mouse - move
    # down one for it.
    t = Choice("t", "line one\nline two", ["a", "b"])
    ls = split(unescaped(screen(render(t, 40, 12))), "\n")
    @test length(ls) == 12 && all(cols(l) == 40 for l in ls)
    @test ls[first(t.orows) + 1] |> l -> occursin(" b ", l)
    @test click!(t, :press, 10, first(t.orows) + 1, 1.0) === :ok && selected(t) == 2

    # A malformed byte in the query - or a label - is matched as itself, not an
    # error that leaves the picker unable to draw.
    bad = Choice("t", "", ["a\x80b", "abc"])
    @test handle!(bad, 0x80 + 0) === :ok && query(bad) == "\x80"
    @test matches(bad) == [1] && selected(bad) == 1 && picked(bad, 13) == 1
    @test length(split(screen(render(bad, 40, 12)), "\n")) == 12
    query!(bad, "A")
    @test matches(bad) == [1, 2]

    # The rows of a list in a box: the cursor's row whole, and the box full.
    @test listwindow([1, 3, 2, 1, 1], 2, 1, 3) == (2, 2, 2:2)
    @test listwindow([1, 3, 2, 1, 1], 3, 1, 3) == (3, 3, 3:4)
    @test listwindow([1, 1, 1], 1, 1, 10) == (1, 1, 1:3)
    # Rows of a line each are the same window, counted rather than summed.
    for n in 0:6, sel in -1:8, top in -1:8, inner in 1:7
        @test listwindow(n, sel, top, inner) == listwindow(ones(Int, n), sel, top, inner)
    end
    @test listwindow(10, 7, 9, 3) == (7, 7, 7:9)
    @test listwindow(10, 2, 2, 0)[3] == 2:1             # a box with no room
    # A page with no cursor passes its top as one, and is kept full.
    @test listwindow(10, 9, 9, 4)[2] == 7

    # Where the pager's keys and the wheel put the cursor, clamped; a key that
    # is not one of them is the host's.
    @test listmove(keycode('j'), 3, 5, 2) == 4 && listmove(K_DOWN, 5, 5, 2) == 5
    @test listmove(keycode('k'), 1, 5, 2) == 1 && listmove(keycode('k'), 1, 5, 2; lo = 0) == 0
    @test listmove(keycode(' '), 1, 5, 2) == 3 && listmove(C_F, 4, 5, 2) == 5
    @test listmove(keycode('b'), 4, 5, 2) == 2 && listmove(K_PGUP, 2, 5, 2) == 1
    @test listmove(keycode('g'), 4, 5, 2; lo = 0) == 0 && listmove(K_END, 1, 5, 2) == 5
    @test listmove(keycode('G'), 1, 0, 2) == 1          # an empty list stays at its first
    @test listmove(keycode('x'), 3, 5, 2) === nothing
    @test listmove(:wheeldown, 1, 10) == 1 + TermInput.WHEEL_ROWS
    @test listmove(:wheelup, 2, 10) == 1 && listmove(:press, 2, 10) === nothing
end

@testset "a question only named keys answer" begin
    # What a host calls to read a pick or an answer is exported with the widget.
    @test :picked in names(TermInput) && :answer in names(TermInput)
    q = Confirm("Discard?", ["", "it is nowhere else"])
    @test q.note == "it is nowhere else"
    @test occursin(CONFIRM_HINT, screen(render(q, 60, 10)))
    # Every widget takes its note the same way: a string, or rows with the
    # empty ones left out.
    @test Confirm("t", "a\nb").note == Confirm("t", ["a", "", "b"]).note == "a\nb"
    @test TextArea("t", ["a", "", "b"]).note == LineInput("t", ["a", "b"]).note ==
          Choice("t", ["a", "b"], ["x"]).note == "a\nb"
    # The hint is a field a host may set afterwards, on every widget.
    q.hint = "y discards it"
    @test occursin("y discards it", screen(render(q, 60, 10)))
    @test answer(q, keycode('y')) == 1 && answer(q, keycode('Y')) == 1
    @test answer(q, 13) == 0 && answer(q, 27) == 0 && answer(q, keycode('n')) == 0
    q2 = Confirm("Quit", "a draft", ["yY", "\e"]; hint = "y quits · esc goes back")
    @test answer(q2, 27) == 2 && answer(q2, K_UP) == 0
    ls = split(screen(render(q2, 60, 10)), "\n")
    @test length(ls) == 10 && all(cols(l) == 60 for l in ls)
    @test any(l -> occursin("esc goes back", l), ls)
    q3 = Confirm("Quit", "a draft\nand a stash")
    ls = split(unescaped(screen(render(q3, 60, 10))), "\n")
    @test length(ls) == 10 && count(l -> occursin("a draft", l) || occursin("and a stash", l), ls) == 2
end

@testset "the two widgets differ in exactly four places" begin
    # The README carries the whole readline table, and a table is only worth
    # having if it cannot drift. Every key both widgets bind is written down
    # once there; this is the list of the ones where they part, so a binding
    # added to one and not the other fails here rather than in the table.
    every = [C_B, C_F, C_P, C_N, C_A, C_E, K_WORD_LEFT, K_WORD_RIGHT, K_LEFT,
             K_RIGHT, K_UP, K_DOWN, K_HOME, K_END, C_D, K_DEL, 127, C_T, C_K,
             C_U, C_W, K_WORD_BACK, K_WORD_KILL, C_Y, C_G, 27, 13, 10, C_S, C_R,
             K_EDIT, C_O, 12, 17, 22, 0, 9, K_STAB, K_PGUP, K_PGDN]
    act(mk, k) = handle!(mk(), k)
    ta() = TextArea("t"; initial = "ab cd")
    li() = LineInput("t"; initial = "ab cd")
    differ = [k for k in every if act(ta, k) !== act(li, k)]

    # A second line to reach, a line to split, and an editor worth opening.
    # Nothing else.
    @test Set(differ) == Set([C_P, C_N, K_UP, K_DOWN, 13, 10, K_EDIT, C_O])
    @test act(ta, 13) === :ok && act(li, 13) === :unhandled
    @test act(ta, K_EDIT) === :ok && act(li, K_EDIT) === :unhandled
    @test act(ta, K_UP) === :ok && act(li, K_UP) === :unhandled

    # And the keys neither of them claims, which are a host's to bind. The
    # first four are how a program finishes, gives up, or does something of its
    # own - none of which a text box can answer for the program around it.
    for k in (C_S, 27, C_G, C_R, 12, 17, 22, 0, 9, K_STAB, K_PGUP, K_PGDN)
        @test act(ta, k) === :unhandled && act(li, k) === :unhandled
    end
    # Nothing returns anything but these two any more: a widget that answered
    # "submitted" or "cancelled" would be answering for its host.
    @test Set(vcat([act(ta, k) for k in every], [act(li, k) for k in every])) ⊆
          Set(ACTIONS) == Set([:ok, :unhandled])
end

@testset "the box comes from CHROME" begin
    # The glyphs are a table here, and the one drawn is `CHROME[].box` - and a
    # name that is not there is a different corner, not an exception.
    b = dialogbox(80)
    @test occursin(string(boxstyle().top.left), String(b.head("title")))
    @test occursin("title", String(b.head("title")))
    @test rowwidth(b.row("x")) == b.pad + b.bw
    @test rowwidth(b.foot()) == b.pad + b.bw
    @test rowwidth(b.head("a title")) == b.pad + b.bw
    @test rowwidth(b.top()) == b.pad + b.bw
    # A title too long for the edge is elided rather than pushing the corner
    # off the end of it.
    @test rowwidth(b.head("t"^300)) == b.pad + b.bw
    # The title is strong and the edge quiet, each in its own face.
    @test occursin("\e[1mtitle", ansi(b.head("title")))
    @test startswith(ansi(b.row("x")), string(" "^b.pad, ansi(faced(string(boxstyle().mid.left), CHROME[].quiet))))
    # The rows a widget draws are painted in the weights its border was, so a
    # box given weights of its own is one box and not two.
    plain = (strong = Face(), quiet = Face(), focus = Face(), box = BOXES.ROUNDED)
    @test dialogbox(80; chrome = plain).chrome === plain
    old = CHROME[]
    try
        CHROME[] = plain
        @test !occursin('\e', screen(render(Confirm("t", "a note"), 60, 10)))
        # And a field, whose cursor is the terminal's; a block, where one is
        # drawn, is reverse video whatever the chrome says.
        @test !occursin('\e', screen(render(LineInput("t", "a note"), 60, 10)))
        @test occursin(ansi(faced(" ", REV)),
                       screen(render(TextArea("t"; focused = false), 60, 16)))
    finally
        CHROME[] = old
    end

    old = CHROME[]
    try
        CHROME[] = merge(old, (box = BOXES.SQUARE,))
        @test occursin("┌", String(dialogbox(80).head("t")))
        @test occursin("└", String(dialogbox(80).foot()))
        @test occursin("╔", String(dialogbox(80; box = boxstyle(:DOUBLE)).top()))
    finally
        CHROME[] = old
    end
    @test boxstyle(:NOT_A_BOX) === BOXES.ROUNDED
    @test boxstyle("heavy") === BOXES.HEAVY
    # Every box has all six lines, four characters each, one column apiece.
    for b in BOXES, f in (:top, :head, :head_row, :mid, :row, :bottom)
        l = getfield(b, f)
        @test all(c -> textwidth(c) == 1, (l.left, l.mid, l.vertical, l.right))
    end

    # Every frame is `h` rows of exactly `w` columns, whatever went into it.
    @test length(centred(["a"], 20, 5)) == 5
    @test all(rowwidth(l) == 20 for l in centred(["a", "b"], 20, 5))
    # More rows than there is room for is a frame of the size asked for, still.
    @test length(centred([string(i) for i in 1:50], 20, 5)) == 5
end

@testset "handing the terminal over and taking it back" begin
    # `suspend` puts the screen back the way it found it, in order, and with no
    # terminal to hand over it still writes what a child needs to see.
    ran = Ref(false)
    out = mktemp() do path, io
        redirect_stdout(() -> suspend(() -> ran[] = true, nothing), io)
        flush(io)
        read(path, String)
    end
    @test ran[]
    @test occursin("\e[?1049l", out) && occursin("\e[?1049h", out)
    @test findfirst("\e[?1049l", out) < findfirst("\e[?1049h", out)
    @test occursin("\e[?25h", out)                    # the cursor comes back

    # The mouse is the host's to say it owns, and both sequences are here so
    # that a host does not keep a second copy of them in step with this one.
    m = mktemp() do path, io
        redirect_stdout(() -> suspend(() -> nothing, nothing; mouse = true), io)
        flush(io)
        read(path, String)
    end
    @test occursin(mouse_reporting(false), m) && occursin(mouse_reporting(true), m)
    @test !occursin(mouse_reporting(false), out)
    # Bracketed paste the same way: a shell that never asked for the markers
    # would read them as keys.
    p = mktemp() do path, io
        redirect_stdout(() -> suspend(() -> nothing, nothing; paste = true), io)
        flush(io)
        read(path, String)
    end
    @test findfirst(bracketed_paste(false), p) < findfirst(bracketed_paste(true), p)
    @test !occursin(bracketed_paste(false), out)

    # And it puts the screen back even when the body throws, which is the case
    # that matters: a terminal left in raw mode with no alternate screen is a
    # terminal somebody has to `reset`.
    thrown = mktemp() do path, io
        redirect_stdout(io) do
            try
                suspend(() -> error("boom"), nothing)
            catch
            end
        end
        flush(io)
        read(path, String)
    end
    @test occursin("\e[?1049h", thrown)

end

@testset "a terminal entered is left as it was found" begin
    # Anything but a tty is taken as it is, so the sequences can be read back.
    out = IOBuffer()
    t = enter_terminal(IOBuffer(), out; altscreen = true, title = true,
                       mouse = true, paste = true)
    @test t isa HeldTerminal && t.tty === nothing
    s = String(take!(out))
    @test startswith(s, "\e[?1049h\e[?25l\e[22;2t")
    @test endswith(s, string(mouse_reporting(true), bracketed_paste(true)))
    leave_terminal(t)
    s = String(take!(out))
    # The reverse, and everything that was put on is taken off.
    @test startswith(s, mouse_reporting(false))
    @test endswith(s, string(bracketed_paste(false), "\e[?25h\e[?1049l\e[23;2t"))

    # Only what was asked for: an inline host keeps its screen and its title.
    t = enter_terminal(IOBuffer(), out)
    @test String(take!(out)) == "\e[?25l"
    leave_terminal(t)
    @test String(take!(out)) == "\e[?25h"

    # A mouse turned off during the run is not turned off again on the way out.
    t = enter_terminal(IOBuffer(), out; mouse = true)
    write(t, mouse_reporting(false)); t.mouse = false
    take!(out)
    leave_terminal(t)
    @test !occursin(mouse_reporting(false), String(take!(out)))

    # A terminal that has gone away is left without a word: the commonest way
    # out of a loop is that one, and an exception from its `finally` would
    # replace whatever brought it there.
    gone = IOBuffer()
    t = enter_terminal(IOBuffer(), gone; altscreen = true, mouse = true, paste = true)
    close(gone)
    @test leave_terminal(t) === nothing

    # One nothing was done to has nothing to undo but the cursor.
    t = HeldTerminal(IOBuffer(), out)
    @test !t.altscreen && !t.mouse && !t.paste && t.tty === nothing
    leave_terminal(t)
    @test String(take!(out)) == "\e[?25h"

    # The size and the writes are the output's, the events the input's.
    t = enter_terminal(IOBuffer("\e[Zq"), out)
    @test displaysize(t) == displaysize(out)
    write(t, "x")
    @test endswith(String(take!(out)), "x")
    @test readevent(t) == KeyEvent(K_STAB) && readevent(t) == KeyEvent(Int('q'))

    # `suspend` undoes and redoes what was done and no more: no alternate
    # screen that was never entered, and the mouse as it is now.
    t = enter_terminal(IOBuffer(), out; paste = true)
    take!(out)
    ran = Ref(false)
    suspend(() -> ran[] = true, t)
    s = String(take!(out))
    @test ran[]
    @test s == string(bracketed_paste(false), "\e[?25h", "\e[?25l", bracketed_paste(true))
    t = enter_terminal(IOBuffer(), out; altscreen = true, mouse = true)
    take!(out)
    try
        suspend(() -> error("boom"), t)
    catch
    end
    s = String(take!(out))
    @test findfirst("\e[?1049l", s) < findfirst("\e[?1049h", s)
    @test endswith(s, mouse_reporting(true))          # put back, thrown or not
end

@testset "the reader reads one event when it is armed, and none between" begin
    p = Pipe()
    Base.link_pipe!(p; reader_supports_async = true, writer_supports_async = true)
    events = Channel{Any}(8)
    r = InputReader(p.out, events)
    # Not armed, it reads nothing: what arrives now is for whoever reads next,
    # which is what lets `suspend` hand the terminal to a child.
    write(p.in, "x")
    @test read(p.out, UInt8) == UInt8('x')
    @test !isready(events)
    # Armed, one event, and then parked again.
    write(p.in, "\e[Zq")
    arm!(r)
    @test take!(events) == KeyEvent(K_STAB)
    sleep(0.05)
    @test !isready(events)
    arm!(r)
    @test take!(events) == KeyEvent(Int('q'))
    # The channel is the host's, and its own wakes go on it beside the keys.
    put!(events, :wake)
    @test take!(events) === :wake
    # The terminal gone is an event, not a loop left waiting for ever.
    close(p.in)
    arm!(r)
    ev = take!(events)
    @test ev isa EndEvent && ev.why isa EOFError
    wait(r.task)
    @test istaskdone(r.task) && !isready(events)

    # A read of the host's own, told at each arming which way to read: here
    # undecoded for one event and decoded for the next, in that order.
    p = Pipe()
    Base.link_pipe!(p; reader_supports_async = true, writer_supports_async = true)
    r = InputReader(p.out, events, Bool) do io, raw
        raw ? readavailable(io) : readevent(io)
    end
    write(p.in, "\e[A")
    arm!(r, true)
    @test take!(events) == Vector{UInt8}("\e[A")
    write(p.in, "\e[A")
    arm!(r, false)
    @test take!(events) == KeyEvent(K_UP)
    # Its type is what the host sends it, and only an argument of that type
    # arms it; what it reads with, and from, is the task's alone.
    @test r isa InputReader{Bool} && isconcretetype(typeof(r))
    @test_throws MethodError arm!(r)
    close(r)
    close(p.in)

    # Let go while parked: it ends, and says nothing more.
    q = Pipe()
    Base.link_pipe!(q; reader_supports_async = true, writer_supports_async = true)
    s = InputReader(q.out, events)
    close(s)
    wait(s.task)
    close(q.in)
    @test istaskdone(s.task) && !isready(events)
    # And from a held terminal, which is where its input is.
    t = enter_terminal(IOBuffer("j"), IOBuffer())
    u = InputReader(t, events)
    arm!(u)
    @test take!(events) == KeyEvent(Int('j'))
    arm!(u)
    @test take!(events) isa EndEvent                  # an IOBuffer ends too
end

@testset "a frame is one write, cursor hidden first and shown last" begin
    b = String(frame_bytes(["ab", "cd"], "", (2, 1)))
    # Held by the terminal until the closing sequence, drawn with the cursor
    # hidden, and the cursor put where the host said and shown only then.
    @test startswith(b, "\e[?2026h\e[?25l\e[?7l\e[r\e[1H")
    @test endswith(b, "cd\e[?7h\e[2;1H\e[?25h\e[?2026l")
    # Each row's line deleted before it is written, and a blank one put back
    # in its place, so nothing below it moves. A line xterm.js deletes takes
    # the markers of the links drawn on it; one overwritten or erased kept
    # them all. Not by a scroll region of the one row, which tmux ignores.
    @test occursin("\e[1H\e[M\e[Lab\e[2H\e[M\e[Lcd\e[?7h", b)
    @test !occursin(r"\e\[\d+;\d+r", b)
    @test !occursin("\e[K", b) && !occursin("\e[J", b) && !occursin('\n', b)
    # No cursor to show: it stays hidden, and nothing moves it.
    n = String(frame_bytes(["ab"]))
    @test endswith(n, "\e[M\e[Lab\e[?7h\e[?2026l") && !occursin("?25h", n)
    # The title goes after the frame and before the caret, inside the hold.
    t = String(frame_bytes(["x"], "\e]2;a title\e\\", (1, 1)))
    @test occursin("x\e[?7h\e]2;a title\e\\\e[1;1H\e[?25h", t)
    # Rows the frame did not bring, to the screen's height, are deleted too.
    f = String(frame_bytes(["ab"], "", nothing; h = 3))
    @test occursin("\e[M\e[Lab\e[2H\e[M\e[L\e[3H\e[M\e[L\e[?7h", f)
    # A row wider than the screen does not wrap onto the next: auto-wrap is
    # off from before the first row to after the last, and on again after,
    # and the next row is put at its own line whatever the cursor did.
    wide = String(frame_bytes(["abcdef", "gh"]))
    off, on = findfirst("\e[?7l", wide), findfirst("\e[?7h", wide)
    @test last(off) < first(findfirst("abcdef", wide)) &&
          first(on) > last(findfirst("gh", wide))
    @test occursin("abcdef\e[2H\e[M\e[Lgh", wide)
    # Rows of faces are written by StyledStrings, and a row as a string, or
    # with no faces, as it is.
    out(r) = sprint(print, r; context = :color => true)
    bold = faced("ab", Face(weight = :bold))
    fr = String(frame_bytes([bold, TermInput.row("cd"), "\e[1mef"]))
    @test occursin(string("\e[1H\e[M\e[L", out(bold), "\e[2H"), fr)
    @test occursin("\e[2H\e[M\e[Lcd\e[3H\e[M\e[L\e[1mef\e[?7h", fr)
    # A verbatim piece is written as it is and closed, and what follows it is
    # written from the column after its width, however little it drew.
    v = rowcat("│", verbatim("\e[31mab", 5), faced("│", Face(weight = :bold)))
    fv = String(frame_bytes([v]))
    @test occursin(string("\e[M\e[L│\e[31mab\e[0m\e[7G", out(faced("│", Face(weight = :bold)))), fv)
    two = rowcat(verbatim("x", 3), " ", verbatim("y", 2), "z")
    @test occursin("\e[M\e[Lx\e[0m\e[4G y\e[0m\e[7Gz", String(frame_bytes([two])))
end

@testset "no frame while input is waiting" begin
    # A burst is a key at a time with the rest already waiting, which is what
    # holds the frame until the last of them; a key typed alone is not.
    io = IOBuffer("hi\e[A")
    @test readevent(io) == KeyEvent(Int('h')) && input_waiting(io)
    readevent(io)
    @test readevent(io) == KeyEvent(K_UP) && !input_waiting(io)
    t = enter_terminal(IOBuffer("hi"), IOBuffer())
    @test input_waiting(t)
end

@testset "the README's program runs, from the README" begin
    # The block itself, so the README cannot say one thing while this tests
    # another.
    readme = read(joinpath(@__DIR__, "..", "README.md"), String)
    at = findfirst("### A whole program", readme)
    m = match(r"```julia\n(.*?)```"s, readme, last(at))
    host = Module(:ReadmeHost)
    Base.include_string(host, m[1])
    pick(input) = Base.invokelatest(host.pick, ["apple", "banana", "cherry"];
                                    input = IOBuffer(input), output = IOBuffer())
    @test pick("\r") == "apple"
    @test pick("\e[B\r") == "banana"                  # the cursor, by arrow
    @test pick("che\r") == "cherry"                   # narrowed by typing
    @test pick("\e[200~ban\n\e[201~\r") == "banana"   # a paste is the query
    @test pick("\e") === nothing
    @test pick("\e[Z\e") === nothing                  # Shift-Tab is not escape
    # What it wrote is a terminal put back as it was found.
    out = IOBuffer()
    Base.invokelatest(host.pick, ["a"]; input = IOBuffer("\r"), output = out)
    s = String(take!(out))
    @test startswith(s, "\e[?1049h\e[?25l")
    @test occursin("\e[?2026h", s) && occursin("Pick one", s)
    @test endswith(s, string(bracketed_paste(false), "\e[?25h\e[?1049l"))
end

@testset "the editor a widget hands the buffer to" begin
    # `⌥e` hands the buffer over and takes back whatever comes out. Nothing
    # here depends on an editor being installed: `define_editor` is the hook
    # `InteractiveUtils.edit` consults, which is the reason `edit` is used
    # rather than spawning `$EDITOR` - `JULIA_EDITOR` and these hooks are what
    # make the editor that opens the one `edit()` would open at the REPL.
    InteractiveUtils.define_editor("terminput_test_editor"; wait = true) do cmd, path, line, column
        write(path, "edited\nby somebody else\n")
        `$(Base.julia_cmd()) -e ""`
    end
    aseditor(f, name) =
        withenv(f, "JULIA_EDITOR" => name, "EDITOR" => nothing, "VISUAL" => nothing)

    calls = Ref(0)
    counted(f) = (calls[] += 1; f())
    v = TextArea("t"; initial = "before")
    aseditor("terminput_test_editor") do
        @test handle!(v, K_EDIT; suspend = counted) === :ok
    end
    @test text(v) == "edited\nby somebody else\n"
    @test (v.buf.row, v.buf.col) == (3, 1)   # the cursor is at the end of it
    @test isempty(v.status)                  # nothing to say when it worked
    @test calls[] == 1                       # the terminal was given away once

    # `^o` is the same move, because a terminal that treats Option as a compose
    # key sends no Meta at all and would leave the editor unreachable.
    w = TextArea("t"; initial = "before")
    aseditor("terminput_test_editor") do
        handle!(w, C_O; suspend = counted)
    end
    @test text(w) == text(v) && calls[] == 2

    # An editor that cannot be run loses nothing: what went in comes back, and
    # the status says what happened rather than the buffer silently emptying.
    e = TextArea("t"; initial = "keep this")
    aseditor("no-such-editor-anywhere-9f3a") do
        @test handle!(e, K_EDIT) === :ok
    end
    @test text(e) == "keep this"
    @test !isempty(e.status)

    # An editor that returns without writing is reported too, rather than
    # silently submitting what went in - `code` without `--wait` is the case,
    # and it is not obvious from the screen that nothing was edited.
    InteractiveUtils.define_editor("terminput_null_editor"; wait = true) do cmd, path, line, column
        `$(Base.julia_cmd()) -e ""`
    end
    n = TextArea("t"; initial = "unchanged")
    aseditor("terminput_null_editor") do
        handle!(n, K_EDIT)
    end
    @test text(n) == "unchanged"
    @test occursin("no change", n.status)
end

@testset "the cursor is the terminal's, and a block where the keys are not" begin
    # A terminal has one cursor and it goes where the keys are: the widget says
    # where, for `frame_bytes`, and draws nothing there. A host that draws this
    # beside something else has two things on screen and one of them has the
    # keys - so the other draws a block in reverse video where its cursor is,
    # which says where typing goes when the keys come back. A field rather than
    # the host painting over the frame afterwards, which is the only other way
    # to get there from outside.
    ta = TextArea("Comment", "on a.jl:11"; initial = "a remark")
    @test ta.focused                                    # the only-thing-on-screen case
    lit = screen(render(ta, 60, 16))
    @test !occursin("\e[7m", lit)
    r, c = caret(ta, 60, 16)
    @test cellat(ta, 60, 16) == " " && endswith(first(unescaped(split(lit, "\n")[r]), c - 1), "a remark")

    ta.focused = false
    dark = screen(render(ta, 60, 16))
    @test caret(ta, 60, 16) === nothing
    @test occursin(string("a remark", ansi(faced(" ", REV))), dark)
    # Only the cursor changes. Everything else is the same frame, at the same
    # size, so a host laying two columns against each other gets no shift.
    @test unescaped(dark) == unescaped(lit)
    @test length(split(dark, "\n")) == length(split(lit, "\n")) == 16

    # It is a way of drawing and not a way of behaving: an unfocused widget
    # still edits, because whether it should be sent keys at all is the host's
    # question and this is only the answer to how it looks.
    @test handle!(ta, keycode('!')) === :ok
    @test text(ta) == "a remark!"
    ta.focused = true
    @test !occursin("\e[7m", screen(render(ta, 60, 16))) && cellat(ta, 60, 16) == " "

    # Where it goes is a display column, past the wide characters before it,
    # and on the line the box scrolled to.
    cjk = TextArea("t"; initial = "日本語")
    handle!(cjk, K_LEFT)
    @test cellat(cjk, 60, 16) == "語"
    tall = TextArea("t"; initial = join(string.(1:40), "\n"))
    @test cellat(tall, 60, 16) == " "
    r, c = caret(tall, 60, 16)
    @test r <= 16 && endswith(first(unescaped(ansi(render(tall, 60, 16)[r])), c - 1), "40")
    for _ in 1:39; handle!(tall, K_UP); end
    handle!(tall, C_A)
    @test cellat(tall, 60, 16) == "1"
    # The query of a `Choice` is where typing goes there; a `Confirm` has none.
    ch = Choice("Pick", "", ["one", "two"])
    for k in "tw"; handle!(ch, keycode(k)); end
    handle!(ch, K_LEFT)
    # The option under the list's cursor is lit as it was; the query row has
    # no block on it.
    @test cellat(ch, 60, 16) == "w"
    @test !occursin("\e[7m", ansi(render(ch, 60, 16)[caret(ch, 60, 16)[1]]))
    @test caret(Confirm("Sure?", ""), 60, 16) === nothing
    # A screen too short for the box cuts it, and the cursor with it.
    @test caret(LineInput("t", "a\nb\nc\nd"), 60, 3) === nothing
end

@testset "a misspelt direction is an error, not a key that does nothing" begin
    b = TextBuffer("abc")
    @test_throws ArgumentError move!(b, :lft)
    @test b.col == 4
end

@testset "every exported or public name says what it is" begin
    # A name a host is told to import and cannot ask about is half an API.
    # `names` lists the public names on 1.11 and the exported ones before it.
    # `Docs.hasdoc` is 1.11's. Before it, a docstring is in the `meta` of the
    # module that owns the name - or, for a module, in that module's own.
    function hasdoc(m, n)
        isdefined(Docs, :hasdoc) && return Docs.hasdoc(m, n)
        b = Docs.Binding(m, n)
        v = getfield(m, n)
        haskey(Docs.meta(v isa Module ? v : b.mod), b)
    end
    api = setdiff(names(TermInput), [:TermInput])
    @test isempty(filter(n -> !hasdoc(TermInput, n), api))
    @test isempty(filter(n -> !hasdoc(TermInput.Keys, n),
                         setdiff(names(TermInput.Keys), [:Keys])))
    if VERSION >= v"1.11.0-DEV.469"
        # And the names the README tells a host to import are public.
        for n in (:render, :handle!, :text, :click!, :query, :query!, :selected,
                  :matches, :drawfield, :oneline, :doubled, :column)
            @test Base.ispublic(TermInput, n)
        end
        # A name a host is likely to have is not pushed into its namespace.
        for n in (:transpose!, :move!, :kill!, :yank!, :render)
            @test !Base.isexported(TermInput, n)
        end
    end
end

@testset "markdown, drawn as rows" begin
    import Markdown
    import TermInput: MarkdownStyle, MDRow
    md(s) = Markdown.parse(s)
    # The rows as they read, and the check every render has to pass: each one
    # exactly the width asked for, whatever went into it.
    function drawn(s, w = 40; kw...)
        rs = markdown_rows(md(s), w; kw...)
        @test all(r -> cols(ansi(r.text)) == w, rs)
        rs
    end
    texts(rs) = [rstrip(unescaped(ansi(r.text))) for r in rs]
    B, BG = Face(weight = :bold), Face(background = SimpleColor(:blue))
    I, D, U = Face(slant = :italic), Face(weight = :light), Face(underline = true)
    Y = Face(foreground = SimpleColor(:yellow))
    # What a face writes round a word, as StyledStrings has it for this
    # terminal: italic and strikethrough are what its terminfo says they are.
    around(f::Face, s) = ansi(TermInput.emit([TermInput.Run(s, [f])]))

    @testset "one per element" begin
        @test texts(drawn("just words")) == ["just words"]
        @test texts(drawn("# One\n\n###### Six")) == ["One", "", "Six"]
        # The level is carried by the style and nothing else.
        rs = drawn("## Two"; style = MarkdownStyle(h2 = B))
        @test startswith(ansi(rs[1].text), "\e[1mTwo\e[22m")
        rs = drawn("a **b** *c* ~~d~~";
                   style = MarkdownStyle(bold = B, italic = I,
                                         strike = Face(strikethrough = true)))
        @test occursin("\e[1mb\e[22m", ansi(rs[1].text))
        @test occursin(around(I, "c"), ansi(rs[1].text))
        # The stdlib parses `~~` and HTML blocks from 1.12 and 1.14.
        isdefined(Markdown, :Strikethrough) &&
            @test occursin(around(Face(strikethrough = true), "d"), ansi(rs[1].text))
        # Nested as written: the inner style inside the outer.
        rs = drawn("**a *b* c**"; style = MarkdownStyle(bold = B, italic = U))
        @test startswith(ansi(rs[1].text), "\e[1ma \e[4mb\e[24m c\e[22m ")
        # A code span keeps its backticks, in `code_tick` inside `code`.
        rs = drawn("x `y` z"; style = MarkdownStyle(code = BG, code_tick = D))
        # One background, the backticks dimmed inside it.
        @test occursin("x \e[44m\e[2m`\e[22my\e[2m`\e[49m\e[22m z", ansi(rs[1].text))
        # A weight inside a weight replaces it, and the outer one comes back
        # after - `22` ends bold and dim alike. Before 1.12, StyledStrings
        # writes one weight over the other, which a terminal draws as both.
        rs = drawn("**a `b` c**"; style = MarkdownStyle(bold = B, code_tick = D))
        @test occursin("\e[1ma \e[22m\e[2m`\e[22m\e[1mb\e[22m\e[2m`\e[22m\e[1m c\e[22m",
                       ansi(rs[1].text)) broken = VERSION < v"1.12"
        @test rs[1].src == "a `b` c"
        # A style inside a link is merged over it, and the link goes on after.
        rs = drawn("[x **b** y](u)"; style = MarkdownStyle(link = U, bold = B))
        @test startswith(ansi(rs[1].text), "\e[4mx \e[1mb\e[22m y\e[24m")
        # A close that ends none of what is open leaves it alone.
        rs = drawn("[x **b** y](u)"; style = MarkdownStyle(link = BG, bold = B))
        @test startswith(ansi(rs[1].text), "\e[44mx \e[1mb\e[22m y\e[49m")
        # Julia reads a double backtick as maths, so the span is built by hand.
        rs = markdown_rows(Markdown.MD(Any[Markdown.Paragraph(Any[Markdown.Code("", "a`b")])]), 10)
        @test texts(rs) == ["``a`b``"]
        # A link is its label; the url is the host's.
        rs = drawn("see [the docs](https://example.com) now";
                   style = MarkdownStyle(link = U))
        @test rstrip(ansi(rs[1].text)) == "see \e[4mthe docs\e[24m now"
        @test texts(drawn("![a cat](cat.png)")) == ["a cat"]
        # A list: the bullet, or numbers right-aligned to the widest.
        @test texts(drawn("- a\n- b")) == ["• a", "• b"]
        @test texts(drawn("9. a\n10. b\n11. c")) == [" 9. a", "10. b", "11. c"]
        # Loose when an item has more than one block: a blank row between.
        @test texts(drawn("- a\n\n  more\n- b")) == ["• a", "", "  more", "", "• b"]
        # ...and tight when all that makes it loose is what follows it.
        @test texts(drawn("- a\n- b\n\nafter")) == ["• a", "• b", "", "after"]
        # An empty item still has its bullet.
        @test texts(drawn("- a\n- \n- c")) == ["• a", "•", "• c"]
        @test texts(drawn("> said\n>\n> twice")) == ["│ said", "│", "│ twice"]
        rs = drawn("!!! warning \"Mind\"\n    the gap";
                   style = MarkdownStyle(warning = Y))
        @test [rstrip(ansi(r.text)) for r in rs] == ["\e[33m│ Mind\e[39m", "\e[33m│ \e[39mthe gap"]
        @test texts(drawn("!!! tip\n    x")) == ["│ Tip", "│ x"]
        @test [ansi(r.text) for r in drawn("---"; style = MarkdownStyle(rule = Y))] ==
              ["\e[33m" * "─"^40 * "\e[39m"]
        @test texts(drawn("a\\\nb")) == ["a", "b"]           # a LineBreak
        @test texts(drawn("\$\$x^2\$\$")) == ["\$\$x^2\$\$"]
        @test texts(drawn("a note[^1]\n\n[^1]: said here")) ==
              ["a note[^1]", "", "[^1]: said here"]
        isdefined(Markdown, :HTMLBlock) &&
            @test texts(drawn("<div>\nhi\n</div>")) == ["<div>", "hi", "</div>"]
    end

    @testset "code blocks" begin
        rs = drawn("```\nx = 1\n\ty\n```"; style = MarkdownStyle(codeblock = BG))
        @test [ansi(r.text) for r in rs] == ["  \e[44m x = 1" * " "^32 * "\e[49m",
                            "  \e[44m         y" * " "^28 * "\e[49m"]
        # Padded to the width, background and all, so the block reads as one.
        @test endswith(ansi(rs[1].text), "\e[49m")
        # The source keeps the tab; the row draws it as its columns.
        @test rs[2].src == "\ty"
        # Hard-wrapped, never reflowed: each row a piece of the one line.
        rs = drawn("```\n" * "a "^30 * "\n```", 20)
        @test length(rs) == 4 && rs[1].first && !any(r -> r.first, rs[2:end])
        @test all(r -> r.src == rstrip("a "^30), rs)
        @test unescaped(ansi(rs[1].text)) == "   " * "a a a a a a a a a"[1:17]
        # With no highlighter for the language, the block is `codeblock` alone.
        @test TermInput.highlight("python", "x = 1") == Tuple{UnitRange{Int},Symbol}[]
    end

    @testset "tables" begin
        t = "| a | b |\n|:--|--:|\n| one | 2 |\n| three | 45 |"
        @test texts(drawn(t)) == ["╭───────┬────╮", "│ a     │  b │", "├───────┼────┤",
                                  "│ one   │  2 │", "│ three │ 45 │", "╰───────┴────╯"]
        @test texts(drawn(t; style = MarkdownStyle(box = TermInput.BOXES.SQUARE)))[1] ==
              "┌───────┬────┐"
        rs = drawn(t; style = MarkdownStyle(table_head = B, table_rule = Y))
        @test occursin("\e[1ma\e[22m", ansi(rs[2].text))
        @test startswith(ansi(rs[1].text), "\e[33m╭")
        @test rs[4].src == "| one | 2 |"
        # Fitted to the width: the widest column narrowed first, and its cell
        # wrapped rather than cut - and then a rule between the body's rows.
        wide = "| k | v |\n|---|---|\n| a | " * "word "^12 * "|\n| b | c |"
        rs = drawn(wide, 30)
        @test all(r -> cols(ansi(r.text)) == 30, rs)
        @test occursin("word", join(texts(rs)))
        @test count(r -> occursin("word", ansi(r.text)), rs) > 1
        @test count(r -> startswith(unescaped(ansi(r.text)), "├"), rs) == 2
        # A column with no room is narrowed only so far.
        @test TermInput.fitcolumns([50, 50], 10) == [TermInput.TABLE_FLOOR, TermInput.TABLE_FLOOR]
        @test TermInput.fitcolumns([3, 30], 30) == [3, 20]
    end

    @testset "nesting" begin
        # A table in a list is drawn at its indent, not centred beside it.
        rs = drawn("- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |")
        @test texts(rs)[3] == "  ╭───┬───╮"
        @test texts(rs)[4] == "  │ a │ b │"
        # A list in a quote, and a quote in a list.
        @test texts(drawn("> - a\n> - b")) == ["│ • a", "│ • b"]
        @test texts(drawn("- > a")) == ["• │ a"]
        @test texts(drawn("- a\n  - b\n    - c")) == ["• a", "  • b", "    • c"]
        # A code span split across a wrap is closed at the end of one row and
        # opened again on the next, and nothing is left in force at either end.
        rs = drawn("xxxxxx `aaa bbb ccc` yy", 12; style = MarkdownStyle(code = BG))
        @test length(rs) == 2
        for r in rs
            @test count("\e[44m", ansi(r.text)) == count("\e[49m", ansi(r.text))
            @test !endswith(rstrip(ansi(r.text)), "\e[44m")
        end
        @test occursin("\e[44m`aaa\e[49m", ansi(rs[1].text))
        @test startswith(ansi(rs[2].text), "\e[44mbbb ccc`\e[49m")
        # The padding is never painted.
        @test all(r -> !occursin(r"\e\[48;5;236m\s*$", ansi(r.text)), rs)
    end

    @testset "the source map" begin
        # A word that ends at the edge breaks at the space after it, and the
        # next row starts at the next word.
        @test texts(drawn("aaaa bbbb cc", 4)) == ["aaaa", "bbbb", "cc"]
        @test texts(drawn("aa bb\\\nx", 2)) == ["aa", "bb", "x"]
        # A paragraph wrapped over three rows is one `src`, `first` on the first.
        p = "the quick brown fox jumps over the lazy dog and keeps going"
        rs = drawn(p, 24)
        @test length(rs) == 3
        @test all(r -> r.src == p, rs)
        @test [r.first for r in rs] == [true, false, false]
        # A line in a list starts behind its marker, and that is in its `src`.
        rs = drawn("- " * p, 24)
        @test all(r -> r.src == "• " * p, rs) && rs[1].first && !rs[2].first
        rs = drawn("> " * p, 24)
        @test all(r -> r.src == "│ " * p, rs)
        # Blank rows are lines of their own.
        rs = drawn("a\n\nb")
        @test [(r.src, r.first) for r in rs] == [("a", true), ("", true), ("b", true)]
        # `breaks`: a newline is a line break, each its own line; without it a
        # space. The stdlib keeps the newline from 1.14 only.
        if VERSION >= v"1.14.0-DEV"
            rs = drawn("one\ntwo"; breaks = true)
            @test [(unescaped(ansi(r.text)) |> rstrip, r.src, r.first) for r in rs] ==
                  [("one", "one", true), ("two", "two", true)]
            @test texts(drawn("one\ntwo")) == ["one two"]
            # Two spaces at a line's end break it either way, as CommonMark says.
            @test texts(drawn("one  \ntwo")) == ["one", "two"]
        end
    end

    @testset "widths are the terminal's" begin
        # A wide character is two columns and is never split; a combining mark
        # is none, and stays with the letter it marks.
        rs = drawn("中文中文中文", 5)
        @test texts(rs) == ["中文", "中文", "中文"]
        rs = drawn("éééé", 2)
        @test texts(rs) == ["éé", "éé"]
        @test all(r -> cols(ansi(r.text)) == 2, rs)
        # A word wider than the row is split by columns.
        @test texts(drawn("x" ^ 25, 10)) == ["x"^10, "x"^10, "x"^5]
        # Too narrow for a marker or a box is cut to the width, never wider.
        for w in 1:6
            drawn("- a\n\n> b\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```", w)
        end
    end

    @testset "no style asked for, no escape written" begin
        doc = "# h\n\n**b** *i* `c` [l](u)\n\n> q\n\n```\nx\n```\n\n| a |\n|---|\n| b |\n\n---"
        @test !any(r -> occursin('\e', ansi(r.text)), drawn(doc))
    end

    @testset "an element it does not know is its text" begin
        struct Mystery end
        Markdown.plain(io::IO, ::Mystery) = print(io, "a mystery")
        Markdown.plaininline(io::IO, ::Mystery) = print(io, "inline mystery")
        rs = markdown_rows(Markdown.MD(Any[Mystery(), Markdown.Paragraph(Any["x ", Mystery()])]), 30)
        @test texts(rs) == ["a mystery", "", "x inline mystery"]
    end
end

@testset "a code block in Julia is highlighted where Julia has a highlighter" begin
    import Markdown
    import TermInput: MarkdownStyle, highlight
    Y, G = Face(foreground = SimpleColor(:yellow)), Face(foreground = SimpleColor(:green))
    # A face with no style of its own falls back through the fixed table, and
    # then to nothing.
    st = MarkdownStyle(faces = Dict(:string => G, :operator => Y, :parentheses => Y))
    @test TermInput.facestyle(st, :string_delim) == G
    @test TermInput.facestyle(st, :rainbow_paren_3) == Y
    @test TermInput.facestyle(st, :opassignment) == Y
    @test TermInput.facestyle(st, :keyword) == Face()
    # Every other language is the stub's, everywhere.
    @test highlight("python", "def f(): pass") == Tuple{UnitRange{Int},Symbol}[]
    # A fence's language is a type, and the Julia ones are one type.
    @test TermInput.codemime(" Python ") == MIME"text/python"()
    @test all(l -> TermInput.codemime(l) == MIME"text/julia"(), ("julia", "JL", "jldoctest", ""))
    # A host's highlighter for a language of its own is a method on its type,
    # beside Julia's rather than in place of it.
    @eval TermInput.highlight(::MIME"text/wltest", code::AbstractString) =
        [(firstindex(code):lastindex(code), :string)]
    @test highlight("wltest", "abc") == [(1:3, :string)]
    @test highlight("python", "def f(): pass") == Tuple{UnitRange{Int},Symbol}[]
    if VERSION >= v"1.12"
        # `Markdown` loads JuliaSyntaxHighlighting, which loads the extension.
        @test Base.get_extension(TermInput, :TermInputHighlightExt) !== nothing
        hl = highlight("julia", "function f(x) end")
        @test (1:8, :keyword) in hl
        @test any(r -> r[1] == 10:10 && r[2] in (:funcdef, :funcall), hl)   # by version
        @test all(f -> !startswith(String(f), "julia_"), last.(hl))
        @test highlight("", "x = 1") == highlight("jldoctest", "x = 1") != []
        @test highlight(MIME"text/julia"(), SubString("x = 1")) == highlight("julia", "x = 1")
        rs = markdown_rows(Markdown.parse("```julia\nfunction f() end\n```"), 30;
                           style = MarkdownStyle(faces = Dict(:keyword => Y)))
        @test occursin("\e[33mfunction\e[39m", ansi(rs[1].text))
        @test unescaped(ansi(rs[1].text)) == rpad("   function f() end", 30)
        @test rs[1].src == "function f() end"
        # The colours alone, for a host drawing code its own way: a line each,
        # tabs as written, each line closed.
        ls = TermInput.highlighted_lines("julia", "function f()\n\tend",
                                         MarkdownStyle(faces = Dict(:keyword => Y)))
        @test ansi.(ls) == ["\e[33mfunction\e[39m f()", "\t\e[33mend\e[39m"]
    else
        @test TermInput.highlighted_lines("julia", "a\nb") == ["a", "b"]
        # Before 1.12 there is no highlighter, and the extension never loads.
        @test Base.get_extension(TermInput, :TermInputHighlightExt) === nothing
        @test highlight("julia", "x = 1") == Tuple{UnitRange{Int},Symbol}[]
    end
end

end # testset TermInput
