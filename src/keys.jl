"""
    TermInput.Keys

The key vocabulary: one code per key, whether or not the key stands for a
character someone typed.

A submodule because it is the piece with the fewest ties to anything else. It
is the widgets' binding table: `handle!` takes one of these codes, so producing
them is the whole of what a host has to do to drive a widget.

[`readevent`](@ref TermInput.readevent) produces them from a terminal's bytes. A host that reads
keys some other way - a multiplexer that has already put every terminal's keys
into one form, a protocol `readevent` does not speak, something that is not a
terminal at all - produces them itself, and the widgets cannot tell.

`REPL.TerminalMenus.readkey` is what people reach for and it is not enough on
its own: it cannot see a mouse report at all, and it drops any sequence it does
not recognise as a bare `Escape`, leaving the tail to arrive as separate
keystrokes - which is how Shift-Tab reads as Escape-then-Z.
"""
module Keys

export K_BASE, K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP,
       K_PGDN, K_INS, K_NONE, printable, keychar, keycode, unmodified
export K_SHIFT, K_ALT, K_CTRL, K_META, K_MODS
export K_F1, K_F2, K_F3, K_F4, K_F5, K_F6, K_F7, K_F8, K_F9, K_F10, K_F11, K_F12,
       K_F13, K_F14, K_F15, K_F16, K_F17, K_F18, K_F19, K_F20
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
sequence can be is four bytes, so everything at `1 << 32` and up is free: the
named keys are just above it, and the modifiers' bits ([`K_SHIFT`](@ref)) far
above those.

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
const K_INS   = K_BASE + 9

"""
    K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP, K_PGDN, K_INS

The keys that are not characters, each a code at or above [`K_BASE`](@ref), so
that no sequence of bytes somebody typed can be one of them; the function keys
are [`K_F1`](@ref) on.

| code | key |
|---|---|
| `K_LEFT` `K_RIGHT` `K_UP` `K_DOWN` | the arrows |
| `K_DEL` | Delete, the key that deletes forwards |
| `K_HOME` `K_END` `K_PGUP` `K_PGDN` | Home, End, Page Up, Page Down |
| `K_INS` | Insert |

A key held with a modifier is one of these, or a character, with the
modifier's bit added - see [`K_SHIFT`](@ref): Shift-Up is `K_SHIFT | K_UP`,
Shift-Tab `K_SHIFT | 9`, and `⌥b` `K_ALT | Int('b')`.
"""
K_LEFT, K_RIGHT, K_UP, K_DOWN, K_DEL, K_HOME, K_END, K_PGUP, K_PGDN, K_INS

const K_F1  = K_BASE + 16
const K_F2, K_F3, K_F4, K_F5   = K_F1 + 1, K_F1 + 2, K_F1 + 3, K_F1 + 4
const K_F6, K_F7, K_F8, K_F9   = K_F1 + 5, K_F1 + 6, K_F1 + 7, K_F1 + 8
const K_F10, K_F11, K_F12      = K_F1 + 9, K_F1 + 10, K_F1 + 11
const K_F13, K_F14, K_F15, K_F16 = K_F1 + 12, K_F1 + 13, K_F1 + 14, K_F1 + 15
const K_F17, K_F18, K_F19, K_F20 = K_F1 + 16, K_F1 + 17, K_F1 + 18, K_F1 + 19

"""
    K_F1, K_F2, ..., K_F20

The function keys, one consecutive run: `K_F1 + n - 1` is Fn, so a host that
binds them by number does arithmetic rather than a table.

Twenty because that is as far as a terminal numbers them. F1 to F4 arrive as
`SS3 P` to `S`, or `CSI 1;m P` to `S` with a modifier, and the rest as VT220's
`CSI n ~`, whose codes stop at F20 (`CSI 34 ~`). xterm sends a keyboard's F13
and up as F1 and up shifted, and they are read as it sends them: F13 there is
`K_SHIFT | K_F1`. The Linux console's own `CSI [ A` to `E` are F1 to F5.
"""
K_F1, K_F2, K_F3, K_F4, K_F5, K_F6, K_F7, K_F8, K_F9, K_F10, K_F11, K_F12,
K_F13, K_F14, K_F15, K_F16, K_F17, K_F18, K_F19, K_F20

const K_SHIFT = 1 << 40
const K_ALT   = 1 << 41
const K_CTRL  = 1 << 42
const K_META  = 1 << 43
const K_MODS  = K_SHIFT | K_ALT | K_CTRL | K_META

"""
    K_SHIFT, K_ALT, K_CTRL, K_META, K_MODS

The modifiers, a bit each above every key, added to the key they were held
with: `K_ALT | Int('v')` is `⌥v`, `K_CTRL | K_LEFT` Ctrl-Left, `K_SHIFT | K_F1`
Shift-F1. `K_MODS` is all four, so `k & ~K_MODS` is the key and `k & K_MODS`
what was held with it.

Which arrive is the terminal's to say, and differs:

  * **On a named key** - the arrows, Home, End, the `~` keys, the function keys
    - every one, from xterm's modifier parameter (`CSI 1;5D` is Ctrl-Left),
    which is 1 plus a bit each for shift, alt, ctrl and meta.
  * **Alt on anything** is `ESC` and then the key, which is what terminals
    send for Alt, and for a Mac's Option set to be Meta - so that is `K_ALT`
    too. `ESC ESC [ D`, iTerm's spelling of Alt-Left, is `K_ALT | K_LEFT`.
  * **Ctrl on a character is the control byte it arrives as**, never
    `K_CTRL`: `^a` is `1`, as [`C_A`](@ref). A terminal sends `^i` and Tab as
    the one byte, so there is nothing for a bit to say.
  * **Shift on a character is the character**: `A`, not `K_SHIFT | 'a'`.
    Shift-Tab is `K_SHIFT | 9`.

A widget binds the combinations it has a meaning for and answers the rest as
the key alone, through [`unmodified`](@ref): Shift-Left in a text field is
Left, and Ctrl-Page Up is Page Up.
"""
K_SHIFT, K_ALT, K_CTRL, K_META, K_MODS

"""
    K_NONE

A sequence that was read whole and is no key: one a decoder could frame and
not place. Consumed so that its tail does not arrive as keys, and bound by
nothing - a widget answers `:unhandled`, and a host should do nothing with it.
Below every other code, and not bytes anybody could type.
"""
const K_NONE = -1

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
    unmodified(k) -> Int

A named key with its modifiers taken off, for a widget that has no meaning for
them: Shift-Up in a list with no selection to extend is Up, and Ctrl-Page Down
is Page Down. A key drawn on the arrow that does nothing at all reads as a
terminal that has stopped responding.

A character keeps them. `⌥q` is not `q`, and taking it for one would make a
key that quits out of a chord that was meant for something else.
"""
unmodified(k::Int) = (p = k & ~K_MODS) >= K_BASE ? p : k

end # module Keys
