# Markdown, drawn as rows of exactly `w` columns.
#
# From the stdlib's parse tree, never from text: the host parses, with whatever
# flavor it wants, and hands over a `Markdown.MD`. Each block is turned into
# lines of *runs* - a piece of text and the styles it is drawn in - and each
# line is wrapped here, where it is known which row came from which line. That
# is the whole of the source map: `src` is the line's text before the wrap, so
# a host that copies rows back out gets the lines as they were written without
# rendering a second time to find them.
#
# A style is a StyledStrings `Face`, and a piece of a row is drawn in its styles
# merged, outermost first. A row is handed to StyledStrings to write, which
# knows what each face turns on and so writes only what changes from one piece
# to the next, and closes everything at the end of the row: the padding is
# never painted, and a span that wraps is closed on one row and opened again on
# the next with no state carried between them. An empty face writes nothing.
#
# The break is `rowwrap`'s, `wrapspans`: the greedy break at the last space, and
# a word wider than the row split by columns, with graphemes kept whole. Only
# the pieces differ - runs here, which are styled when the row is emitted.

import Markdown
import StyledStrings
import StyledStrings: Face

"""
    MarkdownStyle(; h1, …, faces)

The faces markdown is drawn in, a StyledStrings `Face` per thing that is
styled, and every one empty by default - so `MarkdownStyle()` draws with no
escapes at all. A style inside another is merged over it, so a bold word in a
link is the link's underline and bold both.

  * `h1` … `h6`          a heading, by level: nothing else carries the level
  * `bold`, `italic`, `strike`
  * `code`, `code_tick`  a code span, and its backticks inside it
  * `codeblock`          a code block, padded to the width so it reads as one
  * `link`               a link's label, and an image's alt text
  * `blockquote`         the bar down a block quote's left
  * `note`, `tip`, `warning`, `danger`, `info`
                         an admonition's bar and title, by category; any other
                         category is drawn as `note`
  * `table_head`, `table_rule`
                         a table's header cells, and its box
  * `rule`               a horizontal rule
  * `latex`, `footnote`, `html`
                         what the terminal can only show the source of
  * `box`                the [`Box`](@ref) a table is drawn with
  * `faces`              a highlighter's faces, by name - see [`highlight`](@ref)

Passed to each render rather than held globally, so a render depends on nothing
but its arguments: a host with a theme builds one when the theme changes. The
faces are used as they are, never looked up by name in StyledStrings' own
table; a face's `inherit` would be, so a host leaves it empty.
"""
Base.@kwdef struct MarkdownStyle
    h1::Face = NOSTYLE
    h2::Face = NOSTYLE
    h3::Face = NOSTYLE
    h4::Face = NOSTYLE
    h5::Face = NOSTYLE
    h6::Face = NOSTYLE
    bold::Face = NOSTYLE
    italic::Face = NOSTYLE
    strike::Face = NOSTYLE
    code::Face = NOSTYLE
    code_tick::Face = NOSTYLE
    codeblock::Face = NOSTYLE
    link::Face = NOSTYLE
    blockquote::Face = NOSTYLE
    note::Face = NOSTYLE
    tip::Face = NOSTYLE
    warning::Face = NOSTYLE
    danger::Face = NOSTYLE
    info::Face = NOSTYLE
    table_head::Face = NOSTYLE
    table_rule::Face = NOSTYLE
    rule::Face = NOSTYLE
    latex::Face = NOSTYLE
    footnote::Face = NOSTYLE
    html::Face = NOSTYLE
    box::Box = BOXES.ROUNDED
    faces::Dict{Symbol,Face} = Dict{Symbol,Face}()
end

"""
    MDRow(text, src, first)

One row of rendered markdown. `text` is what prints: exactly the width asked
for, escapes inline. `src` is the line it came from as it was written, with no
escapes and nothing wrapped, and `first` says whether this row is where that
line starts - so the rows of a paragraph wrapped over three are one `src`, and
`first` on the first. A copy of a range of rows is the `src` of each row that
is `first`, or of the first row in the range.
"""
struct MDRow
    text::String
    src::String
    first::Bool
end

