# Rows of faces: measuring, cutting and wrapping an annotated string.
#
# A row is an `AnnotatedString{String}`: its text, StyledStrings faces over
# ranges of it as `:face` annotations, a hyperlink as `:link`, and a piece that
# is somebody else's escapes as `:verbatim`. StyledStrings writes it, so
# nothing here writes an escape or ends one: a face ends only what it began,
# and slicing an annotated string keeps the annotations over what is kept.
#
# What is left for this file is the measure. The text's width is `textwidth`
# of it, except over a `:verbatim` range, which is text a terminal already
# laid out - a hosted program's row, say, as its multiplexer gave it, escapes
# and all - whose width is the value of the annotation and is never measured.
# Nothing here cuts or wraps inside one: a row that has to be cut through it is
# cut before it or after it.

import StyledStrings
import StyledStrings: Face

# The stdlib's from 1.11, and the package's on 1.10, where an annotation is
# still a pair rather than a named tuple, and where `*`, `join` and `rpad` of
# annotated strings give a `String`: here `rowcat` is the concatenation.
@static if isdefined(Base, :AnnotatedString)
    const AnnotatedString = Base.AnnotatedString
    const Annot = @NamedTuple{region::UnitRange{Int}, label::Symbol, value::Any}
    annot(r::UnitRange{Int}, label::Symbol, @nospecialize(value)) =
        Annot((r, label, value))
    annregion(a) = a.region
    annlabel(a) = a.label
    annvalue(a) = a.value
    const rowcat_ = Base.annotatedstring
else
    const AnnotatedString = StyledStrings.AnnotatedString
    const Annot = Tuple{UnitRange{Int},Pair{Symbol,Any}}
    annot(r::UnitRange{Int}, label::Symbol, @nospecialize(value)) =
        (r, Pair{Symbol,Any}(label, value))
    annregion(a) = a[1]
    annlabel(a) = first(a[2])
    annvalue(a) = last(a[2])
    const rowcat_ = StyledStrings.AnnotatedStrings.annotatedstring
end

"The last byte of a region, whichever way the region's end is counted."
lastbyte(str::AbstractString, r::UnitRange{Int}) = nextind(str, last(r)) - 1

"""
    Row

What a row is: `AnnotatedString{String}`, Base's from 1.11 and StyledStrings'
on 1.10.
"""
const Row = AnnotatedString{String}

"No style: the face that writes nothing."
const NOSTYLE = Face()

"The annotations of `s`, as a vector of this Julia's annotation type."
annots(s::AnnotatedString) = Annot[annot(annregion(a), annlabel(a), annvalue(a))
                                   for a in StyledStrings.annotations(s)]

"""
    row(s) -> Row

`s` as a row: an annotated string as it is, anything else as text with nothing
over it.
"""
row(s::Row) = s
row(s::AnnotatedString) = Row(String(s.string), annots(s))
row(s::SubString{<:AnnotatedString}) = row(AnnotatedString(s))
row(s::AbstractString) = Row(String(s), Annot[])
row(c::AbstractChar) = Row(string(c), Annot[])

"""
    rowcat(xs...) -> Row

The pieces one after another, each keeping its faces - what `*` is from 1.11,
and on 1.10 too, where `*` of an annotated string drops them.
"""
rowcat(xs::Union{AbstractString,AbstractChar}...) = row(rowcat_(xs...))

"""
    faced(s, face) -> Row

`s` drawn in `face`, under whatever faces it has already: a face inside the
string is merged over this one, so a bold word in a quiet row is quiet and bold.
The empty face adds nothing, and so writes nothing.
"""
function faced(s::Union{AbstractString,AbstractChar}, f::Face)
    r = row(s)
    (f == NOSTYLE || isempty(r.string)) && return r
    Row(r.string, vcat(Annot[annot(1:ncodeunits(r.string), :face, f)], annots(r)))
end

"""
    overlaid(s, range, face) -> Row

`face` merged *over* the faces already on `range` of `s`, a range of byte
indices - a selection or a search hit, which wins over the colour the row has
there. [`faced`](@ref) is the other way round, under what is there.
"""
function overlaid(s::AbstractString, r::UnitRange{Int}, f::Face)
    x = row(s)
    (f == NOSTYLE || isempty(r)) && return x
    Row(x.string, vcat(annots(x), Annot[annot(r, :face, f)]))
end

"""
    linked(s, url) -> Row

`s` as a hyperlink to `url`, which StyledStrings writes as OSC 8 around each
piece of it. An empty url is no link.
"""
function linked(s::AbstractString, url::AbstractString)
    r = row(s)
    (isempty(url) || isempty(r.string)) && return r
    Row(r.string, vcat(annots(r), Annot[annot(1:ncodeunits(r.string), :link, String(url))]))
end

