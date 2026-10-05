# Julia's own highlighter, where the running Julia has one.
#
# `JuliaSyntaxHighlighting` is a stdlib from 1.12 and a dependency of `Markdown`
# there, so loading `Markdown` is what loads this. The method is on
# `MIME"text/julia"`, which the stub's `::MIME` is not, so it adds to
# `highlight` rather than overwriting it - which precompilation would refuse -
# and so does a host's for a language of its own.
module TermInputHighlightExt

import TermInput
import JuliaSyntaxHighlighting

function TermInput.highlight(::MIME"text/julia", code::AbstractString)
    out = Tuple{UnitRange{Int},Symbol}[]
    s = try
        JuliaSyntaxHighlighting.highlight(String(code))
    catch
        return out              # a highlighter that throws costs colour, never text
    end
    for a in Base.annotations(s)
        a.label === :face || continue
        f = a.value
        f isa Symbol || continue
        name = String(f)
        startswith(name, "julia_") && (name = name[7:end])
        # The highlighter's regions end on the last byte of their last
        # character; a string range ends where that character starts.
        r = a.region
        push!(out, (first(r):thisind(code, last(r)), Symbol(name)))
    end
    out
end

end # module TermInputHighlightExt
