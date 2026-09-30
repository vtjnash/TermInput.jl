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
# A style is a pair of escapes, the one that starts it and the one that ends
# it, and every piece of a row is written with its own: the styles it is in,
# its text, and their ends in reverse. So nothing is in force at the end of a
# row, the padding is never painted, and a span that wraps is closed on one row
# and opened again on the next with no state carried between them. A style
# given as two empty strings writes nothing at all.
#
# Not `awrap`, which wraps a string with escapes already in it: it carries the
# codes in force across a break but does not close them at the end of the row,
# and it cannot say which piece of the row was which run. Wrapping runs is the
# same greedy break at the last space, and a word wider than the row split by
# columns, with graphemes kept whole.

import Markdown

"A style: the escape that starts it and the one that ends it."
const MDStyle = Tuple{String,String}
const NOSTYLE = ("", "")

"""
    MarkdownStyle(; h1, …, faces)

The escapes markdown is drawn in, one pair `(on, off)` per thing that is styled,
and every one empty by default - so `MarkdownStyle()` draws with no escapes at
all.

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
but its arguments: a host with a theme builds one when the theme changes.
"""
Base.@kwdef struct MarkdownStyle
    h1::MDStyle = NOSTYLE
    h2::MDStyle = NOSTYLE
    h3::MDStyle = NOSTYLE
    h4::MDStyle = NOSTYLE
    h5::MDStyle = NOSTYLE
    h6::MDStyle = NOSTYLE
    bold::MDStyle = NOSTYLE
    italic::MDStyle = NOSTYLE
    strike::MDStyle = NOSTYLE
    code::MDStyle = NOSTYLE
    code_tick::MDStyle = NOSTYLE
    codeblock::MDStyle = NOSTYLE
    link::MDStyle = NOSTYLE
    blockquote::MDStyle = NOSTYLE
    note::MDStyle = NOSTYLE
    tip::MDStyle = NOSTYLE
    warning::MDStyle = NOSTYLE
    danger::MDStyle = NOSTYLE
    info::MDStyle = NOSTYLE
    table_head::MDStyle = NOSTYLE
    table_rule::MDStyle = NOSTYLE
    rule::MDStyle = NOSTYLE
    latex::MDStyle = NOSTYLE
    footnote::MDStyle = NOSTYLE
    html::MDStyle = NOSTYLE
    box::Box = BOXES.ROUNDED
    faces::Dict{Symbol,MDStyle} = Dict{Symbol,MDStyle}()
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
    highlight(lang, code) -> Vector{Tuple{UnitRange{Int},Symbol}}

Byte ranges of `code` and the face each is drawn in, for a code block written
in `lang`. The face is looked up in a [`MarkdownStyle`](@ref)'s `faces`.

