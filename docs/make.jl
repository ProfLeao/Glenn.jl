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
        canonical = "https://profleao.github.io/Glenn.jl/",
        assets = ["assets/logo-sidebar.css"],
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

# Manually copy logo PNG for sidebar CSS (not auto-tracked by Documenter)
mkpath(joinpath(@__DIR__, "build", "assets"))
cp(
    joinpath(@__DIR__, "src", "assets", "logo_glennjl.png"),
    joinpath(@__DIR__, "build", "assets", "logo_glennjl.png");
    force=true,
)

# Deploy is handled by GitHub Actions using peaceiris/actions-gh-pages
# (uses GITHUB_TOKEN — no SSH key needed)
