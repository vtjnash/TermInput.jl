# Julia's own highlighter, where the running Julia has one.
#
# `JuliaSyntaxHighlighting` is a stdlib from 1.12 and a dependency of `Markdown`
# there, so loading `Markdown` is what loads this. The method is `(lang,
# ::String)`, strictly more specific than the stub's `(lang, ::AbstractString)`,
# so it adds to `highlight` rather than overwriting it - which precompilation
# would refuse - and a call is static either way.
module TermInputHighlightExt

import TermInput
import JuliaSyntaxHighlighting

"""The fence languages read as Julia. An empty one is too: an unlabelled block
in a Julia project's comments is Julia far more often than not, and one that
is not costs only colour."""
const JULIA = ("julia", "jl", "jldoctest", "")

function TermInput.highlight(lang::AbstractString, code::String)
    out = Tuple{UnitRange{Int},Symbol}[]
    lowercase(strip(lang)) in JULIA || return out
    s = try
        JuliaSyntaxHighlighting.highlight(code)
    catch
        return out              # a highlighter that throws costs colour, never text
    end
    for a in Base.annotations(s)
        a.label === :face || continue
        f = a.value
        f isa Symbol || continue
        name = String(f)
        startswith(name, "julia_") && (name = name[7:end])
        push!(out, (a.region, Symbol(name)))
    end
    out
end

end # module TermInputHighlightExt
