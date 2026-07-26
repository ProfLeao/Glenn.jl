#!/usr/bin/env julia
# =====================================================================
# glenn — Command-line interface for Glenn.jl
#
# Usage:
#   julia --project bin/glenn.jl build -i thermo.inp -o thermo.db
#   julia --project bin/glenn.jl query -s O2
#
# If the package is installed, this script can be invoked directly
# from the package directory or copied to a directory in PATH.
# =====================================================================

# Determine the project root (parent of the directory containing this script)
script_dir = @__DIR__
project_root = abspath(joinpath(script_dir, ".."))

# Check if we need to activate the project
if !isdir(joinpath(project_root, "Manifest.toml")) &&
   !isfile(joinpath(project_root, "Manifest.toml"))
    # Try one more level up (if script is in a deeper subdirectory)
    project_root = abspath(joinpath(script_dir, "..", ".."))
end

# Activate the project if not already in a project context
try
    using Glenn
catch
    # If Glenn is not loaded, try to activate the project
    using Pkg
    Pkg.activate(project_root)
    using Glenn
end

# Forward all arguments to the CLI
Glenn.cli_main()
