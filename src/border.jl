# The box a widget is drawn in.
#
# The characters are this package's own table, a handful of the boxes a
# terminal program is drawn in, and the one to use is a field of `CHROME` beside
# the weights it is painted in - a host with a theme sets both in one place, and
# every widget and every table follows.
#
# They used to be Term's, read off `Term.TERM_THEME[].box`, so that a composer
# opened over a screen of `Term.Panel`s was bordered the way they were. That was
# one global read mid-render for five tables of glyphs, and it cost every host
# the whole of Term to have them.
#
# The *measuring* was never Term's, for two reasons that pull in opposite
# directions. `Panel` measures markup, so a title a host has already styled
# with raw SGR is counted as characters and the panel wraps a line that fits.
# And a buffer full of prose is *not* markup, so the braces in it are
# somebody's typing rather than a tag - which is the failure the other way
# round, and the more damaging of the two, because it silently deletes what was
# typed. So the rows are laid out here against real display widths, and in
# faces - see `rows.jl`.

"""
    BoxLine(left, mid, vertical, right)

One line of a [`Box`](@ref): the character at each end, the one that fills
between them, and the one where a column rule crosses it.
"""
struct BoxLine
    left::Char
    mid::Char
    vertical::Char
    right::Char
end
BoxLine(s::AbstractString) = BoxLine(collect(s)...)

"""
    Box(name, top, head, head_row, mid, row, foot_row, foot, bottom)
    Box(name, top, head, head_row, mid, row, bottom)
    Box(name, lines)

The characters of a box, a [`BoxLine`](@ref) for each kind of line in it:

    ╭─┬╮ top
    │ ││ head      the cells of a table's header
    ├─┼┤ head_row  the rule under the header
    │ ││ mid       every other line inside the box
    ├─┼┤ row       a rule between two rows of a table
    ├─┼┤ foot_row  the rule over a table's footer
    │ ││ foot      the cells of the footer
    ╰─┴╯ bottom

A widget's border uses `top`, `mid` and `bottom`; a table uses all eight. Given
six, the footer's two are the body's: `foot_row` is `row` and `foot` is `mid`.
`lines` is the same as a string, a line of four characters to each, six or
eight of them - a newline after the last is allowed, so a box can be written as
a block in triple quotes.
"""
struct Box
    name::Symbol
    top::BoxLine
    head::BoxLine
    head_row::BoxLine
    mid::BoxLine
    row::BoxLine
    foot_row::BoxLine
    foot::BoxLine
    bottom::BoxLine
end
Box(name::Symbol, top::BoxLine, head::BoxLine, head_row::BoxLine, mid::BoxLine,
    row::BoxLine, bottom::BoxLine) = Box(name, top, head, head_row, mid, row, row, mid, bottom)
function Box(name::Symbol, rows::AbstractString)
    ls = split(chomp(rows), '\n')
    length(ls) in (6, 8) ||
        throw(ArgumentError("a box is six or eight lines, not $(length(ls))"))
    Box(name, (BoxLine(r) for r in ls)...)
end

