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
        assets = ["assets/logo_glennjl.png"],
    ),
    pages = [
        "Home" => "index.md",
        "API Reference" => [
            "Calculator" => "calculator.md",
            "Database" => "database.md",
            "Builder" => "builder.md",
            "CLI" => "cli.md",
        ],
        "Examples" => [
            "Basic Usage" => "examples/basic_usage.md",
            "Fuel Comparison" => "examples/fuel_comparison.md",
        ],
    ],
    warnonly = [:missing_docs, :cross_references],
)

deploydocs(
    repo = "github.com/ProfLeao/Glenn.jl.git",
    devbranch = "main",
)
