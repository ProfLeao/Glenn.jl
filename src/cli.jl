"""
    cli.jl — Command-line interface for Glenn.jl.

Provides a Julia-based CLI entry point via `julia --project -e 'using Glenn; Glenn.cli_main()' --`
or through a script.

# Usage

    julia --project -e 'using Glenn; Glenn.cli_main()' -- build -i thermo.inp -o thermo.db
    julia --project -e 'using Glenn; Glenn.cli_main()' -- query -s O2
"""
module CLI

using Printf
using ..ThermoDatabase
using ..ThermoCalculator
using ..ThermoBuilder

# ------------------------------------------------------------------
# Helper: parse command-line arguments (lightweight, no external deps)
# ------------------------------------------------------------------

"""
    parse_cli_args(args::Vector{String}) -> Dict

Parse CLI arguments into a structured Dict.

# Commands

- `build` — Convert thermo.inp → SQLite database
  - `-i, --input`  : Input FORTRAN file (default: thermo.inp)
  - `-o, --output` : Output SQLite database (default: thermo.db)
  - `-v, --verbose`: Enable verbose (DEBUG) logging

- `query` — Run example queries against the database
  - `-d, --database`: SQLite database file (default: bundled thermo.db)
  - `-s, --species` : Species name pattern to search (default: O2)
  - `-v, --verbose` : Enable verbose (DEBUG) logging
"""
function parse_cli_args(args::Vector{String})
    # Use bundled paths as defaults
    bundled_db = normpath(joinpath(@__DIR__, "..", "data", "thermo.db"))
    bundled_inp = normpath(joinpath(@__DIR__, "..", "data", "thermo.inp"))

    result = Dict{String, Any}(
        "command" => nothing,
        "verbose" => false,
        "input" => bundled_inp,
        "output" => "thermo.db",
        "database" => bundled_db,
        "species" => "O2",
    )

    i = 1
    while i <= length(args)
        arg = args[i]

        if arg in ("build", "query")
            result["command"] = arg
        elseif arg in ("-v", "--verbose")
            result["verbose"] = true
        elseif arg in ("-i", "--input")
            i += 1
            if i <= length(args)
                result["input"] = args[i]
            end
        elseif arg in ("-o", "--output")
            i += 1
            if i <= length(args)
                result["output"] = args[i]
            end
        elseif arg in ("-d", "--database")
            i += 1
            if i <= length(args)
                result["database"] = args[i]
            end
        elseif arg in ("-s", "--species")
            i += 1
            if i <= length(args)
                result["species"] = args[i]
            end
        elseif arg in ("-h", "--help")
            result["command"] = "help"
        end

        i += 1
    end

    return result
end

# ------------------------------------------------------------------
# Build command
# ------------------------------------------------------------------

"""
    cmd_build(args::Dict)

Build the SQLite database from a thermo.inp file.
"""
function cmd_build(args::Dict)
    println(repeat("=", 70))
    println("CONVERTING thermo.inp → SQLite3")
    println(repeat("=", 70))

    inp_file = args["input"]::String
    out_file = args["output"]::String

    if !isfile(inp_file)
        println(stderr, "Error: Input file not found: $inp_file")
        return
    end

    builder = ThermoBuilder.ThermoDBBuilder(inp_file, out_file)
    try
        ThermoBuilder.connect(builder)
        ThermoBuilder.create_tables(builder)
        ThermoBuilder.parse_and_load(builder)

        conn = builder.conn
        if conn !== nothing
            total_species = first(SQLite.DBInterface.execute(conn,
                "SELECT COUNT(*) FROM species"))
            total_intervals = first(SQLite.DBInterface.execute(conn,
                "SELECT COUNT(*) FROM temperature_intervals"))
            total_coeffs = first(SQLite.DBInterface.execute(conn,
                "SELECT COUNT(*) FROM coefficients"))

            println("\nDatabase Statistics:")
            println("  Species: $(total_species[1])")
            println("  Temperature Intervals: $(total_intervals[1])")
            println("  Coefficient Sets: $(total_coeffs[1])")
        end

        println("\n[SUCCESS] Conversion completed!")
    finally
        ThermoBuilder.close(builder)
    end
end

# ------------------------------------------------------------------
# Query command
# ------------------------------------------------------------------