"""
    highlight(mime::MIME, code) -> Vector{Tuple{UnitRange{Int},Symbol}}
    highlight(lang::AbstractString, code)

Byte ranges of `code` and the face each is drawn in, for a code block of type
`mime`. The face is looked up in a [`MarkdownStyle`](@ref)'s `faces`.

A language is a type, so a highlighter is a method on its own `MIME`, and one
never replaces another: Julia's own answers `MIME"text/julia"` from 1.12,
through an extension on `JuliaSyntaxHighlighting`, which `Markdown` loads there,
and a host that wants another language adds `highlight(::MIME"text/python",
code::AbstractString)`, say. Every other type is this stub's: no ranges, so the
block is drawn in `codeblock` alone.

Given a fence's language, `highlight` asks the type [`codemime`](@ref) names.
"""
highlight(::MIME, code::AbstractString) = Tuple{UnitRange{Int},Symbol}[]
highlight(lang::AbstractString, code::AbstractString) = highlight(codemime(lang), code)

"""The fence languages read as Julia. An empty one is too: an unlabelled block
in a Julia project's comments is Julia far more often than not, and one that
is not costs only colour."""
const JULIA_FENCES = ("julia", "jl", "jldoctest", "")

"""
    codemime(lang) -> MIME

The type of a code block whose fence says `lang`: `text/julia` for `julia`,
`jl`, `jldoctest` or nothing at all, and `text/` and the language, lowercased,
for anything else - `python` is `text/python`. Not the registered types: the
fence's word is all there is to go on, and the type only picks a method.
"""
function codemime(lang::AbstractString)
    l = lowercase(strip(lang))
    l in JULIA_FENCES ? MIME"text/julia"() : MIME("text/" * l)
end

"""Where a face with no style of its own looks next: a delimiter as what it
delimits, every bracket as `parentheses`, and the narrower kinds of operator as
the wider."""
const FACE_FALLBACK = Dict{Symbol,Symbol}(
    :string_delim => :string, :char_delim => :char, :char => :string,
    :cmd_delim => :cmd, :backslash_literal => :string, :regex => :string,
    :opassignment => :assignment, :assignment => :operator,
    :comparator => :operator, :broadcast => :operator,
    :typedec => :type, :bool => :number, :unpaired_parentheses => :parentheses)

function facestyle(st::MarkdownStyle, face::Symbol)
    for _ in 1:8                        # the chains above are short; no cycles
        s = get(st.faces, face, nothing)
        s === nothing || return s
        if startswith(String(face), "rainbow_")
            face = :parentheses
        else
            next = get(FACE_FALLBACK, face, nothing)
            next === nothing && return NOSTYLE
            face = next
        end
    end
    NOSTYLE
end

# --- runs -------------------------------------------------------------------

"A piece of text and the styles it is in, outermost first."
struct Run
    text::String
    styles::Vector{Face}
end

const Line = Vector{Run}

"""A row of runs as the string that prints it: each run in its styles merged,
written by StyledStrings, which writes only what differs between neighbours -
so a code span is one background with its backticks dimmed inside it, not
three - and turns off whatever a close took with it that is still wanted.
Nothing is open at the end of the row."""
function emit(line::Line)
    anns = Annot[]
    io = IOBuffer()
    for r in line
        isempty(r.text) && continue
        i = position(io)
        write(io, r.text)
        isempty(r.styles) ||
            push!(anns, annot(i+1:position(io), :face, foldl(merge, r.styles)))
    end
    text = String(take!(io))
    isempty(anns) && return text
    print(IOContext(io, :color => true), Row(text, anns))
    String(take!(io))
end

plaintext(line::Line) = join(r.text for r in line)
runwidth(line::Line) = sum((awidth(r.text) for r in line); init = 0)

