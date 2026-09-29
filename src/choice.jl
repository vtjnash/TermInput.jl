# Picking one of a list, and answering a question with a key.
#
# The `<select>` beside the `<input>` and the `<textarea>`: a list in a box,
# narrowed by typing into a `LineInput` at its head. And its smaller sibling,
# `Confirm`, which is a question that only named keys answer.
#
# The same contract as the other two. `render` is a pure function of the widget
# and a size - bar where it remembers having put the rows, for the mouse - and
# `handle!` claims the keys that move the cursor and edit the query and hands
# back the rest. What a pick *does* is the host's, and so is what escape means;
# the widget only says which option a key would pick (`picked`).

"""Scroll so the cursor's row is on screen, and report the window to draw.

    (sel, top, rows) = listwindow(hs, sel, top, inner)

Rows of `hs[i]` lines each - an option with lines of its own under it, a row of
a host's list with more to say - so the window is of rows and the box of lines:
the last row in it may be cut, never the cursor's, unless it is taller than the
box. Every list shares it: the geometry of a list of rows in a box does not
depend on what the rows are.
"""
function listwindow(hs::Vector{Int}, sel::Int, top::Int, inner::Int)
    n = length(hs)
    sel = clamp(sel, 1, max(1, n))
    top = clamp(top, 1, max(1, n))
    sel < top && (top = sel)
    # Down until the whole of the cursor's row fits, or it is the top one.
    while top < sel && sum(@view hs[top:sel]) > inner
        top += 1
    end
    # And up while the rows above fit in what the list would leave empty at
    # its foot: a list scrolled to its end, or narrowed under a scrolled top,
    # fills the box rather than ending half way down it.
    while top > 1 && sum(@view hs[(top - 1):n]) <= inner
        top -= 1
    end
    last_ = top - 1
    used = 0
    while last_ < n && used < inner
        last_ += 1
        used += hs[last_]
    end
    (sel, top, top:last_)
end

"""
    doubled(last, x, y, at, window) -> Bool

Is a press at `(x, y)` at time `at` the second half of a double click, where
`last` is `(at, x, y)` of the press before it and `window` how far apart in
seconds the two may be?

One column of slack, because a hand moves between the two presses and a gesture
that has to land on the same cell twice is one that mostly does not. `at` and
`window` are both arguments: a terminal reports each press as if it were alone,
so the time is the only thing that makes two of them one gesture, and a widget
that read the clock itself could not be tested without waiting.
"""
doubled(last::Tuple{Float64,Int,Int}, x::Int, y::Int, at::Float64, window::Float64) =
    at - last[1] <= window && y == last[3] && abs(x - last[2]) <= 1

"How long two presses can be apart and still be one double click, by default."
const DOUBLECLICK = 0.5

"The lines of an option's label: the option, then what is said under it."
optlines(label::AbstractString) = split(label, '\n')

"""The key that picks row `i` straight off, or `' '` for a row past the tenth.

`1`-`9` and then `0`, which is where a decade of terminals put the tenth of
anything.
"""
numkey(i::Int) = i < 1 || i > 10 ? ' ' : i == 10 ? '0' : Char('0' + i)

"""Pick one of a list, narrowing by typing.

    c = Choice("Labels", "↵ toggles one", ["bug", "docs", "performance"])
    print(render(c, 80, 24))
    if handle!(c, key) === :unhandled      # not a move or an edit
        i = picked(c, key)                 # ↵, or a digit: which one, or 0
        i > 0 && apply(c.labels[i])
        key == 27 && close()
    end

The filter is what makes it usable rather than a nicety: a couple of hundred
labels is not something to scroll through. The query is a [`LineInput`](@ref),
so it edits the way every other field does.

A label may be several lines, `\\n` between them: the first is the option, and
the ones under it are more about it - drawn under it, lit with it, and matched
by the filter with it. The cursor moves an option at a time and the whole of
the one it is on stays in the box ([`listwindow`](@ref)).

`numbered` puts the first ten on keys of their own, `1`-`9` and `0`. Only for a
list that is the same list every time and is reached by memory rather than by
reading, since it costs those ten the ability to be narrowed by typing a digit.

`sel` and `top` are positions in what the query leaves showing
([`matches`](@ref)); `picked` and [`selected`](@ref) answer in `labels`.
"""
mutable struct Choice
    title::String
    note::String
    labels::Vector{String}
    input::LineInput                      # the query
    sel::Int
    top::Int
    numbered::Bool
    hint::String
    maxwidth::Int
    boxrows::UnitRange{Int}               # where the last render put the box, and
    orows::UnitRange{Int}                 # the option rows in it, for the mouse -
    omap::Vector{Int}                     # and which shown option each of those
                                          # is, 0 for a blank one under the last
    lastclick::Tuple{Float64,Int,Int}