This method is the stub: no ranges, so the block is drawn in `codeblock` alone.
Julia's own highlighter answers for Julia from 1.12, through an extension on
`JuliaSyntaxHighlighting`, which `Markdown` loads there. A host that wants
another language adds a method for its own `lang`, specialised on the code's
type the way that one is - `(::AbstractString, ::String)`.
"""
highlight(lang::AbstractString, code::AbstractString) = Tuple{UnitRange{Int},Symbol}[]

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
    styles::Vector{MDStyle}
end

const Line = Vector{Run}

"The escapes and text of one piece, closed behind itself."
function writerun(io::IO, r::Run)
    for s in r.styles
        write(io, s[1])
    end
    write(io, r.text)
    for k in length(r.styles):-1:1
        write(io, r.styles[k][2])
    end
    nothing
end

"""A row of runs as the string that prints it. Neighbours in the same styles
are written as one piece, so a word of plain text is not a dozen resets."""
function emit(line::Line)
    io = IOBuffer()
    k = 1
    while k <= length(line)
        j = k
        while j < length(line) && line[j+1].styles == line[k].styles
            j += 1
        end
        writerun(io, j == k ? line[k] : Run(join(line[i].text for i in k:j), line[k].styles))
        k = j + 1
    end
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
    n = length(gs)
    spans = UnitRange{Int}[]
    rs, col, bp = 1, 0, 0                # row start, its width, a space in it
    i = 1
    while i <= n
        if col + gw[i] > w && i > rs
            if !hard && bp > rs
                push!(spans, rs:bp-1)
                rs = bp + 1
                while rs < i && gs[rs] == " "    # the spaces the break left
                    rs += 1
                end
                col = sum(@view(gw[rs:i-1]); init = 0)
            else
                push!(spans, rs:i-1)
                rs = i; col = 0
            end
            bp = 0
            continue
        end
        gs[i] == " " && (bp = i)
        col += gw[i]
        i += 1
    end
    (rs <= n || isempty(spans)) && push!(spans, rs:n)
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

with(stack::Vector{MDStyle}, s::MDStyle) = s == NOSTYLE ? stack : vcat(stack, [s])

"Inline content as lines of runs: more than one where it has a line break."
function inlines(xs, ctx::Ctx, stack::Vector{MDStyle} = MDStyle[])
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

styled(s::AbstractString, st::MDStyle) = string(st[1], s, st[2])

block!(out::Vector{MDRow}, md::Markdown.MD, w::Int, ctx::Ctx) = blocks!(out, md.content, w, ctx)

function block!(out::Vector{MDRow}, p::Markdown.Paragraph, w::Int, ctx::Ctx)
    for line in inlines(p.content, ctx)
        wrapped!(out, line, w)
    end
    out
end

function block!(out::Vector{MDRow}, h::Markdown.Header{l}, w::Int, ctx::Ctx) where {l}
    st = (ctx.st.h1, ctx.st.h2, ctx.st.h3, ctx.st.h4, ctx.st.h5, ctx.st.h6)[clamp(l, 1, 6)]
    for line in inlines(h.text, ctx, with(MDStyle[], st))
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

"""The lines of a code block as runs: `codeblock` round everything, and a face
inside it wherever the highlighter gave one."""
function codelines(code::String, lang::AbstractString, ctx::Ctx)
    st = ctx.st
    face = fill(:none, ncodeunits(code))
    for (r, f) in highlight(lang, code)
        for b in r
            checkbounds(Bool, face, b) && (face[b] = f)
        end
    end
    base = with(MDStyle[], st.codeblock)
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
        io = IOBuffer()
        col = detab!(io, SubString(code, i, prevind(code, j)), col)
        push!(line, Run(String(take!(io)), f === :none ? base : with(base, facestyle(st, f))))
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
    lines, srcs = codelines(c.code, c.language, ctx)
    for (line, src) in zip(lines, srcs)
        for (k, row) in enumerate(wraprun(line, inner; hard = true))
            fill = max(0, inner - runwidth(row))
            base = with(MDStyle[], cb)
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
    rows = wrapped!(MDRow[], Run[Run(title, with(MDStyle[], st))], max(1, w - 2))
    body = blocks!(MDRow[], a.content, max(1, w - 2), ctx)
    isempty(body) || append!(rows, body)
    prefixed!(out, rows, bar, bar)
end

"""A footnote's definition, as a paragraph led by its reference. Its reference
in the text is an inline one, drawn as `[^id]` where it was written."""
function block!(out::Vector{MDRow}, f::Markdown.Footnote, w::Int, ctx::Ctx)
    lead = Run(string("[^", f.id, "]:"), with(MDStyle[], ctx.st.footnote))
    content = f.text === nothing ? Any[] : f.text
    if !isempty(content) && first(content) isa Markdown.Paragraph
        lines = inlines(first(content).content, ctx)
        pushfirst!(lines[1], lead, Run(" ", MDStyle[]))
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
        wrapped!(out, Run[Run(String(l), with(MDStyle[], ctx.st.latex))], w; hard = true)
    end
    out
end

@static if isdefined(Markdown, :HTMLBlock)
    "HTML, as it was written: GitHub sanitises most of it away, and a terminal
    cannot do better than show it."
    function block!(out::Vector{MDRow}, x::Markdown.HTMLBlock, w::Int, ctx::Ctx)
        for l in x.content
            wrapped!(out, Run[Run(String(l), with(MDStyle[], ctx.st.html))], w; hard = true)
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
        wrapped!(out, Run[Run(String(l), MDStyle[])], w; hard = true)
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
                     head ? with(MDStyle[], st.table_head) : MDStyle[])
        line = Run[]
        for (k, l) in enumerate(ls)
            k > 1 && push!(line, Run(" ", MDStyle[]))
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