"""Wrap a line of runs to rows `w` columns wide: at the last space that fits,
or, where there is none - a url, a long identifier, or `hard` for code, which
is never reflowed - at the last grapheme that fits. A space a row is broken at
is dropped, and a row never starts with the spaces a soft break left."""
function wraprun(line::Line, w::Int; hard::Bool = false)
    gs, gw, gr = String[], Int[], Int[]
    for (k, r) in enumerate(line), g in Base.Unicode.graphemes(r.text)
        push!(gs, String(g)); push!(gw, textwidth(g)); push!(gr, k)
    end
    spans = wrapspans(gw, Bool[g == " " for g in gs], w; hard)
    rows = Line[]
    for sp in spans
        row = Run[]
        k, buf = 0, IOBuffer()
        for j in sp
            if gr[j] != k
                k == 0 || push!(row, Run(String(take!(buf)), line[k].styles))
                k = gr[j]
            end
            write(buf, gs[j])
        end
        k == 0 || push!(row, Run(String(take!(buf)), line[k].styles))
        push!(rows, row)
    end
    rows
end

# --- inline -----------------------------------------------------------------

"What a block's inline content is drawn with, and whether a newline breaks."
struct Ctx
    st::MarkdownStyle
    breaks::Bool
end

with(stack::Vector{Face}, s::Face) = s == NOSTYLE ? stack : vcat(stack, [s])

"Inline content as lines of runs: more than one where it has a line break."
function inlines(xs, ctx::Ctx, stack::Vector{Face} = Face[])
    lines = Line[Run[]]
    inline!(lines, xs, ctx, stack)
    lines
end

inline!(lines::Vector{Line}, xs::AbstractVector, ctx::Ctx, stack) =
    (for x in xs; inline!(lines, x, ctx, stack); end; nothing)

addrun!(lines::Vector{Line}, s::AbstractString, stack) =
    (isempty(s) || push!(lines[end], Run(String(s), stack)); nothing)

"""Text, where a newline is a line break when `breaks` asks for one or the line
ends in two spaces or a backslash, and a space otherwise. The indent of the
line after a break is not part of what was written."""
function inline!(lines::Vector{Line}, s::AbstractString, ctx::Ctx, stack)
    pieces = split(s, '\n')
    for (k, p) in enumerate(pieces)
        p = String(p)
        k > 1 && (p = lstrip(p))
        if k < length(pieces)
            hard = ctx.breaks || endswith(p, "  ") || endswith(p, "\\")
            if hard
                addrun!(lines, rstrip(endswith(p, "\\") ? chop(p) : p), stack)
                push!(lines, Run[])
            else
                addrun!(lines, string(rstrip(p), " "), stack)
            end
        else
            addrun!(lines, p, stack)
        end
    end
    nothing
end

inline!(lines::Vector{Line}, x::Markdown.Bold, ctx::Ctx, stack) =
    inline!(lines, x.text, ctx, with(stack, ctx.st.bold))
inline!(lines::Vector{Line}, x::Markdown.Italic, ctx::Ctx, stack) =
    inline!(lines, x.text, ctx, with(stack, ctx.st.italic))
inline!(lines::Vector{Line}, x::Markdown.Link, ctx::Ctx, stack) =
    inline!(lines, x.text, ctx, with(stack, ctx.st.link))
inline!(lines::Vector{Line}, x::Markdown.Image, ctx::Ctx, stack) =
    addrun!(lines, x.alt, with(stack, ctx.st.link))
inline!(lines::Vector{Line}, ::Markdown.LineBreak, ctx::Ctx, stack) =
    (push!(lines, Run[]); nothing)
inline!(lines::Vector{Line}, x::Markdown.LaTeX, ctx::Ctx, stack) =
    addrun!(lines, string('$', x.formula, '$'), with(stack, ctx.st.latex))
@static if isdefined(Markdown, :Strikethrough)
    inline!(lines::Vector{Line}, x::Markdown.Strikethrough, ctx::Ctx, stack) =
        inline!(lines, x.text, ctx, with(stack, ctx.st.strike))
end
@static if isdefined(Markdown, :HTMLInline)
    inline!(lines::Vector{Line}, x::Markdown.HTMLInline, ctx::Ctx, stack) =
        addrun!(lines, x.content, with(stack, ctx.st.html))
end
inline!(lines::Vector{Line}, x::Markdown.Footnote, ctx::Ctx, stack) =
    addrun!(lines, string("[^", x.id, "]"), with(stack, ctx.st.footnote))

