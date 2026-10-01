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

"""
    listwindow(hs, sel, top, inner) -> (sel, top, rows)

Scroll so the cursor's row is on screen, and report the window to draw: the
cursor `sel` and the first row shown `top`, both clamped, and the range of rows
that fit in a box `inner` lines tall.

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

"""
    DOUBLECLICK

How long two presses can be apart, in seconds, and still be one double click:
the default `window` of [`click!`](@ref) and [`doubled`](@ref).
"""
const DOUBLECLICK = 0.5

"The lines of an option's label: the option, then what is said under it."
optlines(label::AbstractString) = rowlines(label)

"""The key that picks row `i` straight off, or `' '` for a row past the tenth.

`1`-`9` and then `0`, which is where a decade of terminals put the tenth of
anything.
"""
numkey(i::Int) = i < 1 || i > 10 ? ' ' : i == 10 ? '0' : Char('0' + i)

"""
    Choice

Pick one of a list, narrowing by typing.

    import TermInput: render, handle!    # `picked` is exported

    c = Choice("Labels", "↵ toggles one", ["bug", "docs", "performance"])
    write(stdout, frame_bytes(render(c, 80, 24)))
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

`ranged` lets shift-`↑`/`↓` hold an anchor where the cursor was and light the
run of options from it to the cursor, for a host that can do something with
several neighbours at once - a range of commits, say. [`chosen`](@ref) is the
run, or the option under the cursor; any other move lets the anchor go.

`sel` and `top` are positions in what the query leaves showing
([`matches`](@ref)); `picked` and [`selected`](@ref) answer in `labels`.
`status` and `hint` are fields a host may set, as on a [`TextArea`](@ref).
"""
mutable struct Choice
    title::String
    note::Row
    labels::Vector{Row}
    input::LineInput                      # the query
    sel::Int
    top::Int
    numbered::Bool
    ranged::Bool
    anchor::Int                           # where a shifted move began, 0 for none
    status::String
    hint::String
    maxwidth::Int
    boxrows::UnitRange{Int}               # where the last render put the box, and
    orows::UnitRange{Int}                 # the option rows in it, for the mouse -
    omap::Vector{Int}                     # and which shown option each of those
                                          # is, 0 for a blank one under the last
    lastclick::Tuple{Float64,Int,Int}
end

"""
    CHOICE_HINT

The key hints under a `Choice`: the keys it owns, which move the cursor and
narrow the list. What `↵`, escape and the digits of a numbered list do is the
host's - they come back from `handle!` - so a host says so in `hint`.
"""
const CHOICE_HINT = "↑/↓ move · type to narrow"

"""
    Choice(title, note, labels; numbered = false, ranged = false,
           hint = CHOICE_HINT, maxwidth = DIALOG_WIDTH)

A list of `labels` titled `title`, with `note` - what picking one does: a
string, or a vector of rows, see [`notetext`](@ref) - drawn quietly under the
title. `""` for none; it is not optional here only because `labels` follows it.

  * `numbered` puts the first ten on keys of their own, `1`-`9` and `0`
  * `ranged`   shift-`↑`/`↓` light a run of options; see [`chosen`](@ref)
  * `hint`     the key hints under the box, which a host that binds `↵` and
               escape - every host - adds to
  * `maxwidth` the widest the box is drawn, however wide the screen
"""
function Choice(title, note, labels::AbstractVector; numbered::Bool = false,
                ranged::Bool = false, hint::AbstractString = CHOICE_HINT,
                maxwidth::Int = DIALOG_WIDTH)
    Choice(String(title), notetext(note), Row[row(l) for l in labels],
           LineInput(""), 1, 1, numbered, ranged, 0, "", String(hint), maxwidth,
           1:0, 1:0, Int[], (0.0, 0, 0))
end

"""
    query(c::Choice) -> String

What is typed to narrow the list.
"""
query(c::Choice) = text(c.input)

"""
    query!(c::Choice, s) -> Choice

Set the query, as if it had been typed, and go back to the top of the list.
"""
query!(c::Choice, s::AbstractString) = (settext!(c.input.buf, oneline(s)); c.sel = 1; c)

"""Lower case, but a malformed byte - which a paste or a confused terminal can
put in the query, and `lowercase` throws on - stays the byte it was."""
fold(s::AbstractString) = map(ch -> isvalid(ch) ? lowercase(ch) : ch, s)

"""
    matches(c::Choice) -> Vector{Int}

The options the query leaves showing, as indices into `labels`: those whose
label, lines under it included, holds the query, ignoring case and faces.
"""
function matches(c::Choice)
    q = fold(query(c))
    isempty(q) && return collect(eachindex(c.labels))
    Int[i for (i, l) in enumerate(c.labels) if occursin(q, fold(String(l)))]
end

"""
    selected(c::Choice) -> Int

The option under the cursor, as an index into `labels`, or 0 when none shows.
"""
function selected(c::Choice)
    m = matches(c)
    isempty(m) ? 0 : m[clamp(c.sel, 1, length(m))]
end

"""
    chosen(c::Choice) -> Vector{Int}