end

"""
    Choice(title, note, labels; numbered = false, hint, maxwidth = 76)
"""
function Choice(title, note, labels::AbstractVector; numbered::Bool = false,
                hint::AbstractString = numbered ? "0-9 picks · ↑/↓ move · ↵ pick · esc cancel" :
                                                  "↑/↓ move · ↵ pick · esc cancel",
                maxwidth::Int = 76)
    Choice(String(title), String(note), String[String(l) for l in labels],
           LineInput(""), 1, 1, numbered, String(hint), maxwidth,
           1:0, 1:0, Int[], (0.0, 0, 0))
end

"What is typed to narrow the list."
query(c::Choice) = text(c.input)

"Set the query, as if it had been typed, and go back to the top of the list."
query!(c::Choice, s::AbstractString) = (settext!(c.input.buf, oneline(s)); c.sel = 1; c)

"""The options the query leaves showing, as indices into `labels`: those whose
label, lines under it included, holds the query, ignoring case and escapes."""
function matches(c::Choice)
    q = lowercase(query(c))
    isempty(q) && return collect(eachindex(c.labels))
    Int[i for (i, l) in enumerate(c.labels) if occursin(q, lowercase(astrip(l)))]
end

"The option under the cursor, as an index into `labels`, or 0 when none shows."
function selected(c::Choice)
    m = matches(c)
    isempty(m) ? 0 : m[clamp(c.sel, 1, length(m))]
end

"""
    picked(c::Choice, k) -> Int

The option key `k` picks, as an index into `labels`, or 0 when it picks none:
`↵` picks the one under the cursor, and in a numbered list a digit picks that
row - nothing where there is no such row, rather than the last.
"""
function picked(c::Choice, k::Int)
    k = unshift(k)
    k in (13, 10) && return selected(c)
    if c.numbered && Int('0') <= k <= Int('9')
        m = matches(c)
        i = k == Int('0') ? 10 : k - Int('0')
        return i <= length(m) ? m[i] : 0
    end
    0
end

function render(c::Choice, w::Int, h::Int)
    ch = CHROME[]
    m = matches(c)
    b = dialogbox(w; width = c.maxwidth)
    hs = Int[length(optlines(c.labels[i])) for i in m]
    bh = clamp(sum(hs; init = 0), 1, max(1, h - 10))
    c.sel, c.top, win = listwindow(hs, c.sel, c.top, bh)

    out = [b.head(c.title)]
    isempty(c.note) || push!(out, b.row(c.note, ch.quiet))
    line = curline(c.input.buf)
    push!(out, b.row(string("/ ", drawcursor(line, displaycolumn(line, c.input.buf.col)))))
    c.omap = Int[]
    for i in win, (j, l) in enumerate(optlines(c.labels[m[i]]))
        length(c.omap) < bh || break
        # The digit, or a space where it has run out, so the names stay in one
        # column whether or not the row has a key of its own; and the lines
        # under an option in that column too.
        label = !c.numbered ? l : string(j == 1 ? numkey(i) : ' ', "  ", l)
        push!(out, b.row(label, i == c.sel ? ch.focus : ch.quiet))
        push!(c.omap, i)
    end
    while length(c.omap) < bh
        push!(out, b.row(""))
        push!(c.omap, 0)
    end
    isempty(m) && (out[end] = b.row("nothing matches", ch.quiet))
    push!(out, b.foot())
    push!(out, b.hint(c.hint))
    # Where the rows land, for a click: `centred` puts the box in the middle,
    # and the options start after the head, the note and the query row.
    blank = max(0, (h - length(out)) ÷ 2)
    c.boxrows = (blank + 1):(blank + length(out))
    orow = blank + 3 + (isempty(c.note) ? 0 : 1)
    c.orows = orow:(orow + bh - 1)
    centred(out, w, h)
end