"""A code span keeps its backticks - they are part of what a copy produces -
and as many of them as it takes to hold one written inside it."""
function inline!(lines::Vector{Line}, x::Markdown.Code, ctx::Ctx, stack)
    code = replace(x.code, '\n' => ' ')
    longest = maximum((length(m.match) for m in eachmatch(r"`+", code)); init = 0)
    tick = "`"^(longest + 1)
    pad = startswith(code, '`') || endswith(code, '`') ? " " : ""
    inner = with(stack, ctx.st.code)
    addrun!(lines, tick, with(inner, ctx.st.code_tick))
    addrun!(lines, string(pad, code, pad), inner)
    addrun!(lines, tick, with(inner, ctx.st.code_tick))
    nothing
end

"Anything else - an element a later Julia adds - as its plain text, unstyled."
function inline!(lines::Vector{Line}, x, ctx::Ctx, stack)
    s = try
        sprint(Markdown.plaininline, x)
    catch
        string(x)
    end
    inline!(lines, s, ctx, stack)
end

# --- blocks -----------------------------------------------------------------

"""Rows of a line of runs wrapped at `w`, each padded to it: the line's text
is every row's `src`, and the first row is its `first`."""
function wrapped!(out::Vector{MDRow}, line::Line, w::Int; hard::Bool = false,
                  src::String = String(rstrip(plaintext(line))))
    for (k, row) in enumerate(wraprun(line, w; hard))
        push!(out, MDRow(apad(emit(row), w), src, k == 1))
    end
    out
end

blank(w::Int) = MDRow(" "^max(w, 0), "", true)

"""Blocks in order, a blank row between each two when `loose` - which every
run of blocks is but the items of a tight list."""
function blocks!(out::Vector{MDRow}, xs::AbstractVector, w::Int, ctx::Ctx; loose::Bool = true)
    started = false
    for x in xs
        rows = block!(MDRow[], x, w, ctx)
        isempty(rows) && continue
        started && loose && push!(out, blank(w))
        append!(out, rows)
        started = true
    end
    out
end

"""The rows of a block drawn `pw` columns in from the left: the first behind
`first`, the rest behind `rest`, and a row's `src` the line it starts behind
the prefix it starts behind - what a copy of that line would have in it."""
function prefixed!(out::Vector{MDRow}, rows::Vector{MDRow}, first::String, rest::String)
    src = ""
    for (k, r) in enumerate(rows)
        p = k == 1 ? first : rest
        r.first && (src = String(rstrip(string(astrip(p), r.src))))
        push!(out, MDRow(string(p, r.text), src, r.first))
    end
    out
end

styled(s::AbstractString, st::Face) = emit(Run[Run(s, with(Face[], st))])

block!(out::Vector{MDRow}, md::Markdown.MD, w::Int, ctx::Ctx) = blocks!(out, md.content, w, ctx)

function block!(out::Vector{MDRow}, p::Markdown.Paragraph, w::Int, ctx::Ctx)
    for line in inlines(p.content, ctx)
        wrapped!(out, line, w)
    end
    out
end

function block!(out::Vector{MDRow}, h::Markdown.Header{l}, w::Int, ctx::Ctx) where {l}
    st = (ctx.st.h1, ctx.st.h2, ctx.st.h3, ctx.st.h4, ctx.st.h5, ctx.st.h6)[clamp(l, 1, 6)]
    for line in inlines(h.text, ctx, with(Face[], st))
        wrapped!(out, line, w)
    end
    out
end

block!(out::Vector{MDRow}, ::Markdown.HorizontalRule, w::Int, ctx::Ctx) =
    push!(out, MDRow(styled("─"^max(w, 0), ctx.st.rule), "---", true))

"""A tab as the spaces to the next stop of eight columns, counted from `col`:
what a terminal would do with it, and what nothing downstream can do once it
is inside a row."""
function detab!(io::IO, s::AbstractString, col::Int)
    for c in s
        if c == '\t'
            k = 8 - col % 8
            write(io, " "^k); col += k
        else
            write(io, c); col += textwidth(c)
        end
    end
    col
end