"""
    BOXES

The boxes there are, by name: `ROUNDED` (the default), `SQUARE`, `HEAVY`,
`DOUBLE`, and the ones a table is drawn in that do not look like a dialog -
`MINIMAL_HEAVY_HEAD`, no outer edge and a heavy rule under the header, and the
rest of the eighteen: `NONE` (spaces), `ASCII`, `ASCII2`, `ASCII_DOUBLE_HEAD`,
`SQUARE_DOUBLE_HEAD`, `MINIMAL`, `MINIMAL_DOUBLE_HEAD`, `SIMPLE`,
`SIMPLE_HEAD`, `SIMPLE_HEAVY`, `HORIZONTALS`, `HEAVY_EDGE`, `HEAVY_HEAD` and
`DOUBLE_EDGE`. The names and characters are Term's, so a theme written for
Term names the same box here.
"""
const BOXES = (
    NONE = Box(:NONE, "    \n    \n    \n    \n    \n    \n    \n    "),
    ASCII = Box(:ASCII, "+--+\n| ||\n|-+|\n| ||\n|-+|\n|-+|\n| ||\n+--+"),
    ASCII2 = Box(:ASCII2, "+-++\n| ||\n+-++\n| ||\n+-++\n+-++\n| ||\n+-++"),
    ASCII_DOUBLE_HEAD = Box(:ASCII_DOUBLE_HEAD,
        "+-++\n| ||\n+=++\n| ||\n+-++\n+-++\n| ||\n+-++"),
    SQUARE = Box(:SQUARE, "┌─┬┐\n│ ││\n├─┼┤\n│ ││\n├─┼┤\n├─┼┤\n│ ││\n└─┴┘"),
    SQUARE_DOUBLE_HEAD = Box(:SQUARE_DOUBLE_HEAD,
        "┌─┬┐\n│ ││\n╞═╪╡\n│ ││\n├─┼┤\n├─┼┤\n│ ││\n└─┴┘"),
    MINIMAL = Box(:MINIMAL, "  ╷ \n  │ \n╶─┼╴\n  │ \n╶─┼╴\n╶─┼╴\n  │ \n  ╵ "),
    MINIMAL_HEAVY_HEAD = Box(:MINIMAL_HEAVY_HEAD,
        "  ╷ \n  │ \n╺━┿╸\n  │ \n╶─┼╴\n╶─┼╴\n  │ \n  ╵ "),
    MINIMAL_DOUBLE_HEAD = Box(:MINIMAL_DOUBLE_HEAD,
        "  ╷ \n  │ \n ═╪ \n  │ \n ─┼ \n ─┼ \n  │ \n  ╵ "),
    SIMPLE = Box(:SIMPLE, "    \n    \n ── \n    \n    \n ── \n    \n    "),
    SIMPLE_HEAD = Box(:SIMPLE_HEAD, "    \n    \n ── \n    \n    \n    \n    \n    "),
    SIMPLE_HEAVY = Box(:SIMPLE_HEAVY, "    \n    \n ━━ \n    \n    \n ━━ \n    \n    "),
    HORIZONTALS = Box(:HORIZONTALS, " ── \n    \n ── \n    \n ── \n ── \n    \n ── "),
    ROUNDED = Box(:ROUNDED, "╭─┬╮\n│ ││\n├─┼┤\n│ ││\n├─┼┤\n├─┼┤\n│ ││\n╰─┴╯"),
    HEAVY = Box(:HEAVY, "┏━┳┓\n┃ ┃┃\n┣━╋┫\n┃ ┃┃\n┣━╋┫\n┣━╋┫\n┃ ┃┃\n┗━┻┛"),
    HEAVY_EDGE = Box(:HEAVY_EDGE, "┏━┯┓\n┃ │┃\n┠─┼┨\n┃ │┃\n┠─┼┨\n┠─┼┨\n┃ │┃\n┗━┷┛"),
    HEAVY_HEAD = Box(:HEAVY_HEAD, "┏━┳┓\n┃ ┃┃\n┡━╇┩\n│ ││\n├─┼┤\n├─┼┤\n│ ││\n└─┴┘"),
    DOUBLE = Box(:DOUBLE, "╔═╦╗\n║ ║║\n╠═╬╣\n║ ║║\n╠═╬╣\n╠═╬╣\n║ ║║\n╚═╩╝"),
    DOUBLE_EDGE = Box(:DOUBLE_EDGE, "╔═╤╗\n║ │║\n╟─┼╢\n║ │║\n╟─┼╢\n╟─┼╢\n║ │║\n╚═╧╝"),
)

"""
    boxstyle() -> Box
    boxstyle(name) -> Box

The box to draw with: `CHROME[].box`, or the one in [`BOXES`](@ref) called
`name`, and `ROUNDED` if there is none by that name - a widget that throws
because somebody named an unknown box is a worse answer than a widget with a
different corner. A host that wants to say the name was wrong asks
`haskey(BOXES, name)` first.
"""
boxstyle() = CHROME[].box
boxstyle(name::Symbol) = get(BOXES, name, BOXES.ROUNDED)
boxstyle(name::AbstractString) = boxstyle(Symbol(uppercase(name)))

"""
    CHROME[] = (strong = ..., quiet = ..., focus = ..., box = ...)

How the chrome of a widget is drawn, for a host to set: three kinds of
emphasis, each a StyledStrings `Face`, and the box.

They are a `Ref` because a host that has its own colours - a dashboard with a
theme file, say - has one place to say so rather than an argument to thread
through every widget it draws.

  * `strong` a title, and a border that has the keyboard
  * `quiet`  a border that does not, and the note and hint lines around it
  * `focus`  the option under the cursor in a `Choice`
  * `box`    the [`Box`](@ref) the border is drawn with, one of [`BOXES`](@ref)

The defaults are bold, light (which a terminal draws as dim), reverse video
and `ROUNDED`. Nothing ends them: a face ends only what it began. A host that
sets the three to `Face()` gets chrome with no escapes in it at all, which is
what a program drawing plain text wants and what a pipe wants.

Not in here: the block that marks where a cursor without the keys is - see
[`drawcursor`](@ref). Reverse video there is not emphasis, it is the only
thing saying where typing will go, and a host that turned its colours off would
otherwise lose it.
"""
const CHROME = Ref((strong = Face(weight = :bold), quiet = Face(weight = :light),
                    focus = Face(inverse = true), box = BOXES.ROUNDED))

"""
    DIALOG_WIDTH

The widest a dialog is drawn, however wide the screen: the default `maxwidth` of
a `LineInput`, a `Choice` and a `Confirm`, and of [`dialogbox`](@ref) itself.

Several widgets draw the same bordered box, and a box that is 76 columns wide in
one of them and 72 in the other is a box somebody has to keep in step by eye. A
`TextArea` is the one exception, and wider on purpose: it is somewhere to write
a paragraph, not a question to answer.
"""
const DIALOG_WIDTH = 76

