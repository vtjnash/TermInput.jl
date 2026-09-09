"""
    TermInput

Text input for the terminal: a line to answer a question in and a box to write a
paragraph in, drawn wherever your own TUI puts them.

The name is the design. An HTML `<input>` and `<textarea>` are a place to type
inside a page that is not about typing: the page owns the layout, the element
owns the caret and the keys, and what comes back out is a string. This is that,
for a terminal.

    using TermInput
    import TermInput: render, handle!, text

    ta = TextArea("Comment", "on managers.jl:544")
    print(render(ta, 80, 24))            # `h` rows of exactly `w` columns
    act = handle!(ta, key)               # :ok | :submit | :cancel | :unhandled
    act === :submit && post(submission(ta))

Nothing here reads stdin, holds raw mode, or runs a loop. A host has all three
already, and a widget that insisted on its own would be one you cannot put in
the program you are writing - so `render` is a pure function of the widget and a
size, `handle!` takes one key code, and a key this does not claim comes straight
back as `:unhandled`.

## The pieces

  * `ansi.jl`      display widths, fitting and wrapping for text with escape
                   sequences in it
  * `keys.jl`      the key vocabulary: one code per key, as a submodule
  * `buffer.jl`    `TextBuffer` - lines, a cursor, and readline's operations,
                   with no view attached
  * `border.jl`    the box, in Term's box characters and the theme's style
  * `suspend.jl`   handing the terminal to `\$EDITOR` and taking it back
  * `textarea.jl`  `TextArea`, the multi-line composer
  * `lineinput.jl` `LineInput`, one line in a box

## What Term gives it

The border follows `Term.TERM_THEME[].box`, so a composer opened over a screen
of `Term.Panel`s is bordered the way they are. The measuring is this package's
own: `Panel` measures markup, so a title a host styled with raw SGR is counted
as characters and wrapped - and worse in the other direction, a buffer full of
prose is *not* markup, so a `{` somebody typed is read as a tag and silently
deleted.
"""
module TermInput

import Term
import REPL
import InteractiveUtils

export ESCAPE, awidth, astrip, afit, apad, amid, awrap
export TextBuffer, settext!, curline, move!, newline!, insertblock!, backspace!,
       deletechar!, killline!, killtostart!, deleteword!, word_start, word_end,
       bufferrows, isblank
export boxstyle, dialogbox, centred
export suspend, compose_external, mouse_reporting
export TextArea, LineInput, ACTIONS, submission, TEXTAREA_HINT, LINEINPUT_HINT
# The key vocabulary is a host's to produce and every widget's to bind, so it is
# re-exported rather than left behind the submodule: a program that reads a
# keystroke has to be able to say `K_LEFT` without knowing where it lives.
export Keys
export K_BASE, K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP,
       K_PGDN, K_STAB, K_WORD_LEFT, K_WORD_RIGHT, K_WORD_BACK, K_EDIT,
       K_SUP, K_SDOWN, printable, keychar, keycode, unshift
export C_A, C_D, C_E, C_K, C_O, C_R, C_S, C_U, C_W

include("ansi.jl")
include("keys.jl")
using .Keys

include("buffer.jl")
include("border.jl")
include("suspend.jl")
include("textarea.jl")
include("lineinput.jl")

"""
    render(widget, w, h) -> String

The whole frame: `h` rows of exactly `w` display columns, joined by newlines and
with no trailing one. Pure - the same widget and the same size give the same
string.

Not exported, because `render` is a name a host is likely to have already;
`import TermInput: render` where it is not.
"""
render

"""
    handle!(widget, key) -> Symbol

Hand one key code to a widget - see [`ACTIONS`](@ref) for what comes back, and
`Keys` for the codes. Not exported, for the same reason as [`render`](@ref).
"""
handle!

"""
    text(widget) -> String

What is written, exactly as it is written. [`submission`](@ref) is what to take
when a widget says `:submit`. Not exported, for the same reason as
[`render`](@ref).
"""
text

end # module TermInput