"""The lines of a code block as runs: `base` round everything, and a face
inside it wherever the highlighter gave one; with `tabs`, a tab drawn as its
columns. Each line comes with its source."""
function codelines(code::String, lang::AbstractString, st::MarkdownStyle,
                   base::Vector{Face}; tabs::Bool = true)
    face = fill(:none, ncodeunits(code))
    for (r, f) in highlight(lang, code)
        for b in r
            checkbounds(Bool, face, b) && (face[b] = f)
        end
    end
    lines, srcs = Line[], String[]
    line, col, i = Run[], 0, firstindex(code)
    lstart = i
    while i <= ncodeunits(code)
        c = code[i]
        if c == '\n'
            push!(lines, line); push!(srcs, code[lstart:prevind(code, i)])
            line, col = Run[], 0
            i += 1; lstart = i
            continue
        end
        f = face[i]
        j = i
        while j <= ncodeunits(code) && code[j] != '\n' && face[j] == f
            j = nextind(code, j)
        end
        piece = SubString(code, i, prevind(code, j))
        if tabs
            io = IOBuffer()
            col = detab!(io, piece, col)
            piece = String(take!(io))
        end
        push!(line, Run(String(piece), f === :none ? base : with(base, facestyle(st, f))))
        i = j
    end
    push!(lines, line); push!(srcs, code[lstart:end])
    lines, srcs
end

"""A code block: two in, no border, and the background padded to the width so
the block reads as one. Its lines are cut where they reach the edge, never
reflowed, since where a line of code breaks is part of what it says."""
function block!(out::Vector{MDRow}, c::Markdown.Code, w::Int, ctx::Ctx)
    cb = ctx.st.codeblock
    inner = max(1, w - 3)
    lines, srcs = codelines(c.code, c.language, ctx.st, with(Face[], cb))
    for (line, src) in zip(lines, srcs)
        for (k, row) in enumerate(wraprun(line, inner; hard = true))
            fill = max(0, inner - runwidth(row))
            base = with(Face[], cb)
            text = string("  ", emit(vcat(Run(" ", base), row, Run(" "^fill, base))))
            push!(out, MDRow(apad(text, w), rstrip(src), k == 1))
        end
    end
    out
end

"""A list: `•`, or the number right-aligned to the widest one, and the item
hung beside it - so a list inside it is indented by the width of its marker.
A loose list has a blank row between items; a tight one has none, even between
the blocks of one item.

Loose is taken from the tree only when an item has more than one block in it:
the stdlib marks a list loose when a blank line follows it, which is every list
with a paragraph after it, and that list is tight where GitHub draws it."""
function block!(out::Vector{MDRow}, l::Markdown.List, w::Int, ctx::Ctx)
    ordered = l.ordered >= 0
    top = l.ordered + length(l.items) - 1
    nw = ordered ? max(ndigits(max(l.ordered, 0)), ndigits(max(top, 0))) : 0
    loose = l.loose && any(item -> length(item) > 1, l.items)
    for (k, item) in enumerate(l.items)
        marker = ordered ? string(lpad(string(l.ordered + k - 1), nw), ". ") : "• "
        mw = awidth(marker)
        rows = blocks!(MDRow[], item, max(1, w - mw), ctx; loose)
        isempty(rows) && push!(rows, blank(max(1, w - mw)))
        k > 1 && loose && push!(out, blank(w))
        prefixed!(out, rows, marker, " "^mw)
    end
    out
end

"""A block quote: a bar down its left in `blockquote`, and what it quotes
drawn two narrower beside it."""
function block!(out::Vector{MDRow}, q::Markdown.BlockQuote, w::Int, ctx::Ctx)
    bar = styled("│ ", ctx.st.blockquote)
    rows = blocks!(MDRow[], q.content, max(1, w - 2), ctx)
    isempty(rows) && push!(rows, blank(max(1, w - 2)))
    prefixed!(out, rows, bar, bar)
end

"The style an admonition of `category` is drawn in: its own, or `note`'s."
function admonitionstyle(st::MarkdownStyle, category::AbstractString)
    c = lowercase(category)
    c == "tip" ? st.tip : c == "warning" ? st.warning : c == "danger" ? st.danger :
    c == "info" ? st.info : st.note
end

