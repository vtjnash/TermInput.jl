# A table: cells of rows, laid out in columns and drawn in a box.
#
# What `markdown_rows` draws a `Markdown.Table` with, and what a host with a
# table of its own - a grid of values, or of other things it has drawn as rows -
# draws one with. The cells are rows already; this is only where they go:
# the columns' widths, each cell wrapped or cut to its column, padded and
# aligned in it, the cells of a row made as tall as its tallest, and the box's
# lines between and round them.

"The narrowest a column is made to fit a table in, unless it is narrower."
const TABLE_FLOOR = 4

"""Column widths for cells `nat` columns wide at their widest, in a table that
has `room` columns for its cells' text to fit in: each at its widest, and while
that is too wide, the widest narrowed a column at a time, down to
`TABLE_FLOOR`."""
function fitcolumns(nat::Vector{Int}, room::Int)
    cw = copy(nat)
    while sum(cw; init = 0) > room
        k = argmax(cw)
        cw[k] <= TABLE_FLOOR && break
        cw[k] -= 1
    end
    cw
end

"One setting for each of `n` columns (or rows): a vector as it is, or one value for all."
percol(x::AbstractVector, n::Int) = x
percol(x, n::Int) = fill(x, n)

"""A cell as its lines, and whether they are laid out already: a string cut at
its newlines, a vector as the rows it holds."""
celllines(x::AbstractVector) = (Row[row(r) for r in x], true)
celllines(x::Union{AbstractString,AbstractChar}) = (rowlines(row(x)), false)
celllines(x) = (rowlines(row(string(x))), false)

const Cellines = Tuple{Vector{Row},Bool}

"`s` aligned in `cw` columns: `:left`, `:center` (the odd space after) or `:right`."
function aligned(s::Row, cw::Int, align::Symbol)
    d = max(0, cw - rowwidth(s))
    a = first(String(align))
    a == 'r' ? rowcat(" "^d, s) :
    a == 'c' ? rowcat(" "^(d ÷ 2), s, " "^(d - d ÷ 2)) : rowcat(s, " "^d)
end

"""
    tablerows(cells, w = 0; header = nothing, footer = nothing, widths = nothing,
              justify = :left, valign = :top, pad = 1, vpad = 0, box = boxstyle(),
              rule = Face(), faces = Face(), header_faces = faces,
              footer_faces = faces, rules = :wrapped, wrap = true,
              top = true, bottom = true) -> Vector{Row}

`cells`, a matrix, as the rows of a table in `box`: a line of the box above,
its header, a rule, the body's rows, and its footer and the bottom line. A cell
is a string - its lines, wrapped to the column - or a vector of rows, laid out
already: what a host drew of something else, a table in a table, which is cut
to the column where it is wider and never re-wrapped. `header` and `footer` are
a cell for each column, or `nothing` for none.

  * `w`        the width to fit in, `0` for none: columns at their widest, and
               where that is too wide the widest narrowed first, down to four
               columns, and their cells wrapped
  * `widths`   the columns' widths inside their padding, a vector or one for
               all, instead of fitting them
  * `justify`  `:left`, `:center` or `:right`, a vector or one for all columns
  * `valign`   where a cell shorter than its row goes in it: `:top`,
               `:center` or `:bottom`
  * `pad`      spaces each side of a cell's text, a vector or one for all
  * `vpad`     blank lines added to each row's height, above and below as
               `valign` places the cell: one for all, or a vector in the order
               the rows are drawn, header first and footer last
  * `rule`     the face the box is drawn in
  * `faces`    the face of a body cell in each column, a vector or one for all,
               under the faces the cell has, over its padding too - so a
               background is the width of the column; `header_faces` and
               `footer_faces` the same for those rows. The blank lines that
               make a cell as tall as its row carry none
  * `rules`    which body rows a rule goes between: `:always`, `:never`, or
               `:wrapped`, every two when any body row is more than a line -
               where it takes one to tell them apart; or a vector with an entry
               for each two neighbours, `nothing` or the `BoxLine` drawn there
  * `wrap`     `false` cuts each line of a string to its column with
               [`rowfit`](@ref) rather than wrapping it
  * `top`, `bottom` whether the box's first and last lines are drawn

Every row is as wide as the table: the sum of its columns, their padding, and a
character between each two and at each end, which a box with no edge draws as
a space.
"""
tablerows(cells::AbstractMatrix, w::Int = 0; kw...) = first(tablelayout(cells, w; kw...))

