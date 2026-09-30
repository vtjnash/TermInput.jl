# What can be tested without a terminal, which here is everything.
#
# `render` is a pure function of a widget and a size, `handle!` takes a key code
# and returns an action, and the editing model underneath both is a function of
# a buffer. Nothing reads stdin, so nothing needs a tty - and the one thing that
# touches a real terminal, `suspend`, is asserted on the escape sequences it
# writes to stdout.
#
#     julia --project=. test/runtests.jl

using Test
using TermInput
import TermInput: render, handle!, text, chunks, drawcursor, drawfield, displaycolumn
# The public names that are not exported, as a host would import them.
import TermInput: ESCAPE, settext!, curline, move!, newline!, insertblock!, paste!,
    backspace!, deletechar!, killline!, killtostart!, deleteword!, killwordforward!,
    kill!, yank!, transpose!, wordstart, wordend, bufferrows, boxstyle, dialogbox,
    centred, CHROME, ACTIONS, click!, query, query!, selected, matches, doubled,
    DOUBLECLICK, oneline, column, BOXES, Box, BoxLine
import InteractiveUtils

@testset "TermInput" begin

@testset "display width of text with escapes in it" begin
    @test awidth("plain") == 5
    @test awidth("\e[32mgreen\e[0m") == 5
    @test awidth("\e]8;;http://x\e\\link\e]8;;\e\\") == 4
    @test astrip("\e[32mgreen\e[0m") == "green"
    @test apad("ab", 5) == "ab   " && awidth(apad("ab", 5)) == 5
    @test awidth(apad("\e[32mab\e[0m", 5)) == 5
    # Truncation keeps the escapes it passed and closes the style at the cut -
    # but only where there was a style to close. Plain text cut short comes
    # back plain, so a program that emits no escapes goes on emitting none.
    @test awidth(afit("abcdefgh", 4)) == 4
    @test afit("abcdefgh", 4) == "abc…"
    @test endswith(afit("\e[32mabcdefgh", 4), "…\e[0m")
    @test afit("abc", 10) == "abc"
    @test afit("abc", 0) == ""
    @test awidth(afit("\e[32mabcdefgh\e[0m", 4)) == 4
end

@testset "a name too long for its column is told apart at the end" begin
    # Names in a fixed column agree at the front and differ at the end far more
    # often than the other way round - branches under one owner prefix, urls
    # into one issue - so cutting at the tail draws a pair like that as the
    # *same string*, and a list whose job is telling two of something apart then
    # tells you nothing.
    a = "users/someone/tsa-tryheld-state"
    b = "users/someone/tsa-tryheld-other"
    @test afit(a, 26) == afit(b, 26)              # what eliding at the tail does
    @test amid(a, 26) != amid(b, 26)              # and what this does instead
    @test awidth(amid(a, 26)) == 26
    @test endswith(amid(a, 26), "state") && startswith(amid(a, 26), "users/")

    # Short enough is left exactly as it was.
    @test amid("patch-11", 26) == "patch-11"
    @test amid("", 26) == ""
    @test amid("anything", 0) == ""
    # Never wider than asked, at any width worth drawing. Below three columns
    # there is no room for a head, a mark and a tail, and the arithmetic that
    # spends `w - 1` on each end would come back one column too wide.
    for w in 1:40, s in (a, b, "x", "abcdefgh")
        @test awidth(amid(s, w)) <= w
    end
    # A wide character is not split down the middle to make the count come out.
    @test awidth(amid("日本語のブランチ名前です", 11)) <= 11
end

