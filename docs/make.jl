using Documenter
using Glenn

DocMeta.setdocmeta!(
    Glenn,
    :DocTestSetup,
    :(using Glenn; calc = Calculator());
    recursive = true,
)

makedocs(
    modules = [Glenn],
    sitename = "Glenn.jl",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://profl.github.io/Glenn.jl/stable/",
    ),
    pages = [
        "Home" => "index.md",
        "API Reference" => [
            "Calculator" => "calculator.md",
            "Database" => "database.md",
        ],
    ],
    warnonly = [:missing_docs, :cross_references],
)

deploydocs(
    repo = "github.com/ProfLeao/Glenn.jl.git",
    devbranch = "main",
)