"""
    cmd_query(args::Dict)

Run example queries against the database.
"""
function cmd_query(args::Dict)
    println(repeat("=", 70))
    println("THERMO.DB QUERY EXAMPLES")
    println(repeat("=", 70))

    db_file = args["database"]::String
    pattern = args["species"]::String

    if !isfile(db_file)
        println(stderr, "Error: Database file not found: $db_file")
        return
    end

    calc = ThermoCalculator.Calculator(db_file)

    try
        # 1. Statistics
        println("\n1. DATABASE STATISTICS:")
        println(repeat("-", 70))
        stats = ThermoDatabase.get_statistics(calc.db)
        println("  Total species: $(stats["total_species"])")
        println("  Total intervals: $(stats["total_intervals"])")
        println("  Total coefficient sets: $(stats["total_coeff_sets"])")
        println("  Species by phase: $(stats["species_by_phase"])")
        println("  Average molecular weight: $(round(stats["avg_molecular_weight"], digits=2)) g/mol")

        # 2. Search
        println("\n2. SPECIES SEARCH ('$pattern'):")
        println(repeat("-", 70))
        species_list = ThermoCalculator.get_available_species(calc, pattern)
        for sp in Iterators.take(species_list, 5)
            @printf("  ID: %4d | Name: %-20s | Phase: %-10s | MW: %s\n",
                sp.id, sp.name, sp.phase, sp.molecular_weight)
        end

        # 3. Properties
        if !isempty(species_list)
            species_id = species_list[1].id
            species_name = species_list[1].name
            println("\n3. PROPERTIES FOR $species_name:")
            println(repeat("-", 70))
            @printf("  %8s | %14s | %14s | %14s\n",
                "T (K)", "Cp (J/mol·K)", "H° (J/mol)", "S° (J/mol·K)")
            println(repeat("-", 70))

            for T in [298.15, 500.0, 1000.0, 1500.0]
                props = ThermoCalculator.calculate_properties(calc, species_id, T)
                @printf("  %8.2f | %14.3f | %14.1f | %14.3f\n",
                    props.temperature, props.cp,
                    props.h_relative, props.s)
                end
            end

            h_f = ThermoCalculator.calculate_formation_enthalpy(calc, species_id)
            if h_f !== nothing
                println("\n  H°_f(298.15 K) = $(round(h_f, digits=1)) J/mol")
            end
        end

        println("\n" * repeat("=", 70))
        println("[SUCCESS] Queries completed!")
    finally
        Base.close(calc)
    end
end

# ------------------------------------------------------------------
# Help
# ------------------------------------------------------------------

"""
    print_help()

Print CLI usage information.
"""
function print_help()
    println("""
Glenn.jl — Thermochemical Properties Calculator

USAGE:
    julia --project -e 'using Glenn; Glenn.cli_main()' -- <command> [options]

COMMANDS:
    build       Convert thermo.inp → SQLite3 database
    query       Run example queries against the database

BUILD OPTIONS:
    -i, --input <file>    Input FORTRAN file (default: bundled thermo.inp)
    -o, --output <file>   Output SQLite database (default: thermo.db)
    -v, --verbose         Enable verbose logging

QUERY OPTIONS:
    -d, --database <file> SQLite database file (default: bundled thermo.db)
    -s, --species <name>  Species name pattern to search (default: O2)
    -v, --verbose         Enable verbose logging

EXAMPLES:
    # Build database from bundled thermo.inp
    julia --project -e 'using Glenn; Glenn.cli_main()' -- build

    # Build from custom input
    julia --project -e 'using Glenn; Glenn.cli_main()' -- build -i my_thermo.inp -o my_thermo.db

    # Query species properties (uses bundled thermo.db)
    julia --project -e 'using Glenn; Glenn.cli_main()' -- query -s CH4

    # Query with custom database
    julia --project -e 'using Glenn; Glenn.cli_main()' -- query -d my_thermo.db -s CO2
""")
end

# ------------------------------------------------------------------
# Main entry point
# ------------------------------------------------------------------

"""
    cli_main(args::Vector{String}=ARGS)

Main CLI entry point. Parses arguments and dispatches to the
appropriate subcommand.
"""
function cli_main(args::Vector{String}=String[])
    if isempty(args)
        print_help()
        return
    end

    parsed = parse_cli_args(args)

    command = parsed["command"]

    if command == "help" || command === nothing
        print_help()
    elseif command == "build"
        cmd_build(parsed)
    elseif command == "query"
        cmd_query(parsed)
    else
        println(stderr, "Unknown command: $command")
        print_help()
    end
end

end # module CLI