"""
    verbatim(text, w) -> Row

`text` as a piece of a row that is drawn as it is and `w` columns wide: its
escapes are written untouched and its width is never measured. For a row that
something else laid out - a program's screen, as a multiplexer gave it. It
carries one annotation, `:verbatim => w`, and nothing else is laid over it.
"""
verbatim(text::AbstractString, w::Int) =
    Row(String(text), isempty(text) ? Annot[] : Annot[annot(1:ncodeunits(text), :verbatim, w)])

"The `:verbatim` ranges of `s` and their widths, in order."
function verbatims(s::AnnotatedString)
    out = Tuple{UnitRange{Int},Int}[]
    for a in StyledStrings.annotations(s)
        annlabel(a) === :verbatim &&
            push!(out, (first(annregion(a)):lastbyte(s.string, annregion(a)), annvalue(a)::Int))
    end
    sort!(out; by = first ∘ first)
end
verbatims(::AbstractString) = Tuple{UnitRange{Int},Int}[]

"""
    rowwidth(s) -> Int

The columns `s` prints in: `textwidth` of its text, and a `:verbatim` range
the width it says it is.
"""
rowwidth(s::AbstractString) = textwidth(s)
function rowwidth(s::AnnotatedString)
    vs = verbatims(s)
    str = s.string
    isempty(vs) && return textwidth(str)
    w, i = 0, 1
    for (r, vw) in vs
        first(r) > i && (w += textwidth(SubString(str, i, prevind(str, first(r)))))
        w += vw
        i = last(r) + 1
    end
    i <= ncodeunits(str) && (w += textwidth(SubString(str, i)))
    w
end

# --- cells ------------------------------------------------------------------

"""A piece of a row that is never split: a grapheme, or a verbatim range. Its
bytes, its columns, and whether it is a space a line may break at."""
struct Cell
    lo::Int
    hi::Int
    w::Int
    space::Bool
end

function cells(s::AbstractString)
    x = row(s)
    str = x.string
    vs = verbatims(x)
    out = Cell[]
    i, k, n = 1, 1, ncodeunits(str)
    while i <= n
        if k <= length(vs) && first(vs[k][1]) <= i
            r, vw = vs[k]
            push!(out, Cell(i, max(i, last(r)), vw, false))
            i = last(r) + 1; k += 1
            continue
        end
        stop = k <= length(vs) ? prevind(str, first(vs[k][1])) : n
        for g in Base.Unicode.graphemes(SubString(str, i, thisind(str, stop)))
            lo = g.offset + 1
            push!(out, Cell(lo, g.offset + ncodeunits(g), textwidth(g), g == " "))
        end
        i = nextind(str, thisind(str, stop))
    end
    out
end

"""Bytes `lo:hi` of `s` as a row of their own, keeping what is over them."""
function slice(s::Row, lo::Int, hi::Int)
    hi < lo && return Row("", Annot[])
    row(SubString(s, lo, thisind(s.string, hi)))
end
slice(s::Row, cs::Vector{Cell}, r::UnitRange{Int}) =
    isempty(r) ? Row("", Annot[]) : slice(s, cs[first(r)].lo, cs[last(r)].hi)

# --- cutting ----------------------------------------------------------------

"""
    rowhead(s, w) -> Row

The columns of `s` from the front that fit in `w`, never splitting a wide
character, a grapheme or a verbatim piece.
"""
function rowhead(s::AbstractString, w::Int)
    x, cs = row(s), cells(s)
    acc, k = 0, 0
    while k < length(cs) && acc + cs[k+1].w <= w
        k += 1; acc += cs[k].w
    end
    slice(x, cs, 1:k)
end

"""
    rowtail(s, w) -> Row

The columns of `s` from the back that fit in `w`, by the same rule.
"""
function rowtail(s::AbstractString, w::Int)
    x, cs = row(s), cells(s)
    acc, k = 0, length(cs) + 1
    while k > 1 && acc + cs[k-1].w <= w
        k -= 1; acc += cs[k].w
    end
    slice(x, cs, k:length(cs))
end

"""The mark of a cut, in the faces over byte `at` of `s` - so a bold title
cut short ends in a bold `…`."""
function ellipsis(s::Row, at::Int)
    anns = Annot[annot(1:3, annlabel(a), annvalue(a)) for a in annots(s)
                 if at in annregion(a) && annlabel(a) !== :verbatim]
    Row("…", anns)
end

"""
    rowfit(s, w) -> Row

`s` cut to `w` columns, with a `…` at the cut in the faces it was cut through;
as it is when it fits. A verbatim piece that does not fit whole is cut before.
"""
function rowfit(s::AbstractString, w::Int)
    x = row(s)
    w <= 0 && return Row("", Annot[])
    rowwidth(x) <= w && return x
    head = rowhead(x, w - 1)
    rowcat(head, ellipsis(x, ncodeunits(head.string) + 1))