"""The table and, for each of its rows, the table row it is a line of: `0` for
a rule, then `1`, `2`, … in the order they are drawn, header and footer
included."""
function tablelayout(cells::AbstractMatrix, w::Int = 0; header = nothing, footer = nothing,
                     widths = nothing, justify = :left, valign::Symbol = :top, pad = 1,
                     vpad = 0, box::Box = boxstyle(), rule::Face = NOSTYLE,
                     faces = NOSTYLE, header_faces = faces, footer_faces = faces,
                     rules = :wrapped, wrap::Bool = true, top::Bool = true,
                     bottom::Bool = true)
    nr, n = size(cells)
    body = [Cellines[celllines(cells[i, k]) for k in 1:n] for i in 1:nr]
    head = header === nothing ? nothing : Cellines[celllines(header[k]) for k in 1:n]
    foot = footer === nothing ? nothing : Cellines[celllines(footer[k]) for k in 1:n]
    pads = percol(pad, n)
    lines = vcat(head === nothing ? Vector{Cellines}[] : [head], body,
                 foot === nothing ? Vector{Cellines}[] : [foot])
    cw = if widths !== nothing
        collect(Int, percol(widths, n))
    else
        nat = Int[max(1, maximum((rowwidth(l) for r in lines for l in first(r[k])); init = 0))
                  for k in 1:n]
        w > 0 ? fitcolumns(nat, w - sum(2p + 1 for p in pads; init = 0) - 1) : nat
    end
    just = percol(justify, n)
    vpads = percol(vpad, length(lines))

    edge(l::BoxLine) = faced(string(l.left, join((string(l.mid)^(cw[k] + 2pads[k]) for k in 1:n),
                                                 l.vertical), l.right), rule)
    # A cell's lines in its column: wrapped or cut to it - cut, when they were
    # laid out already - and then aligned in it and padded.
    function fit(c::Cellines, k::Int)
        r, laid = c
        wrap && !laid ? Row[x for l in r for x in rowwrap(l, cw[k])] :
                        Row[rowwidth(l) <= cw[k] ? l : rowfit(l, cw[k]) for l in r]
    end
    out, origin = Row[], Int[]
    drawn = Ref(0)
    function line!(r::Vector{Cellines}, l::BoxLine, fs)
        d = drawn[] += 1
        laid = [fit(r[k], k) for k in 1:n]
        h = maximum(length, laid; init = 1) + 2 * vpads[d]
        fk = percol(fs, n)
        col = [rowvpad(Row[faced(rowcat(" "^pads[k], aligned(x, cw[k], just[k]), " "^pads[k]),
                                 fk[k]) for x in laid[k]],
                       cw[k] + 2pads[k], h, valign) for k in 1:n]
        for j in 1:h
            x = faced(string(l.left), rule)
            for k in 1:n
                x = rowcat(x, col[k][j], faced(string(k == n ? l.right : l.vertical), rule))
            end
            push!(out, x); push!(origin, d)
        end
        nothing
    end
    ruled!(l::BoxLine) = (push!(out, edge(l)); push!(origin, 0))

    top && ruled!(box.top)
    if head !== nothing
        line!(head, box.head, header_faces)
        ruled!(box.head_row)
    end
    gaps = if rules isa AbstractVector
        rules
    elseif rules === :always || (rules === :wrapped &&
                                 any(r -> any(k -> length(fit(r[k], k)) > 1, 1:n), body))
        fill(box.row, max(0, nr - 1))
    else
        fill(nothing, max(0, nr - 1))
    end
    for (i, r) in enumerate(body)
        i > 1 && (g = get(gaps, i - 1, nothing)) !== nothing && ruled!(g)
        line!(r, box.mid, faces)
    end
    if foot !== nothing
        ruled!(box.foot_row)
        line!(foot, box.foot, footer_faces)
    end
    bottom && ruled!(box.bottom)
    out, origin
end