@testset "wrapping keeps the style across the break" begin
    ok(s, w) = all(awidth(l) <= w for l in awrap(s, w))
    # Nothing is lost or gained: a break only ends a line, it never edits.
    same(s, w) = astrip(join(awrap(s, w), "")) == astrip(s)

    @test awrap("guard the remaining raw stderr writes that gate cleanup", 40) ==
          ["guard the remaining raw stderr writes ", "that gate cleanup"]
    # A word is carried to the next line whole, rather than cut at the margin.
    @test !any(occursin("deliver_resu", l) && !occursin("deliver_result", l)
               for l in awrap("guard cleanup in deliver_result and connect_to_peer", 40))

    # A colour opened before a break is replayed after it, or it would stop
    # there - and the escapes travel with the word they style, so a word carried
    # down takes its colour with it and is not styled twice.
    st = awrap("\e[31mred words here\e[0m and \e[32mgreen ones\e[0m too", 14)
    @test all(awidth(l) <= 14 for l in st)
    @test count(l -> occursin("\e[32m", l), st) == 1
    @test startswith(st[2], "\e[31m")          # the colour resumes on line two
    # ...and ends where line one does, so padding the row paints nothing: a
    # background open at a break is closed at the break, on every row it spans.
    bg = awrap("aa \e[41mbbb ccc\e[49m dd", 6)
    @test bg == ["aa ", "\e[41mbbb \e[0m", "\e[41mccc\e[49m dd"]
    @test endswith(apad(bg[2], 8), "\e[0m    ")
    @test awrap("\e[41m" * "x"^10, 4) == ["\e[41mxxxx\e[0m", "\e[41mxxxx\e[0m", "\e[41mxx"]
    for (s, w) in (("\e[32mgreen words that go on and on and on\e[0m", 12),
                   ("plain \e[1mbold\e[0m and \e[31mred\e[0m again", 10))
        @test ok(s, w) && same(s, w)
    end

    # A run wider than the pane has nowhere to break - a url, a stack frame, a
    # type signature - so it is split rather than allowed to overflow, and the
    # pieces fill the width rather than coming out ragged.
    long = awrap("a " * "x"^45, 20)
    @test length(long) > 1 && ok("a " * "x"^45, 20)
    @test length([l for l in long if awidth(l) == 20]) >= 2

    for w in (12, 20, 40, 79)
        for t in ("short", "", "     ", "a b c d e f g h i j k l m n o p q r s t",
                  "https://github.com/JuliaLang/julia/pull/62841#issuecomment-372112478 see",
                  "Tuple{Type{S{N, Tup}}, Vararg{Any}} and some prose after it",
                  "word " * "y"^100 * " tail")
            @test ok(t, w)
            @test same(t, w)
        end
    end

    # A hyperlink open at a break is closed on that row and reopened on the
    # next, or the terminal runs it on across whatever is drawn beside the
    # line - it knows nothing of panes. Each row carries a whole link.
    on, off = "\e]8;;https://x.example/a/b\e\\", "\e]8;;\e\\"
    lk = awrap(string("see ", on, "\e[4mthe linked words here\e[24m", off, " after"), 12)
    @test all(awidth(l) <= 12 for l in lk) && length(lk) >= 3
    @test count(l -> count(on, l) == count(off, l), lk) == length(lk)
    @test count(l -> occursin(on, l), lk) >= 2       # reopened on the next row
    @test astrip(join(lk, "")) == "see the linked words here after"
    # A link split mid-run - a bare url wider than the pane - the same.
    u = awrap(string(on, "https://x.example/", "p"^40, off), 16)
    @test all(count(on, l) == count(off, l) for l in u) && length(u) > 1
    # And one closed before the break is not reopened after it.
    cl = awrap(string(on, "ab", off, " then more words to wrap"), 10)
    @test count(l -> occursin(on, l), cl) == 1
    # A cut is a break with nothing after it: the link is closed at it.
    cut = afit(string("see ", on, "the linked words", off, " after"), 12)
    @test awidth(cut) <= 12 && count(on, cut) == count(off, cut) == 1
    @test count(off, afit(string(on, "ab", off, " and the rest of it"), 10)) == 1  # not twice

    # Degenerate widths do not loop or throw.
    @test awrap("anything", 1) == ["anything"]
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
    @test drawcursor("abc", 2) == "a\e[7mb\e[0mc"
    @test astrip(drawcursor("héllo", 3)) == "héllo"
    @test astrip(drawcursor("日本語", 3)) == "日本語"
    @test occursin("\e[7m本", drawcursor("日本語", 3))
    # Past the end of the line there is a blank to stand on, so the cursor is
    # still somewhere: `\e[7m\e[0m` paints nothing at all.
    @test drawcursor("ab", 3) == "ab\e[7m \e[0m"
    @test astrip(drawcursor("", 1)) == " "
    # Drawing the cursor adds no columns to a line it is inside of.
    for (s, c) in (("abc", 2), ("héllo", 4), ("日本語", 1), ("", 1))
        @test awidth(drawcursor(s, c)) == max(awidth(s), c)
    end
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
        ls = split(render(v, w, h), "\n")
        @test length(ls) == h
        @test all(awidth(l) == w for l in ls)
    end
    # The box stops widening long before the screen does, because a line of
    # prose 200 columns wide is not one anybody can read.
    wide = split(render(v, 200, 24), "\n")
    @test maximum(awidth(astrip(strip(l))) for l in wide) <= v.maxwidth

    # A buffer taller than the box scrolls to keep the cursor on screen, and
    # the frame stays exactly as tall.
    tall = TextArea("t"; initial = join(string.("line ", 1:200), "\n"))
    ls = split(render(tall, 80, 24), "\n")
    @test length(ls) == 24 && all(awidth(l) == 80 for l in ls)
    @test any(l -> occursin("line 200", l), ls)      # the cursor's line is shown
    @test !any(l -> occursin("line 1 ", l), ls)
    tall.buf.row = 1
    ls = split(render(tall, 80, 24), "\n")
    @test any(l -> occursin("line 1", l), ls)

    # A note of several lines is several rows, and a tab or an escape in the
    # buffer is one column rather than a jump or a command.
    for v in (TextArea("T", "line1\nline2"), TextArea("T"; initial = "a\tb\e[31mc\r\td"))
        ls = split(render(v, 40, 20), "\n")
        @test length(ls) == 20 && all(awidth(l) == 40 for l in ls)
    end

    # Whatever is in the buffer, including what a terminal sent and no
    # codepoint covers, comes back as columns rather than as an exception.
    odd = TextArea("t")
    for c in "日本語 é "; handle!(odd, keycode(c)); end
    insert!(odd.buf, keychar(Int(0xF4908080)))
    ls = split(render(odd, 80, 24), "\n")
    @test all(awidth(l) == 80 for l in ls)
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
        ls = split(render(p, w, h), "\n")
        @test length(ls) == h && all(awidth(l) == w for l in ls)
    end

    # A line longer than the box scrolls sideways to keep the cursor on it, and
    # a `…` says what went off the front.
    long = LineInput("t"; initial = join('a':'z') * join('0':'9') * join('A':'J'))
    cursorline(v, w) = only(filter(l -> occursin("\e[7m", l), split(render(v, w, 10), "\n")))
    l = astrip(cursorline(long, 30))
    @test awidth(cursorline(long, 30)) == 30 && occursin("> …", l) && occursin("J  ", l)
    long.buf.col = 1
    @test occursin("> abc", astrip(cursorline(long, 30)))
    long.buf.col = 30
    l = cursorline(long, 30)
    @test occursin("\e[7m3\e[0m…", l) && occursin("> …", astrip(l))
    @test drawfield("abc", 4, 10) == drawcursor("abc", 4)
    @test astrip(drawfield("abcdefghij", 11, 10)) == "…defghij "
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
    # The default hint names only the keys the widget owns: picking and
    # escape come back, so saying what they do is the host's.
    @test occursin(CHOICE_HINT, render(n, 80, 24))
    @test !occursin("esc", CHOICE_HINT) && !occursin("↵", CHOICE_HINT)
    # A status is shown instead of the hint, and the next key clears it.
    n.status = "no labels to add"
    @test occursin("no labels to add", render(n, 80, 24))
    handle!(n, K_DOWN)
    @test isempty(n.status) && occursin(CHOICE_HINT, render(n, 80, 24))
    # A paste is one line of query.
    query!(c, ""); TermInput.paste!(c, "doc\n")
    @test query(c) == "doc" && matches(c) == [2]

    # The query scrolls sideways, as a line input does.
    query!(c, "x"^100)
    @test occursin("/ …xxx", astrip(render(c, 60, 20)))
    query!(c, "")

    # The frame, and where it put the rows, for the mouse.
    many = ["opt $i" * (iseven(i) ? "\n  under $i" : "") for i in 1:12]
    m = Choice("t", "", many; numbered = true)
    for (w, h) in ((90, 24), (80, 12), (160, 50))
        ls = split(render(m, w, h), "\n")
        @test length(ls) == h && all(awidth(l) == w for l in ls)
    end
    ls = split(astrip(render(m, 80, 50)), "\n")
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
    ls = split(astrip(render(t, 40, 12)), "\n")
    @test length(ls) == 12 && all(awidth(l) == 40 for l in ls)
    @test ls[first(t.orows) + 1] |> l -> occursin(" b ", l)
    @test click!(t, :press, 10, first(t.orows) + 1, 1.0) === :ok && selected(t) == 2

    # A malformed byte in the query - or a label - is matched as itself, not an
    # error that leaves the picker unable to draw.
    bad = Choice("t", "", ["a\x80b", "abc"])
    @test handle!(bad, 0x80 + 0) === :ok && query(bad) == "\x80"
    @test matches(bad) == [1] && selected(bad) == 1 && picked(bad, 13) == 1
    @test length(split(render(bad, 40, 12), "\n")) == 12
    query!(bad, "A")
    @test matches(bad) == [1, 2]

    # The rows of a list in a box: the cursor's row whole, and the box full.
    @test listwindow([1, 3, 2, 1, 1], 2, 1, 3) == (2, 2, 2:2)
    @test listwindow([1, 3, 2, 1, 1], 3, 1, 3) == (3, 3, 3:4)
    @test listwindow([1, 1, 1], 1, 1, 10) == (1, 1, 1:3)