"""
    handle!(c::Choice, k) -> Symbol

`↑`/`↓` and `^p`/`^n` move the cursor, and the rest of what a
[`LineInput`](@ref) edits with edits the query. `↵`, escape and - in a numbered
list - the digits come back, because what picking means is the host's; see
[`picked`](@ref) for which option they would pick.
"""
function handle!(c::Choice, k::Int)
    k = unshift(k)
    n = length(matches(c))
    if k in (K_DOWN, C_N)
        c.sel = clamp(c.sel + 1, 1, max(1, n))
    elseif k in (K_UP, C_P)
        c.sel = max(1, c.sel - 1)
    elseif c.numbered && Int('0') <= k <= Int('9')
        return :unhandled
    else
        q = query(c)
        handle!(c.input, k) === :ok || return :unhandled
        query(c) == q || (c.sel = 1)
    end
    :ok
end

"A paste goes into the query, as one line."
paste!(c::Choice, s::AbstractString) = (paste!(c.input, s); c.sel = 1; c)

"""
    click!(c::Choice, kind, x, y, at; window = DOUBLECLICK) -> Symbol

One mouse report, against where the last `render` put the rows. `kind` is
`:press`, `:wheelup` or `:wheeldown` - anything else is ignored - and `at` the
time of it, for telling a double click (see [`doubled`](@ref)).

A press on an option moves the cursor there, and the wheel moves it three. What
comes back is `:ok`, or one of the two a host has to decide about: `:pick` for
a double click on an option, which is now under the cursor - `↵`, done with the
mouse - and `:unhandled` for a press outside the box, which everywhere else
means "not this".
"""
function click!(c::Choice, kind::Symbol, x::Int, y::Int, at::Float64;
                window::Float64 = DOUBLECLICK)
    n = length(matches(c))
    if kind === :wheelup || kind === :wheeldown
        c.sel = clamp(c.sel + (kind === :wheelup ? -3 : 3), 1, max(1, n))
        return :ok
    end
    kind === :press || return :ok
    dbl = doubled(c.lastclick, x, y, at, window)
    c.lastclick = (at, x, y)
    y in c.boxrows || return :unhandled
    # By the row's option, not its offset: an option can be several rows.
    y in c.orows || return :ok
    i = get(c.omap, y - first(c.orows) + 1, 0)
    1 <= i <= n || return :ok
    c.sel = i
    dbl ? :pick : :ok
end

"""Ask a question that named keys answer, and nothing else does.

    c = Confirm("Discard what you have written?", "it is not saved anywhere",
                ["yY"]; hint = "y discards · any other key keeps it")
    print(render(c, 80, 24))
    answer(c, key) == 1 && discard()       # 0 is no, whatever the key was

Not a [`Choice`](@ref) of two entries: there the answer is already under the
cursor and `↵` takes it, which is exactly the reflex a question like this exists
to interrupt. Here the answering key is one you would not be holding - `y` by
default, named in the hint - and *everything* else is no, including the key
that opened the question and the enter that would have picked something in a
picker.

`keys` is one string for each answer, every key that gives it (`"yY"`, so shift
does not matter); more than one is how a question offers the thing you would
rather do than say yes. `notes` is a line or several: what is at stake, one
fact to a row, wrapped rather than cut at the width.
"""
struct Confirm
    title::String
    notes::Vector{String}
    hint::String
    keys::Vector{String}
    maxwidth::Int
end

noterows(s::AbstractString) = isempty(s) ? String[] : [String(s)]
noterows(v) = String[String(r) for r in v if !isempty(r)]

"""
    Confirm(title, notes, keys = ["yY"]; hint, maxwidth = 76)
"""
Confirm(title, notes, keys::AbstractVector = ["yY"];
        hint::AbstractString = "y confirms · any other key cancels", maxwidth::Int = 76) =
    Confirm(String(title), noterows(notes), String(hint), String[String(k) for k in keys],
            maxwidth)

function render(c::Confirm, w::Int, h::Int)
    b = dialogbox(w; width = c.maxwidth)
    out = [b.head(c.title)]
    for n in c.notes, l in awrap(n, b.iw)
        push!(out, b.row(l, CHROME[].quiet))
    end
    push!(out, b.foot())
    push!(out, b.hint(c.hint))
    centred(out, w, h)
end

"""
    answer(c::Confirm, k) -> Int

Which of the answers key `k` gives, or 0 for no. Escape is an answer when a
question names one for it (`"\\e"` in its keys) and no otherwise: it is the key
a dialog appearing produces from the fingers, so a question that means
something particular by it has to say so in its hint.
"""
function answer(c::Confirm, k::Int)
    (printable(k) || k == 27) || return 0
    something(findfirst(ks -> keychar(k) in ks, c.keys), 0)
end
