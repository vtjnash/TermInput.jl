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
# typed. So the rows are laid out here against real display widths - see
# `ansi.jl`.

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
    Box(name, top, head, head_row, mid, row, bottom)

The characters of a box, a [`BoxLine`](@ref) for each kind of line in it:

    ╭─┬╮ top
    │ ││ head      the cells of a table's header
    ├─┼┤ head_row  the rule under the header
    │ ││ mid       every other line inside the box
    ├─┼┤ row       a rule between two rows of a table
    ╰─┴╯ bottom

A widget's border uses `top`, `mid` and `bottom`; a table uses all six.
"""
struct Box
    name::Symbol
    top::BoxLine
    head::BoxLine
    head_row::BoxLine
    mid::BoxLine
    row::BoxLine
    bottom::BoxLine
end
Box(name::Symbol, rows::AbstractString) = Box(name, (BoxLine(r) for r in split(rows, '\n'))...)

"""
    BOXES

The boxes there are, by name: `ROUNDED` (the default), `SQUARE`, `HEAVY`,
`DOUBLE`, and `MINIMAL_HEAVY_HEAD` - no outer edge, a heavy rule under the
header, which is how a table reads when it is not meant to look like a
dialog. The names are Term's, so a theme written for Term names the same box
here.
"""
const BOXES = (
    ROUNDED = Box(:ROUNDED, "╭─┬╮\n│ ││\n├─┼┤\n│ ││\n├─┼┤\n╰─┴╯"),
    SQUARE = Box(:SQUARE, "┌─┬┐\n│ ││\n├─┼┤\n│ ││\n├─┼┤\n└─┴┘"),
    HEAVY = Box(:HEAVY, "┏━┳┓\n┃ ┃┃\n┣━╋┫\n┃ ┃┃\n┣━╋┫\n┗━┻┛"),
    DOUBLE = Box(:DOUBLE, "╔═╦╗\n║ ║║\n╠═╬╣\n║ ║║\n╠═╬╣\n╚═╩╝"),
    MINIMAL_HEAVY_HEAD = Box(:MINIMAL_HEAVY_HEAD, "  ╷ \n  │ \n╺━┿╸\n  │ \n╶─┼╴\n  ╵ "),
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
    CHROME[] = (strong = ..., quiet = ..., focus = ..., reset = ..., box = ...)

How the chrome of a widget is drawn, for a host to set: three kinds of
emphasis, what ends them, and the box.

They are a `Ref` because a host that has its own colours - a dashboard with a
theme file, say - has one place to say so rather than an argument to thread
through every widget it draws.

  * `strong` a title, and a border that has the keyboard
  * `quiet`  a border that does not, and the note and hint lines around it
  * `focus`  the option under the cursor in a `Choice`
  * `reset`  what ends any of them
  * `box`    the [`Box`](@ref) the border is drawn with, one of [`BOXES`](@ref)

The defaults are bold, dim, reverse video, a reset and `ROUNDED`. A host that
sets the four weights to `""` gets chrome with no escapes in it at all, which is
what a program drawing plain text wants and what a pipe wants.

Not in here: the block that marks where the cursor is in a `TextArea`. Reverse
video there is not emphasis, it is the only thing saying where typing will go,
and a host that turned its colours off would otherwise lose it.
"""
const CHROME = Ref((strong = "\e[1m", quiet = "\e[2m", focus = "\e[7m", reset = "\e[0m",
                    box = BOXES.ROUNDED))

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
the five kinds of row in it.

  * `head(title)`        the top edge with a title written into it
  * `top()`              the same edge with nothing in it, for a widget whose
                         title is a row of its own
  * `row(s, style = "")` one line inside the box, in `style`, padded to the full
                         inner width
  * `foot()`             the bottom edge
  * `hint(s)`            the dim line *under* the box, which is outside the
                         border because it is about the keys and not about the
                         question

`width` is the widest the box may be; it is narrower when the screen is. `box`
is the box style its characters come from, and `chrome` the weights it is
painted in.

The fields `bw`, `pad` and `iw` are the box's own width, the left margin that
centres it, and the columns available inside it. `chrome` is the weights it was
drawn with, for the `style` a caller gives its rows: a caller that takes them
from here rather than from `CHROME[]` paints the rows in what the border was.
"""
function dialogbox(w::Int; width::Int = DIALOG_WIDTH, box = boxstyle(), chrome = CHROME[])
    bw = min(w - 4, width)
    pad = (w - bw) ÷ 2
    iw = bw - 4
    D, R = chrome.quiet, chrome.reset
    tl, tm, tr = box.top.left, box.top.mid, box.top.right
    ml, mr = box.mid.left, box.mid.right
    bl, bm, br = box.bottom.left, box.bottom.mid, box.bottom.right
    row(s, style = "") = string(" "^pad, D, ml, R, " ", style,
                                apad(afit(s, iw), iw), R, " ", D, mr, R)
    # `tl tm " "` + title + `" "` + bar + `tr` must total `bw`, so the filler is
    # `bw - 5 - |title|`.
    head(t) = string(" "^pad, D, tl, tm, " ", R, chrome.strong, afit(t, iw - 2), R, D, " ",
                     string(tm)^max(0, bw - 5 - awidth(afit(String(t), iw - 2))), tr, R)
    top() = string(" "^pad, D, tl, string(tm)^max(0, bw - 2), tr, R)
    foot() = string(" "^pad, D, bl, string(bm)^max(0, bw - 2), br, R)
    hint(s) = string(" "^pad, D, afit(s, bw), R)
    (bw = bw, pad = pad, iw = iw, chrome = chrome, row = row, head = head,
     top = top, foot = foot, hint = hint)
end

"""
    centred(out, w, h) -> String

Put a built box in the middle of the screen and pad it out to a whole frame:
`h` rows of exactly `w` display columns, which is the contract every `render`
here keeps.
"""
function centred(out::Vector{String}, w::Int, h::Int)
    top = max(0, (h - length(out)) ÷ 2)
    all = vcat([" "^w for _ in 1:top], out)
    while length(all) < h; push!(all, " "^w); end
    join([apad(l, w) for l in all[1:h]], "\n")
end

"""
    notetext(note) -> String

What a widget says under its title, as one string with a row to each line: a
string as it is, or a vector of rows joined, the empty ones left out - so a
caller can write a row that only sometimes has something in it as `""` rather
than building the list conditionally. Every widget takes its `note` this way.
"""
notetext(s::AbstractString) = String(s)
notetext(v::AbstractVector) = join((String(r) for r in v if !isempty(r)), '\n')