The options lit, as indices into `labels` in their order: the run from the
anchor to the cursor in a `ranged` list after a shifted move, else the one
under the cursor, else none.
"""
function chosen(c::Choice)
    m = matches(c)
    isempty(m) && return Int[]
    sel = clamp(c.sel, 1, length(m))
    c.anchor == 0 && return [m[sel]]
    a = clamp(c.anchor, 1, length(m))
    m[min(a, sel):max(a, sel)]
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
    m = matches(c)
    b = dialogbox(w; width = c.maxwidth)
    ch = b.chrome
    hs = Int[length(optlines(c.labels[i])) for i in m]
    bh = clamp(sum(hs; init = 0), 1, max(1, h - 10))
    c.sel, c.top, win = listwindow(hs, c.sel, c.top, bh)

    out = Row[b.head(c.title)]
    notes = isempty(c.note) ? Row[] : rowwraplines(c.note, b.iw)
    for l in notes
        push!(out, b.row(l, ch.quiet))
    end
    line = curline(c.input.buf)
    push!(out, b.row(rowcat("/ ", drawfield(line, c.input.buf.col, b.iw - 2))))
    c.omap = Int[]
    lit = c.anchor == 0 ? (c.sel:c.sel) :
          (min(c.anchor, c.sel):max(c.anchor, c.sel))
    for i in win, (j, l) in enumerate(optlines(c.labels[m[i]]))
        length(c.omap) < bh || break
        # The digit, or a space where it has run out, so the names stay in one
        # column whether or not the row has a key of its own; and the lines
        # under an option in that column too.
        label = !c.numbered ? l : rowcat(j == 1 ? numkey(i) : ' ', "  ", l)
        push!(out, b.row(label, i in lit ? ch.focus : ch.quiet))
        push!(c.omap, i)
    end
    while length(c.omap) < bh
        push!(out, b.row(""))
        push!(c.omap, 0)
    end
    isempty(m) && (out[end] = b.row("nothing matches", ch.quiet))
    push!(out, b.foot())
    push!(out, b.hint(isempty(c.status) ? c.hint : c.status))
    # Where the rows land, for a click: `centred` puts the box in the middle,
    # and the options start after the head, the note's rows and the query row.
    blank = max(0, (h - length(out)) ÷ 2)
    c.boxrows = (blank + 1):(blank + length(out))
    orow = blank + 3 + length(notes)
    c.orows = orow:(orow + bh - 1)
    centred(out, w, h)
end

"""
    handle!(c::Choice, k) -> Symbol

`↑`/`↓` and `^p`/`^n` move the cursor - shifted, in a `ranged` list, they
light a run from where it was ([`chosen`](@ref)) - and the rest of what a
[`LineInput`](@ref) edits with edits the query. `↵`, escape and - in a numbered
list - the digits come back, because what picking means is the host's; see
[`picked`](@ref) for which option they would pick.
"""
function handle!(c::Choice, k::Int)
    c.status = ""
    n = length(matches(c))
    if c.ranged && k in (K_SUP, K_SDOWN)
        c.anchor == 0 && (c.anchor = clamp(c.sel, 1, max(1, n)))
        c.sel = clamp(c.sel + (k == K_SDOWN ? 1 : -1), 1, max(1, n))
        return :ok
    end
    k = unshift(k)
    k in (13, 10) || (c.anchor = 0)
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

"""
    paste!(c::Choice, s) -> Choice

A paste goes into the query, as one line and characters only - see
[`paste!(::LineInput, ::AbstractString)`](@ref).
"""
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
        c.anchor = 0
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
    c.anchor = 0
    dbl ? :pick : :ok
end

"""
    Confirm

Ask a question that named keys answer, and nothing else does.

    c = Confirm("Discard what you have written?", "it is not saved anywhere";
                hint = "y discards · any other key keeps it")
    write(stdout, frame_bytes(render(c, 80, 24)))
    answer(c, key) == 1 && discard()       # 0 is no, whatever the key was

Not a [`Choice`](@ref) of two entries: there the answer is already under the
cursor and `↵` takes it, which is exactly the reflex a question like this exists
to interrupt. Here the answering key is one you would not be holding - `y` by
default, named in the hint - and *everything* else is no, including the key
that opened the question and the enter that would have picked something in a
picker.

There is no `status`: a key ends a question, so there is no next frame for a
line saying what happened to be drawn in. `hint` may be set after construction,
as on the other widgets.
"""
mutable struct Confirm
    title::String
    note::Row
    hint::String
    keys::Vector{String}
    maxwidth::Int
end

"""
    CONFIRM_HINT

The key hint under a `Confirm` that answers to the default `"yY"`: which key is
yes, and that every other one is no. What yes *does* is the host's, and a host
that says so - "y discards it" - says it better.
"""
const CONFIRM_HINT = "y yes · any other key no"

"""
    Confirm(title, note, keys = ["yY"]; hint = CONFIRM_HINT, maxwidth = DIALOG_WIDTH)

A question titled `title`, with `note` - what is at stake: a string, or a
vector of rows, one fact to a row, see [`notetext`](@ref) - drawn quietly under
it, wrapped rather than cut at the width. `""` for none; it is not optional
only because `keys` follows it.

  * `keys`     one string for each answer, every key that gives it (`"yY"`, so
               shift does not matter); more than one is how a question offers
               the thing you would rather do than say yes. [`answer`](@ref)
               says which was pressed
  * `hint`     the key hints under the box. Name the answering keys in it: they
               are the only ones that do anything, and nothing else on screen
               says what they are
  * `maxwidth` the widest the box is drawn, however wide the screen
"""
Confirm(title, note, keys::AbstractVector = ["yY"];
        hint::AbstractString = CONFIRM_HINT, maxwidth::Int = DIALOG_WIDTH) =
    Confirm(String(title), notetext(note), String(hint), String[String(k) for k in keys],
            maxwidth)

function render(c::Confirm, w::Int, h::Int)
    b = dialogbox(w; width = c.maxwidth)
    out = Row[b.head(c.title)]
    for l in (isempty(c.note) ? Row[] : rowwraplines(c.note, b.iw))
        push!(out, b.row(l, b.chrome.quiet))
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