end

@testset "a question only named keys answer" begin
    # What a host calls to read a pick or an answer is exported with the widget.
    @test :picked in names(TermInput) && :answer in names(TermInput)
    q = Confirm("Discard?", ["", "it is nowhere else"])
    @test q.note == "it is nowhere else"
    @test occursin(CONFIRM_HINT, render(q, 60, 10))
    # Every widget takes its note the same way: a string, or rows with the
    # empty ones left out.
    @test Confirm("t", "a\nb").note == Confirm("t", ["a", "", "b"]).note == "a\nb"
    @test TextArea("t", ["a", "", "b"]).note == LineInput("t", ["a", "b"]).note ==
          Choice("t", ["a", "b"], ["x"]).note == "a\nb"
    # The hint is a field a host may set afterwards, on every widget.
    q.hint = "y discards it"
    @test occursin("y discards it", render(q, 60, 10))
    @test answer(q, keycode('y')) == 1 && answer(q, keycode('Y')) == 1
    @test answer(q, 13) == 0 && answer(q, 27) == 0 && answer(q, keycode('n')) == 0
    q2 = Confirm("Quit", "a draft", ["yY", "\e"]; hint = "y quits · esc goes back")
    @test answer(q2, 27) == 2 && answer(q2, K_UP) == 0
    ls = split(render(q2, 60, 10), "\n")
    @test length(ls) == 10 && all(awidth(l) == 60 for l in ls)
    @test any(l -> occursin("esc goes back", l), ls)
    q3 = Confirm("Quit", "a draft\nand a stash")
    ls = split(astrip(render(q3, 60, 10)), "\n")
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
    @test occursin(string(boxstyle().top.left), b.head("title"))
    @test occursin("title", astrip(b.head("title")))
    @test awidth(b.row("x")) == b.pad + b.bw
    @test awidth(b.foot()) == b.pad + b.bw
    @test awidth(b.head("a title")) == b.pad + b.bw
    @test awidth(b.top()) == b.pad + b.bw
    # A title too long for the edge is elided rather than pushing the corner
    # off the end of it.
    @test awidth(b.head("t"^300)) == b.pad + b.bw
    # The rows a widget draws are painted in the weights its border was, so a
    # box given weights of its own is one box and not two.
    plain = (strong = "", quiet = "", focus = "", reset = "", box = BOXES.ROUNDED)
    @test dialogbox(80; chrome = plain).chrome === plain
    old = CHROME[]
    try
        CHROME[] = plain
        @test !occursin('\e', render(Confirm("t", "a note"), 60, 10))
        # Bar the cursor, which is reverse video whatever the chrome says.
        @test !occursin('\e', replace(render(LineInput("t", "a note"), 60, 10),
                                       "\e[7m \e[0m" => ""))
    finally
        CHROME[] = old
    end

    old = CHROME[]
    try
        CHROME[] = merge(old, (box = BOXES.SQUARE,))
        @test occursin("┌", dialogbox(80).head("t"))
        @test occursin("└", dialogbox(80).foot())
        @test occursin("╔", dialogbox(80; box = boxstyle(:DOUBLE)).top())
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
    @test length(split(centred(["a"], 20, 5), "\n")) == 5
    @test all(awidth(l) == 20 for l in split(centred(["a", "b"], 20, 5), "\n"))
    # More rows than there is room for is a frame of the size asked for, still.
    @test length(split(centred([string(i) for i in 1:50], 20, 5), "\n")) == 5
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

