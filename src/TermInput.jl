"""
    TermInput

Text input for the terminal: a line to answer a question in, a box to write a
paragraph in, a list to pick one of and a question only a named key answers,
drawn wherever your own TUI puts them.

The name is the design. An HTML `<input>`, `<textarea>` and `<select>` are a
place to type or choose inside a page that is not about typing: the page owns
the layout, the element owns the caret and the keys, and what comes back out is
a string or an option. This is that, for a terminal.

    using TermInput
    import TermInput: render, handle!, text

    ta = TextArea("Comment", "on src/parse.jl:42")
    print(render(ta, 80, 24))               # `h` rows of exactly `w` columns
    if handle!(ta, key) === :unhandled      # not an edit, so it is yours
        key == 19 && post(submission(ta))   # ...and this is what `^s` means
    end

Nothing here reads stdin, holds raw mode, or runs a loop. A host has all three
already, and a widget that insisted on its own would be one you cannot put in
the program you are writing - so `render` is a pure function of the widget and a
size, and `handle!` takes one key code.

Nor does it decide when you are finished. The keys it claims are the ones that
*edit text*; what `^s` or `↵` or escape mean over the top of that is the host's,
because a text box that answered it would be answering it for every program that
embeds one.

## The pieces

  * `ansi.jl`      display widths, fitting and wrapping for text with escape
                   sequences in it
  * `keys.jl`      the key vocabulary: one code per key, as a submodule
  * `buffer.jl`    `TextBuffer` - lines, a cursor, and readline's operations,
                   with no view attached
  * `border.jl`    the box: its characters, and the weights it is painted in
  * `suspend.jl`   handing the terminal to `\$EDITOR` and taking it back
  * `textarea.jl`  `TextArea`, the multi-line composer
  * `lineinput.jl` `LineInput`, one line in a box
  * `choice.jl`    `Choice`, one of a list narrowed by typing, and `Confirm`,
                   a question only named keys answer

## What it measures with

Its own. `awidth`, `afit`, `apad` and `awrap` count display columns in text
that already has escapes in it, which is what a host hands over: a title it
styled, a note, a buffer somebody typed braces into.
"""
module TermInput

import REPL
import InteractiveUtils

# Exported: what a host driving a widget writes on every call, with names
# specific enough that it is unlikely to have them already.
export awidth, astrip, afit, apad, amid, awrap
export TextBuffer
export suspend, compose_external, mouse_reporting, bracketed_paste
export TextArea, LineInput, Choice, Confirm, submission, isblank, picked, answer,
       listwindow, TEXTAREA_HINT, LINEINPUT_HINT, CHOICE_HINT, CONFIRM_HINT
# The key vocabulary is a host's to produce and every widget's to bind, so it is
# re-exported rather than left behind the submodule: a program that reads a
# keystroke has to be able to say `K_LEFT` without knowing where it lives.
export Keys
export K_BASE, K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP,
       K_PGDN, K_STAB, K_WORD_LEFT, K_WORD_RIGHT, K_WORD_BACK, K_WORD_KILL,
       K_EDIT, K_SUP, K_SDOWN, printable, keychar, keycode, unshift
export C_A, C_B, C_D, C_E, C_F, C_G, C_K, C_N, C_O, C_P, C_R, C_S, C_T, C_U,
       C_W, C_Y

# Public and not exported: API, but a name a host is likely to have already -
# `render`, `text`, `move!` - or one it uses once, where it sets a widget up,
# rather than on every call. `import TermInput: render, handle!` where they are
# wanted. `public` is 1.11's, so it is parsed only where it exists.
@static if VERSION >= v"1.11.0-DEV.469"
    eval(Meta.parse("""public render, handle!, text, paste!, click!, column,
        query, query!, selected, matches, doubled, DOUBLECLICK, ACTIONS,
        ESCAPE, oneline, notetext, drawfield, bufferrows, settext!, curline, move!,
        newline!, insertblock!, backspace!, deletechar!, killline!,
        killtostart!, deleteword!, killwordforward!, kill!, yank!, transpose!,
        wordstart, wordend, boxstyle, Box, BoxLine, BOXES, dialogbox, centred, CHROME,
        DIALOG_WIDTH"""))
end

include("ansi.jl")
include("keys.jl")
using .Keys

include("buffer.jl")
include("border.jl")
include("suspend.jl")
include("textarea.jl")
include("lineinput.jl")
include("choice.jl")

"""
    render(widget, w, h) -> String

The whole frame: `h` rows of exactly `w` display columns, joined by newlines and
with no trailing one. Pure - the same widget and the same size give the same
string - bar that a `Choice` notes where it put its rows, for [`click!`](@ref).

Public and not exported, because `render` is a name a host is likely to have
already; `import TermInput: render` where it is not.
"""
render

"""
    handle!(widget, key) -> Symbol

Hand one key code to a `TextArea`, a `LineInput` or a `Choice` - see
[`ACTIONS`](@ref) for what comes back, and `Keys` for the codes. A `Confirm`
has none: any key ends a question, so its key goes to [`answer`](@ref), which
says what it answered.

Public and not exported, for the same reason as [`render`](@ref).
"""
handle!

"""
    text(widget) -> String

What is written, exactly as it is written. [`submission`](@ref) is the same with
the whitespace round it taken off, which is usually what a host wants when it
decides the widget is finished.

Public and not exported, for the same reason as [`render`](@ref).
"""
text

end # module TermInput
