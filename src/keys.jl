"""
    TermInput.Keys

The key vocabulary: one code per key, whether or not the key stands for a
character someone typed.

A submodule because it is the piece with the fewest ties to anything else. It
is the widgets' binding table and nothing more - what turns bytes from a
terminal *into* these codes is a decoder, and there is not one here yet: a host
already has an input loop of its own, and this package's job is what happens
after a key has been read. `handle!` takes one of these codes, so producing
them is the whole of what a host has to do to drive a widget.

`REPL.TerminalMenus.readkey` is what people reach for and it is not enough on
its own: it cannot see a mouse report at all, and it drops any sequence it does
not recognise as a bare `Escape`, leaving the tail to arrive as separate
keystrokes - which is how Shift-Tab reads as Escape-then-Z. A decoder that
produces this vocabulary belongs here eventually; see the README.
"""
module Keys

export K_BASE, K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP,
       K_PGDN, K_STAB, K_WORD_LEFT, K_WORD_RIGHT, K_WORD_BACK, K_WORD_KILL,
       K_EDIT, K_SUP, K_SDOWN, printable, keychar, keycode, unshift
export C_A, C_B, C_D, C_E, C_F, C_G, C_K, C_N, C_O, C_P, C_R, C_S, C_T, C_U,
       C_W, C_Y

# Readline's editing keys, by the control bytes they arrive as. Named because a
# `handle!` full of bare integers is a table nobody can read: `k == C_W` is the
# key, `k == 23` is a number that happens to be it.
const C_A, C_B, C_D, C_E, C_F, C_G, C_K = 1, 2, 4, 5, 6, 7, 11
const C_N, C_O, C_P, C_R, C_S, C_T, C_U = 14, 15, 16, 18, 19, 20, 21
const C_W, C_Y = 23, 25

"""
    C_A, C_B, C_D, C_E, C_F, C_G, C_K, C_N, C_O, C_P, C_R, C_S, C_T, C_U, C_W, C_Y

The control keys readline binds, as the byte each arrives as: `C_W == 23` is
`^w`. Only the ones some widget binds, or hands back and a host is likely to
bind, have a name - `^s` to finish, `^g` to abort, `^r` for a host's own.
"""
C_A, C_B, C_D, C_E, C_F, C_G, C_K, C_N, C_O, C_P, C_R, C_S, C_T, C_U, C_W, C_Y

"""
    K_BASE

Where the keys that are not characters start; see [`K_LEFT`](@ref) for them.

**A key code below this is the bytes that arrived, packed big-endian.** One byte
is `0x00`-`0xFF`, so `k == Int('j')`, `k == 13` and `k == 27` are what they have
always been. A multi-byte UTF-8 sequence is its bytes in order, which is always
above `0xFF` because the lead byte of one is at least `0xC0`. The widest a
sequence can be is four bytes, so everything at `1 << 32` and up is free.

It is *not* a codepoint, and that is the point. Decoding to one is a lossy step
in both directions. `Int(c)` on a malformed sequence either throws - a lone
`0x80` has no codepoint at all - or answers something that was never typed: `C0
80` becomes `0`, a NUL, and `F4 90 80 80` becomes `1114112`. With the key space
starting at `0x110000`, one past the last codepoint, that last one *was* `K_LEFT`
and `F4 90 80 82` was `K_UP`, so a paste of arbitrary bytes moved the cursor.

Rejecting malformed input would fix the collision and is still the wrong answer,
because Julia does not need us to. A `Char` is four bytes of UTF-8 held as they
came, and arbitrary binary survives a round trip through a `String` intact - it
is only `codepoint` that refuses. So nothing is decoded and nothing is thrown
away: the bytes are carried, [`keychar`](@ref) hands them back, and what a
terminal sends is what a comment gets.

The framing is Julia's own, so that a sequence put into a buffer comes back out
of it as the same one `Char`: `0xC0`-`0xF7` lead a sequence and take their
continuation bytes, while `0xF8` and above are not lead bytes at all and stand
alone, as does a continuation byte with no lead and a lead whose continuation
never arrived.
"""
const K_BASE  = 1 << 32
const K_LEFT  = K_BASE + 0
const K_RIGHT = K_BASE + 1
const K_UP    = K_BASE + 2
const K_DOWN  = K_BASE + 3
const K_DEL   = K_BASE + 4
const K_HOME  = K_BASE + 5
const K_END   = K_BASE + 6
const K_PGUP  = K_BASE + 7
const K_PGDN  = K_BASE + 8
const K_STAB  = K_BASE + 9
const K_WORD_LEFT  = K_BASE + 10
const K_WORD_RIGHT = K_BASE + 11
const K_WORD_BACK  = K_BASE + 12
const K_EDIT       = K_BASE + 13
const K_SUP        = K_BASE + 14
const K_SDOWN      = K_BASE + 15
const K_WORD_KILL  = K_BASE + 16

