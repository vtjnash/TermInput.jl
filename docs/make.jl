# The manual is the README, so that there is one of it, and the rest is every
# docstring: what a host imports, the key codes, and what the widgets are made
# of - three pages, since one would be past Documenter's size limit.
#
#     julia --project=docs -e 'using Pkg; Pkg.instantiate()'
#     julia --project=docs docs/make.jl
#
# `build/` is the site; `deploydocs` publishes it from CI and does nothing
# anywhere else.
using Documenter, TermInput

const ROOT = dirname(@__DIR__)

# A link to a heading is GitHub's lowercased slug in the README and the heading
# itself in Documenter, so the one is rewritten into the other on the way in.
function readme_page(readme, page)
    md = read(readme, String)
    slug(h) = replace(lowercase(h), r"[^\w\- ]" => "", ' ' => '-')
    heads = Dict(slug(m[1]) => m[1] for m in eachmatch(r"(?m)^#+ +(.+?) *$", md))
    md = replace(md, r"\]\(#([\w-]+)\)" => s -> begin
        h = get(heads, match(r"#([\w-]+)", s)[1], nothing)
        h === nothing ? s : string("](@ref \"", h, "\")")
    end)
    write(page, md)
end
readme_page(joinpath(ROOT, "README.md"), joinpath(@__DIR__, "src", "index.md"))

makedocs(;
    sitename = "TermInput.jl",
    repo = Remotes.GitHub("vtjnash", "TermInput.jl"),
    modules = [TermInput],
    format = Documenter.HTML(; prettyurls = get(ENV, "CI", nothing) == "true",
                             edit_link = "main"),
    pages = ["Manual" => "index.md", "API" => "api.md", "Keys" => "keys.md",
             "Internals" => "internals.md"],
)

deploydocs(; repo = "github.com/vtjnash/TermInput.jl.git", devbranch = "main",
           push_preview = false)