"""An admonition: a quote whose bar and title are in the category's style,
and the title the category itself when none was written."""
function block!(out::Vector{MDRow}, a::Markdown.Admonition, w::Int, ctx::Ctx)
    st = admonitionstyle(ctx.st, a.category)
    bar = styled("│ ", st)
    title = isempty(a.title) ? uppercasefirst(a.category) : a.title
    rows = wrapped!(MDRow[], Run[Run(title, with(Face[], st))], max(1, w - 2))
    body = blocks!(MDRow[], a.content, max(1, w - 2), ctx)
    isempty(body) || append!(rows, body)
    prefixed!(out, rows, bar, bar)
end

"""A footnote's definition, as a paragraph led by its reference. Its reference
in the text is an inline one, drawn as `[^id]` where it was written."""
function block!(out::Vector{MDRow}, f::Markdown.Footnote, w::Int, ctx::Ctx)
    lead = Run(string("[^", f.id, "]:"), with(Face[], ctx.st.footnote))
    content = f.text === nothing ? Any[] : f.text
    if !isempty(content) && first(content) isa Markdown.Paragraph
        lines = inlines(first(content).content, ctx)
        pushfirst!(lines[1], lead, Run(" ", Face[]))
        for line in lines
            wrapped!(out, line, w)
        end
        rest = content[2:end]
    else
        wrapped!(out, Run[lead], w)
        rest = content
    end
    isempty(rest) || (push!(out, blank(w)); blocks!(out, rest, w, ctx))
    out
end

"Display maths, as its source: there is no drawing it in a terminal."
function block!(out::Vector{MDRow}, x::Markdown.LaTeX, w::Int, ctx::Ctx)
    for l in split(string("\$\$", x.formula, "\$\$"), '\n')
        wrapped!(out, Run[Run(String(l), with(Face[], ctx.st.latex))], w; hard = true)
    end
    out
end

@static if isdefined(Markdown, :HTMLBlock)
    "HTML, as it was written: GitHub sanitises most of it away, and a terminal
    cannot do better than show it."
    function block!(out::Vector{MDRow}, x::Markdown.HTMLBlock, w::Int, ctx::Ctx)
        for l in x.content
            wrapped!(out, Run[Run(String(l), with(Face[], ctx.st.html))], w; hard = true)
        end
        out
    end
end

"""Anything else - an element a later Julia adds, or one an older one lacks -
as its plain text, unstyled: a version skew costs styling and never text."""
function block!(out::Vector{MDRow}, x, w::Int, ctx::Ctx)
    s = try
        sprint(Markdown.plain, x)
    catch
        string(x)
    end
    for l in split(rstrip(s, '\n'), '\n')
        wrapped!(out, Run[Run(String(l), Face[])], w; hard = true)
    end
    out
end

# --- tables -----------------------------------------------------------------

"The narrowest a column is made to fit a table in, unless it is narrower."
const TABLE_FLOOR = 4

"""Column widths for cells `nat` columns wide at their widest, in a table that
has `w` to fit in: each at its widest, and while that is too wide, the widest
narrowed a column at a time, down to `TABLE_FLOOR`."""
function fitcolumns(nat::Vector{Int}, w::Int)
    cw = copy(nat)
    room = w - (3 * length(cw) + 1)       # a bar and a space each side of each
    while sum(cw; init = 0) > room
        k = argmax(cw)
        cw[k] <= TABLE_FLOOR && break
        cw[k] -= 1
    end
    cw
end

"One line of a cell, `cw` wide, aligned as its column is."
function aligned(line::Line, cw::Int, align::Symbol)
    d = max(0, cw - runwidth(line))
    s = emit(line)
    align === :r ? string(" "^d, s) :
    align === :c ? string(" "^(d ÷ 2), s, " "^(d - d ÷ 2)) : string(s, " "^d)
end