end

"""
    rowpad(s, w) -> Row

`s` padded with spaces, which carry no face, to exactly `w` columns - or cut to
them with [`rowfit`](@ref).
"""
function rowpad(s::AbstractString, w::Int)
    x = row(s)
    d = w - rowwidth(x)
    d > 0 ? rowcat(x, " "^d) : d == 0 ? x : rowfit(x, w)
end

"""
    rowmid(s, w) -> Row

`s` fitted to `w` columns by eliding in the *middle*, two thirds of the room
to the head and one third to the tail.

Names in a fixed column agree at the front and differ at the end far more often
than the other way round: branches under one owner prefix, worktrees of one
repo, urls into one issue. Cut at the tail, a pair like that draws as the *same
string* twice, which tells the reader nothing about which is which - and in a
list whose whole job is telling two copies of something apart, that is the one
failure that matters. `users/vtjnash/tsa-tryheld-state` and
`users/vtjnash/tsa-tryheld-other` in twenty-six columns were both
`users/vtjnash/tsa-tryheld…`.
"""
function rowmid(s::AbstractString, w::Int)
    x = row(s)
    w <= 0 && return Row("", Annot[])
    rowwidth(x) <= w && return x
    # Below three columns there is no room for a head, a mark and a tail, and
    # the arithmetic below would spend `w - 1` on each end and come back one
    # column too wide. Nothing useful can be said in two columns anyway.
    w == 1 && return Row("…", Annot[])
    w == 2 && return rowcat(rowhead(x, 1), "…")
    keep = w - 1                       # what is left once the mark is paid for
    head = max(1, (2 * keep) ÷ 3)
    rowcat(rowhead(x, head), "…", rowtail(x, keep - head))
end

# --- wrapping ---------------------------------------------------------------

"""
    wrapspans(widths, spaces, w; hard = false) -> Vector{UnitRange{Int}}

Where a line of pieces `widths` wide breaks into rows `w` columns wide, as the
ranges of pieces on each row: at the last space that fits, or, where there is
none - a url, a long identifier, or `hard`, for text that is never reflowed -
at the last piece that fits. A space a row is broken at is on neither row, and
a row never starts with the spaces a soft break left. A piece wider than `w`
is a row of its own. Always at least one row.
"""
function wrapspans(gw::AbstractVector{Int}, sp::AbstractVector{Bool}, w::Int;
                   hard::Bool = false)
    n = length(gw)
    spans = UnitRange{Int}[]
    rs, col, bp = 1, 0, 0                # row start, its width, a space in it
    i = 1
    while i <= n
        if col + gw[i] > w && i > rs
            !hard && sp[i] && (bp = i)   # a word that ends at the edge
            if !hard && bp > rs
                push!(spans, rs:bp-1)
                rs = bp + 1
                while rs <= n && sp[rs]  # the spaces the break left
                    rs += 1
                end
                i = max(i, rs)
                col = sum(@view(gw[rs:i-1]); init = 0)
            else
                push!(spans, rs:i-1)
                rs = i; col = 0
            end
            bp = 0
            continue
        end
        sp[i] && (bp = i)
        col += gw[i]
        i += 1
    end
    (rs <= n || isempty(spans)) && push!(spans, rs:n)
    spans
end

"""
    rowwrap(s, w; hard = false) -> Vector{Row}

`s` wrapped to rows of at most `w` columns, each keeping the faces over what is
on it - so a face that spans the break is on both rows, and each row closes it.
The break is at the last space that fits, dropped, or where there is none - or
with `hard` - at the last grapheme that fits. A verbatim piece is never split.
One paragraph: a newline in `s` is a character like any other, and
[`rowwraplines`](@ref) is for text with lines in it.
"""
function rowwrap(s::AbstractString, w::Int; hard::Bool = false)
    x, cs = row(s), cells(s)
    w <= 0 && return Row[x]
    Row[slice(x, cs, sp) for sp in
        wrapspans(Int[c.w for c in cs], Bool[c.space for c in cs], w; hard)]
end

"""
    rowlines(s) -> Vector{Row}

`s` cut at each newline, each line keeping its faces, the newlines on none.
"""
function rowlines(s::AbstractString)
    x = row(s)
    str = x.string
    out, i = Row[], 1
    while true
        j = findnext('\n', str, i)
        j === nothing && (push!(out, slice(x, i, ncodeunits(str))); break)
        push!(out, slice(x, i, j - 1))
        i = j + 1
    end
    out
end

"""
    rowwraplines(s, w) -> Vector{Row}

The rows of a note in a box `w` wide: each of its lines, wrapped.
"""
rowwraplines(s::AbstractString, w::Int) = Row[r for l in rowlines(s) for r in rowwrap(l, w)]