@testset "a widget that does not have the keyboard draws no cursor" begin
    # A host that draws this beside something else has two things on screen and
    # one of them has the keys. Two cursors would say neither does - so the
    # widget takes it as a field rather than the host having to paint over the
    # block afterwards, which is the only other way to get there from outside.
    ta = TextArea("Comment", "on a.jl:11"; initial = "a remark")
    @test ta.focused                                    # the only-thing-on-screen case
    lit = render(ta, 60, 16)
    @test occursin("\e[7m", lit)

    ta.focused = false
    dark = render(ta, 60, 16)
    @test !occursin("\e[7m", dark)
    # Only the cursor goes. Everything else is the same frame, at the same size,
    # so a host laying two columns against each other gets no shift out of it.
    @test astrip(dark) == astrip(lit)
    @test length(split(dark, "\n")) == length(split(lit, "\n")) == 16

    # It is a way of drawing and not a way of behaving: an unfocused widget
    # still edits, because whether it should be sent keys at all is the host's
    # question and this is only the answer to how it looks.
    @test handle!(ta, keycode('!')) === :ok
    @test text(ta) == "a remark!"
    ta.focused = true
    @test occursin("\e[7m", render(ta, 60, 16))
end

@testset "a misspelt direction is an error, not a key that does nothing" begin
    b = TextBuffer("abc")
    @test_throws ArgumentError move!(b, :lft)
    @test b.col == 4
