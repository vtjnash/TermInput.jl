# The box a widget is drawn in.
#
# This is where the package is a Term plugin rather than a text editor: the
# characters come from Term's own box vocabulary and default to the box the
# current theme uses, so a text area opened over a screen full of `Term.Panel`s
# is bordered the way they are - change `TERM_THEME[].box` and all of it
# follows.
#
# What does not come from Term is the *measuring*, for two reasons that pull in
# opposite directions. `Panel` measures markup, so a title a host has already
# styled with raw SGR is counted as characters and the panel wraps a line that
# fits. And a buffer full of prose is *not* markup, so the braces in it are
# somebody's typing rather than a tag - which is the failure the other way
# round, and the more damaging of the two, because it silently deletes what was
# typed. So the rows are laid out here against real display widths - see
# `ansi.jl` - and Term supplies the glyphs.

import Term
import Term.Boxes: BOXES

"""The box style to draw with, following Term's theme unless told otherwise.

The theme's box name, or `ROUNDED` if it names one that is not there - a widget
that throws because somebody set an unknown box is a worse answer than a widget
with a different corner.
"""
boxstyle() = get(BOXES, Term.TERM_THEME[].box, BOXES.ROUNDED)

"""
    dialogbox(w; width = 76, box = boxstyle()) -> NamedTuple

The box a widget is drawn in: how wide it is, and the five kinds of row in it.

Several widgets draw the same bordered box, and a box that is 76 columns wide
in one of them and 72 in the other is a box somebody has to keep in step by eye.

  * `head(title)` the top edge with a title written into it
  * `top()`       the same edge with nothing in it, for a widget whose title is
                  a row of its own
  * `row(s, sgr)` one line inside the box, padded to the full inner width
  * `foot()`      the bottom edge
  * `hint(s)`     the dim line *under* the box, which is outside the border
                  because it is about the keys and not about the question

`width` is the widest the box may be; it is narrower when the screen is. The
fields `box`, `pad` and `iw` are the box's own width, the left margin that
centres it, and the columns available inside it.
"""
function dialogbox(w::Int; width::Int = 76, box = boxstyle())
    bw = min(w - 4, width)
    pad = (w - bw) ÷ 2
    iw = bw - 4
    D, R = "\e[2m", "\e[0m"
    tl, tm, tr = box.top.left, box.top.mid, box.top.right
    ml, mr = box.mid.left, box.mid.right
    bl, bm, br = box.bottom.left, box.bottom.mid, box.bottom.right
    row(s, style = "") = string(" "^pad, D, ml, R, " ", style,
                                apad(afit(s, iw), iw), R, " ", D, mr, R)
    # `tl tm " "` + title + `" "` + bar + `tr` must total `bw`, so the filler is
    # `bw - 5 - |title|`.
    head(t) = string(" "^pad, D, tl, tm, " ", R, "\e[1m", afit(t, iw - 2), R, D, " ",
                     string(tm)^max(0, bw - 5 - awidth(afit(String(t), iw - 2))), tr, R)
    top() = string(" "^pad, D, tl, string(tm)^max(0, bw - 2), tr, R)
    foot() = string(" "^pad, D, bl, string(bm)^max(0, bw - 2), br, R)
    hint(s) = string(" "^pad, D, afit(s, bw), R)
    (box = bw, pad = pad, iw = iw, row = row, head = head, top = top,
     foot = foot, hint = hint)
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