"""
    K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP, K_PGDN, K_STAB,
    K_WORD_LEFT, K_WORD_RIGHT, K_WORD_BACK, K_WORD_KILL, K_EDIT, K_SUP, K_SDOWN

The keys that are not characters, each a code at or above [`K_BASE`](@ref), so
that no sequence of bytes somebody typed can be one of them.

| code | key |
|---|---|
| `K_LEFT` `K_RIGHT` `K_UP` `K_DOWN` | the arrows |
| `K_DEL` | Delete, the key that deletes forwards |
| `K_HOME` `K_END` `K_PGUP` `K_PGDN` | Home, End, Page Up, Page Down |
| `K_STAB` | Shift-Tab (`CSI Z`) |
| `K_WORD_LEFT` `K_WORD_RIGHT` | `⌥b`/`⌥f`, and the ctrl- or alt-arrows |
| `K_WORD_BACK` | `⌥⌫`: delete the word before the cursor |
| `K_WORD_KILL` | `⌥d`: delete the word in front of the cursor |
| `K_EDIT` | `⌥e`, hand the text to `\$EDITOR`, as the Julia REPL binds it |
| `K_SUP` `K_SDOWN` | Shift-Up and Shift-Down |

Shift-Up and Shift-Down are keys of their own rather than an arrow with a
modifier, for a view that has a selection to extend with them. One that has
none passes them through [`unshift`](@ref), and every widget here does.
"""
K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP, K_PGDN, K_STAB,
K_WORD_LEFT, K_WORD_RIGHT, K_WORD_BACK, K_WORD_KILL, K_EDIT, K_SUP, K_SDOWN

"""
    printable(k) -> Bool

A key that stands for something someone meant to type.

Anything below [`K_BASE`](@ref) that is not a control byte, which includes bytes
that are not a character on their own. That is deliberate: they are what was
typed or pasted, and [`keychar`](@ref) can hand every one of them back.
"""
printable(k::Int) = (k >= 32 && k != 127 && k < K_BASE)

"""
    keychar(k) -> Char

The bytes of `k` as the `Char` they are, however malformed.

Their count is their magnitude - a two-byte sequence starts at `0xC080`, a three
at `0xE08080`, a four at `0xF0808080` - and a `Char` holds them left-aligned,
which is all this has to do. Nothing is validated, because nothing was decoded.
"""
function keychar(k::Int)
    n = k > 0xFFFFFF ? 0 : k > 0xFFFF ? 1 : k > 0xFF ? 2 : 3
    reinterpret(Char, UInt32(k) << (8 * n))
end

"""
    keycode(c) -> Int

The key code for `c`: its bytes, packed. The inverse of [`keychar`](@ref),
for a caller with a character in hand and a key stream to put it into.
"""
keycode(c::Char) =
    Int(reinterpret(UInt32, c) >> (8 * (4 - ncodeunits(c))))

"""
    unshift(k) -> Int

Shift-Up and Shift-Down for a view with no selection to extend: the plain
arrow. A key drawn on the arrow that does nothing at all reads as a terminal
that has stopped responding.
"""
unshift(k::Int) = k == K_SUP ? K_UP : k == K_SDOWN ? K_DOWN : k

end # module Keys
