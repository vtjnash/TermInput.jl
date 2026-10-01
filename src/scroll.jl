# A cursor in a list taller than its box, and the box scrolled to keep it.
#
# Every list a terminal program draws asks the same two questions - which rows
# fit, given where the cursor is, and where a key or the wheel moves the cursor
# to - and the answers do not depend on what the rows are. A `Choice` and a
# `TextArea` ask them, and so does a host's own list beside them.

"""
    listwindow(hs, sel, top, inner) -> (sel, top, rows)
    listwindow(n, sel, top, inner) -> (sel, top, rows)

Scroll so the cursor's row is on screen, and report the window to draw: the
cursor `sel` and the first row shown `top`, both clamped, and the range of rows
that fit in a box `inner` lines tall.

Rows of `hs[i]` lines each - an option with lines of its own under it, a row of
a host's list with more to say - so the window is of rows and the box of lines:
the last row in it may be cut, never the cursor's, unless it is taller than the
box. Or `n` rows of a line each, which is a page of text or a list of one-line
rows. Every list shares it: the geometry of a list of rows in a box does not
depend on what the rows are.

A view with no cursor - a page that only scrolls - passes `top` as `sel`, and
gets back the `top` that keeps the box full.
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

function listwindow(n::Int, sel::Int, top::Int, inner::Int)
    sel = clamp(sel, 1, max(1, n))
    top = clamp(top, max(1, sel - max(1, inner) + 1), sel)
    top = clamp(top, 1, max(1, n - inner + 1))
    (sel, top, top:min(n, top + inner - 1))
end

"""
    WHEELROWS

How far one notch of the wheel moves a cursor: three rows, which is what a
terminal scrolls its own screen by.
"""
const WHEELROWS = 3

"""
    listmove(k, sel, n, page; lo = 1) -> Union{Int, Nothing}
    listmove(kind, sel, n; lo = 1) -> Union{Int, Nothing}

Where a key moves the cursor `sel` of a list of `n` rows, clamped to `lo:n`,
or `nothing` for a key that does not move it - which is then the host's.

The keys are a pager's, for a list nothing is typed into: `j`/`↓` and `k`/`↑`
a row, space, `^f` and page down - `b`, `^b` and page up - a `page` of rows,
`g`/home the first and `G`/end the last. A list with a query at its head, a
`Choice`, has letters spoken for and binds the arrows itself.

With a `Symbol`, it is the mouse: `:wheelup` and `:wheeldown` move it
[`WHEELROWS`](@ref), and any other `kind` is `nothing`. The wheel moves the
cursor rather than only the window, because the window follows the cursor
([`listwindow`](@ref)) and would spring back at the next frame.

`lo` is where the list starts: `0` for one with a row above its first that the
cursor can stand on, which `g` still goes to.
"""
function listmove(k::Int, sel::Int, n::Int, page::Int; lo::Int = 1)
    to = if k in (Int('j'), K_DOWN);          sel + 1
    elseif k in (Int('k'), K_UP);             sel - 1
    elseif k in (Int(' '), C_F, K_PGDN);      sel + max(1, page)
    elseif k in (Int('b'), C_B, K_PGUP);      sel - max(1, page)
    elseif k in (Int('g'), K_HOME);           lo
    elseif k in (Int('G'), K_END);            n
    else
        return nothing
    end
    clamp(to, lo, max(lo, n))
end

function listmove(kind::Symbol, sel::Int, n::Int; lo::Int = 1)
    d = kind === :wheelup ? -WHEELROWS : kind === :wheeldown ? WHEELROWS : 0
    d == 0 ? nothing : clamp(sel + d, lo, max(lo, n))
end