"""A table, drawn in `style.box` at its indent: the header in `table_head`, the
box in `table_rule`, a column aligned as its `---` says. It is as wide as its
cells, and narrower when that is too wide, with the widest columns narrowed
first and their cells wrapped rather than cut. A rule goes between the body's
rows only when one of them takes more than a line, which is when it is needed
to tell them apart."""
function block!(out::Vector{MDRow}, t::Markdown.Table, w::Int, ctx::Ctx)
    isempty(t.rows) && return out
    st, box = ctx.st, ctx.st.box
    rule = st.table_rule
    n = maximum(length, t.rows)
    align = [k <= length(t.align) ? t.align[k] : :l for k in 1:n]
    # Each cell as one line of runs: a cell is a line in GitHub's tables, and a
    # break written inside one is a space here.
    cell(x, head) = begin
        ls = inlines(x isa AbstractVector ? x : Any[x], Ctx(st, false),
                     head ? with(Face[], st.table_head) : Face[])
        line = Run[]
        for (k, l) in enumerate(ls)
            k > 1 && push!(line, Run(" ", Face[]))
            append!(line, l)
        end
        line
    end
    cells = [[k <= length(r) ? cell(r[k], i == 1) : Run[] for k in 1:n]
             for (i, r) in enumerate(t.rows)]
    nat = [max(1, maximum(runwidth(c[k]) for c in cells)) for k in 1:n]
    cw = fitcolumns(nat, w)
    edge(l::BoxLine) = styled(string(l.left, join((string(l.mid)^(c + 2) for c in cw),
                                                  l.vertical), l.right), rule)
    function body!(r, l::BoxLine)
        wrapped = [wraprun(r[k], cw[k]) for k in 1:n]
        h = maximum(length, wrapped)
        src = join((rstrip(plaintext(c)) for c in r), " | ")
        for j in 1:h
            io = IOBuffer()
            write(io, styled(string(l.left), rule))
            for k in 1:n
                line = j <= length(wrapped[k]) ? wrapped[k][j] : Run[]
                write(io, " ", aligned(line, cw[k], align[k]), " ")
                write(io, styled(string(k == n ? l.right : l.vertical), rule))
            end
            push!(out, MDRow(apad(String(take!(io)), w), string("| ", src, " |"), j == 1))
        end
        h
    end
    push!(out, MDRow(apad(edge(box.top), w), "", true))
    body!(cells[1], box.head)
    if length(cells) > 1
        push!(out, MDRow(apad(edge(box.head_row), w), "", true))
        tall = any(r -> any(k -> runwidth(r[k]) > cw[k], 1:n), cells[2:end])
        for (i, r) in enumerate(cells[2:end])
            i > 1 && tall && push!(out, MDRow(apad(edge(box.row), w), "", true))
            body!(r, box.mid)
        end
    end
    push!(out, MDRow(apad(edge(box.bottom), w), "", true))
    out
end

"""
    highlighted_lines(lang, code, style = MarkdownStyle()) -> Vector{String}

`code` a line to each string, with the escapes of `style.faces` inline where
[`highlight`](@ref) paints it in `lang` - and nothing else: no background, no
wrapping, tabs as they were. Each line closes what it opened. For a host that
draws a block of code its own way, and wants the colours a code block in
markdown would have.
"""
function highlighted_lines(lang::AbstractString, code::AbstractString,
                           style::MarkdownStyle = MarkdownStyle())
    lines, _ = codelines(String(code), lang, style, Face[]; tabs = false)
    String[emit(l) for l in lines]
end

# --- the entry point --------------------------------------------------------

"""
    markdown_rows(md::Markdown.MD, w; style = MarkdownStyle(), breaks = false) -> Vector{MDRow}

`md` drawn as rows of exactly `w` display columns, each carrying the line it
came from - see [`MDRow`](@ref). Pure: the same tree, width and style give the
same rows.

`breaks` makes a newline inside a paragraph a line break, as GitHub draws a
comment, rather than a space, as a document is read. Julia's `Markdown` keeps
the newline in the text from 1.14; before that there is none for it to act on.

The host parses, with the flavor it wants, and the urls of links are the
host's to show: a link is drawn as its label.
"""
function markdown_rows(md::Markdown.MD, w::Int; style::MarkdownStyle = MarkdownStyle(),
                       breaks::Bool = false)
    w = max(w, 1)
    rows = blocks!(MDRow[], md.content, w, Ctx(style, breaks))
    # Every row is `w` already; this is the guarantee, for the one case that
    # is not - a box or a marker wider than a very narrow width - cut to fit.
    [awidth(r.text) == w ? r : MDRow(apad(r.text, w), r.src, r.first) for r in rows]
end