"""
    dialogbox(w; width = DIALOG_WIDTH, box = boxstyle(), chrome = CHROME[]) -> NamedTuple

The box a widget is drawn in, on a screen `w` columns wide: how wide it is, and
the five kinds of row in it, each a [`Row`](@ref).

  * `head(title)`        the top edge with a title written into it
  * `top()`              the same edge with nothing in it, for a widget whose
                         title is a row of its own
  * `row(s, style = Face())` one line inside the box, in `style`, padded to the
                         full inner width - so a background in it is the width
                         of the box
  * `foot()`             the bottom edge
  * `hint(s)`            the dim line *under* the box, which is outside the
                         border because it is about the keys and not about the
                         question

`width` is the widest the box may be; it is narrower when the screen is. `box`
is the box style its characters come from, and `chrome` the weights it is
painted in. A line handed in keeps the faces it has, under the style.

The fields `bw`, `pad` and `iw` are the box's own width, the left margin that
centres it, and the columns available inside it. `chrome` is the weights it was
drawn with, for the `style` a caller gives its rows: a caller that takes them
from here rather than from `CHROME[]` paints the rows in what the border was.
"""
function dialogbox(w::Int; width::Int = DIALOG_WIDTH, box = boxstyle(), chrome = CHROME[])
    bw = min(w - 4, width)
    pad = (w - bw) ÷ 2
    iw = bw - 4
    D = chrome.quiet
    tl, tm, tr = box.top.left, box.top.mid, box.top.right
    ml, mr = box.mid.left, box.mid.right
    bl, bm, br = box.bottom.left, box.bottom.mid, box.bottom.right
    row(s, style::Face = NOSTYLE) =
        rowcat(" "^pad, faced(ml, D), " ", faced(rowpad(rowfit(s, iw), iw), style), " ",
               faced(mr, D))
    # `tl tm " "` + title + `" "` + bar + `tr` must total `bw`, so the filler is
    # `bw - 5 - |title|`.
    function head(t)
        tt = rowfit(t, iw - 2)
        rowcat(" "^pad, faced(string(tl, tm, " "), D), faced(tt, chrome.strong),
               faced(string(" ", string(tm)^max(0, bw - 5 - rowwidth(tt)), tr), D))
    end
    top() = rowcat(" "^pad, faced(string(tl, string(tm)^max(0, bw - 2), tr), D))
    foot() = rowcat(" "^pad, faced(string(bl, string(bm)^max(0, bw - 2), br), D))
    hint(s) = rowcat(" "^pad, faced(rowfit(s, bw), D))
    (bw = bw, pad = pad, iw = iw, chrome = chrome, row = row, head = head,
     top = top, foot = foot, hint = hint)
end

"""
    centred(out, w, h) -> Vector{Row}
    centred(out, w, nothing) -> Vector{Row}

Put a built box in the middle of the screen and pad it out to a whole frame:
`h` rows of exactly `w` display columns, which is the contract every `render`
here keeps. With `nothing` for `h`, the box at its own height - each row padded
to `w`, none added above or below - which is what `render(widget, w)` draws.
"""
function centred(out::AbstractVector, w::Int, h::Int)
    top = max(0, (h - length(out)) ÷ 2)
    rows = Row[rowpad("", w) for _ in 1:top]
    for l in out
        length(rows) < h || break
        push!(rows, rowpad(l, w))
    end
    while length(rows) < h; push!(rows, rowpad("", w)); end
    rows
end
centred(out::AbstractVector, w::Int, ::Nothing) = Row[rowpad(l, w) for l in out]

"""
    centredat(out, k, c, b, w, h) -> Union{Nothing, Tuple{Int,Int}}

Where row `k` of a built box, display column `c` inside box `b`, lands on the
screen [`centred`](@ref) puts it on: 1-based `(row, col)`, or `nothing` when
the box was cut short above it. `c` counts inside the border and its margin,
which is where every widget writes, as `b.row` lays it out. `h` is `nothing`
for a box at its own height.
"""
function centredat(out::AbstractVector, k::Int, c::Int, b, w::Int, h::Union{Nothing,Int})
    r = (h === nothing ? 0 : max(0, (h - length(out)) ÷ 2)) + k
    h === nothing || r <= h ? (r, clamp(b.pad + 2 + c, 1, w)) : nothing
end

"""How many blank rows `centred` puts above a box of `n` rows: none when the box
is drawn at its own height."""
blankabove(n::Int, h::Union{Nothing,Int}) = h === nothing ? 0 : max(0, (h - n) ÷ 2)

"""
    notetext(note) -> Row

What a widget says under its title, as one row with a newline between its
lines: a string as it is, or a vector of rows joined, the empty ones left out -
so a caller can write a row that only sometimes has something in it as `""`
rather than building the list conditionally. Every widget takes its `note` this
way, and a note keeps the faces it was given.
"""
notetext(s::AbstractString) = row(s)
function notetext(v::AbstractVector)
    rs = [row(r) for r in v if !isempty(r)]
    isempty(rs) ? row("") : rowcat(foldl((a, b) -> rowcat(a, "\n", b), rs))
end