end

@testset "every exported or public name says what it is" begin
    # A name a host is told to import and cannot ask about is half an API.
    # `names` lists the public names on 1.11 and the exported ones before it.
    api = setdiff(names(TermInput), [:TermInput])
    @test isempty(filter(n -> !Docs.hasdoc(TermInput, n), api))
    @test isempty(filter(n -> !Docs.hasdoc(TermInput.Keys, n),
                         setdiff(names(TermInput.Keys), [:Keys])))
    if VERSION >= v"1.11.0-DEV.469"
        # And the names the README tells a host to import are public.
        for n in (:render, :handle!, :text, :click!, :query, :query!, :selected,
                  :matches, :drawfield, :oneline, :doubled, :column)
            @test Base.ispublic(TermInput, n)
        end
        # A name a host is likely to have is not pushed into its namespace.
        for n in (:transpose!, :move!, :kill!, :yank!, :ESCAPE, :render)
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
        @test all(r -> awidth(r.text) == w, rs)
        rs
    end
    texts(rs) = [rstrip(astrip(r.text)) for r in rs]
    B = ("\e[1m", "\e[22m")
    BG = ("\e[48;5;236m", "\e[49m")
    I, D, U, Y = ("\e[3m", "\e[23m"), ("\e[2m", "\e[22m"), ("\e[4m", "\e[24m"),
                 ("\e[33m", "\e[39m")

    @testset "one per element" begin
        @test texts(drawn("just words")) == ["just words"]
        @test texts(drawn("# One\n\n###### Six")) == ["One", "", "Six"]
        # The level is carried by the style and nothing else.
        rs = drawn("## Two"; style = MarkdownStyle(h2 = B))
        @test startswith(rs[1].text, "\e[1mTwo\e[22m")
        rs = drawn("a **b** *c* ~~d~~";
                   style = MarkdownStyle(bold = B, italic = ("\e[3m", "\e[23m"),
                                         strike = ("\e[9m", "\e[29m")))
        @test occursin("\e[1mb\e[22m", rs[1].text)
        @test occursin("\e[3mc\e[23m", rs[1].text)
        # The stdlib parses `~~` and HTML blocks from 1.12 and 1.14.
        isdefined(Markdown, :Strikethrough) && @test occursin("\e[9md\e[29m", rs[1].text)
        # Nested as written: the inner style inside the outer.
        rs = drawn("**a *b* c**"; style = MarkdownStyle(bold = B, italic = I))
        @test startswith(rs[1].text, "\e[1ma \e[3mb\e[23m c\e[22m ")
        # A code span keeps its backticks, in `code_tick` inside `code`.
        rs = drawn("x `y` z"; style = MarkdownStyle(code = BG, code_tick = D))
        # One background, the backticks dimmed inside it.
        @test occursin("x \e[48;5;236m\e[2m`\e[22my\e[2m`\e[22m\e[49m z", rs[1].text)
        # An end that ends an outer style too - `22` is bold's and dim's -
        # opens the outer one again.
        rs = drawn("**a `b` c**"; style = MarkdownStyle(bold = B, code_tick = D))
        @test occursin("\e[1ma \e[2m`\e[22m\e[1mb\e[2m`\e[22m\e[1m c\e[22m", rs[1].text)
        @test rs[1].src == "a `b` c"
        # Julia reads a double backtick as maths, so the span is built by hand.
        rs = markdown_rows(Markdown.MD(Any[Markdown.Paragraph(Any[Markdown.Code("", "a`b")])]), 10)
        @test texts(rs) == ["``a`b``"]
        # A link is its label; the url is the host's.
        rs = drawn("see [the docs](https://example.com) now";
                   style = MarkdownStyle(link = U))
        @test rstrip(rs[1].text) == "see \e[4mthe docs\e[24m now"
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
        @test [rstrip(r.text) for r in rs] == ["\e[33m│ \e[39m\e[33mMind\e[39m", "\e[33m│ \e[39mthe gap"]
        @test texts(drawn("!!! tip\n    x")) == ["│ Tip", "│ x"]
        @test [r.text for r in drawn("---"; style = MarkdownStyle(rule = Y))] ==
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
        @test [r.text for r in rs] == ["  \e[48;5;236m x = 1" * " "^32 * "\e[49m",
                            "  \e[48;5;236m         y" * " "^28 * "\e[49m"]
        # Padded to the width, background and all, so the block reads as one.
        @test endswith(rs[1].text, "\e[49m")
        # The source keeps the tab; the row draws it as its columns.
        @test rs[2].src == "\ty"
        # Hard-wrapped, never reflowed: each row a piece of the one line.
        rs = drawn("```\n" * "a "^30 * "\n```", 20)
        @test length(rs) == 4 && rs[1].first && !any(r -> r.first, rs[2:end])
        @test all(r -> r.src == rstrip("a "^30), rs)
        @test astrip(rs[1].text) == "   " * "a a a a a a a a a"[1:17]
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
        @test occursin("\e[1ma\e[22m", rs[2].text)
        @test startswith(rs[1].text, "\e[33m╭")
        @test rs[4].src == "| one | 2 |"
        # Fitted to the width: the widest column narrowed first, and its cell
        # wrapped rather than cut - and then a rule between the body's rows.
        wide = "| k | v |\n|---|---|\n| a | " * "word "^12 * "|\n| b | c |"
        rs = drawn(wide, 30)
        @test all(r -> awidth(r.text) == 30, rs)
        @test occursin("word", join(texts(rs)))
        @test count(r -> occursin("word", r.text), rs) > 1
        @test count(r -> startswith(astrip(r.text), "├"), rs) == 2
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
            @test count("\e[48;5;236m", r.text) == count("\e[49m", r.text)
            @test !endswith(rstrip(r.text), "\e[48;5;236m")
        end
        @test occursin("\e[48;5;236m`aaa\e[49m", rs[1].text)
        @test startswith(rs[2].text, "\e[48;5;236mbbb ccc`\e[49m")
        # The padding is never painted.
        @test all(r -> !occursin(r"\e\[48;5;236m\s*$", r.text), rs)
    end

    @testset "the source map" begin
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
            @test [(astrip(r.text) |> rstrip, r.src, r.first) for r in rs] ==
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
        @test all(r -> awidth(r.text) == 2, rs)
        # A word wider than the row is split by columns.
        @test texts(drawn("x" ^ 25, 10)) == ["x"^10, "x"^10, "x"^5]
        # Too narrow for a marker or a box is cut to the width, never wider.
        for w in 1:6
            drawn("- a\n\n> b\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```", w)
        end
    end

    @testset "no style asked for, no escape written" begin
        doc = "# h\n\n**b** *i* `c` [l](u)\n\n> q\n\n```\nx\n```\n\n| a |\n|---|\n| b |\n\n---"
        @test !any(r -> occursin('\e', r.text), drawn(doc))
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
    Y, G = ("\e[33m", "\e[39m"), ("\e[32m", "\e[39m")
    # A face with no style of its own falls back through the fixed table, and
    # then to nothing.
    st = MarkdownStyle(faces = Dict(:string => G, :operator => Y, :parentheses => Y))
    @test TermInput.facestyle(st, :string_delim) == G
    @test TermInput.facestyle(st, :rainbow_paren_3) == Y
    @test TermInput.facestyle(st, :opassignment) == Y
    @test TermInput.facestyle(st, :keyword) == ("", "")
    # Every other language is the stub's, everywhere.
    @test highlight("python", "def f(): pass") == Tuple{UnitRange{Int},Symbol}[]
    if VERSION >= v"1.12"
        # `Markdown` loads JuliaSyntaxHighlighting, which loads the extension.
        @test Base.get_extension(TermInput, :TermInputHighlightExt) !== nothing
        hl = highlight("julia", "function f(x) end")
        @test (1:8, :keyword) in hl
        @test any(r -> r[1] == 10:10 && r[2] in (:funcdef, :funcall), hl)   # by version
        @test all(f -> !startswith(String(f), "julia_"), last.(hl))
        @test highlight("", "x = 1") == highlight("jldoctest", "x = 1") != []
        rs = markdown_rows(Markdown.parse("```julia\nfunction f() end\n```"), 30;
                           style = MarkdownStyle(faces = Dict(:keyword => Y)))
        @test occursin("\e[33mfunction\e[39m", rs[1].text)
        @test astrip(rs[1].text) == rpad("   function f() end", 30)
        @test rs[1].src == "function f() end"
        # The colours alone, for a host drawing code its own way: a line each,
        # tabs as written, each line closed.
        ls = TermInput.highlighted_lines("julia", "function f()\n\tend",
                                         MarkdownStyle(faces = Dict(:keyword => Y)))
        @test ls == ["\e[33mfunction\e[39m f()", "\t\e[33mend\e[39m"]
    else
        @test TermInput.highlighted_lines("julia", "a\nb") == ["a", "b"]
        # Before 1.12 there is no highlighter, and the extension never loads.
        @test Base.get_extension(TermInput, :TermInputHighlightExt) === nothing
        @test highlight("julia", "x = 1") == Tuple{UnitRange{Int},Symbol}[]
    end
end

end # testset TermInput
