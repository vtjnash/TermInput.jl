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
import TermInput: render, handle!, text, chunks, drawcursor, displaycolumn
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
    @test word_start("foo bar   ", 11) == 5      # over the spaces, then the word
    @test word_start("foo bar", 8) == 5
    @test word_start("foo", 1) == 1              # nothing behind the cursor
    @test word_end("foo bar", 1) == 4
    @test word_end("  foo bar", 1) == 6          # skip leading space first
    @test word_end("foo", 4) == 4
    # The two readline rules differ, and the difference is the point.
    @test word_start("/usr/local/lib", 15) == 1                 # ^w: no space to stop at
    @test word_start("/usr/local/lib", 15; alnum = true) == 12  # alt-bksp: just "lib"
    @test word_end("foo.bar", 1; alnum = true) == 4
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

@testset "the box comes from Term's theme" begin
    # The glyphs are Term's, so a widget drawn beside a `Term.Panel` is
    # bordered the way it is - and a theme naming a box that is not there is a
    # different corner, not an exception.
    import Term
    b = dialogbox(80)
    @test occursin(string(boxstyle().top.left), b.head("title"))
    @test occursin("title", astrip(b.head("title")))
    @test awidth(b.row("x")) == b.pad + b.box
    @test awidth(b.foot()) == b.pad + b.box
    @test awidth(b.head("a title")) == b.pad + b.box
    @test awidth(b.top()) == b.pad + b.box
    # A title too long for the edge is elided rather than pushing the corner
    # off the end of it.
    @test awidth(b.head("t"^300)) == b.pad + b.box

    old = Term.TERM_THEME[].box
    try
        Term.TERM_THEME[].box = :SQUARE
        @test occursin(string(Term.Boxes.BOXES.SQUARE.top.left), dialogbox(80).head("t"))
        Term.TERM_THEME[].box = :NOT_A_BOX
        @test boxstyle() === Term.Boxes.BOXES.ROUNDED
    finally
        Term.TERM_THEME[].box = old
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
    v = TextArea("t"; initial = "before", suspend = f -> (calls[] += 1; f()))
    aseditor("terminput_test_editor") do
        @test handle!(v, K_EDIT) === :ok
    end
    @test text(v) == "edited\nby somebody else\n"
    @test (v.buf.row, v.buf.col) == (3, 1)   # the cursor is at the end of it
    @test isempty(v.status)                  # nothing to say when it worked
    @test calls[] == 1                       # the terminal was given away once

    # `^o` is the same move, because a terminal that treats Option as a compose
    # key sends no Meta at all and would leave the editor unreachable.
    w = TextArea("t"; initial = "before", suspend = f -> (calls[] += 1; f()))
    aseditor("terminput_test_editor") do
        handle!(w, C_O)
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

end # testset TermInput
