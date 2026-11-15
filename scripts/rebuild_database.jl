#!/usr/bin/env julia
# =====================================================================
# Rebuild the bundled Glenn.jl database from thermo.inp, atomically.
# =====================================================================
# The database is built into a temporary file next to the target, validated,
# and only replaces the bundled `data/thermo.db` after every release gate
# passes. A failed rebuild leaves the previous database untouched.
#
# Usage (from the repository root):
#
#     julia --project=. scripts/rebuild_database.jl
#     julia --project=. scripts/rebuild_database.jl -o /tmp/test.db
#     julia --project=. scripts/rebuild_database.jl --skip-gates --force
#
# Release gates for the canonical NASA Glenn/CEA dataset (thermo.inp 9/09/04).
#
# 2035 species: identical to the reference implementation (pyglenn).
# 3795 intervals: 3779 + 16 intervals recovered from repeated species records
#   (phase-transition blocks such as Cr(cr) below/above the lambda
#   transformation). This is deliberately 16 above the reference implementation,
#   which keeps only the first record of each such substance — see
#   docs/PARSER_FIX_PORTING.md.
# =====================================================================

import Pkg

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(REPO_ROOT; io = devnull)

using Glenn

const DEFAULT_INP = joinpath(REPO_ROOT, "data", "thermo.inp")
const DEFAULT_DB = joinpath(REPO_ROOT, "data", "thermo.db")

const EXPECTED_SPECIES = 2035
const EXPECTED_INTERVALS = 3795
const EXPECTED_COEFFS = 3795

# ------------------------------------------------------------------
# Integrity checks
# ------------------------------------------------------------------

# The checks themselves live in the package (`Glenn.validate_database`), so this
# script and package users run exactly the same validation.

"""
    integrity_report(db_path) -> ValidationReport

Validate a database file with `Glenn.validate_database`.
"""
function integrity_report(db_path::AbstractString)
    tdb = Glenn.ThermoDB(db_path)
    try
        return Glenn.validate_database(tdb)
    finally
        close(tdb)
    end
end

# ------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------

function parse_args(args::Vector{String})
    opts = Dict{String, Any}(
        "input" => DEFAULT_INP,
        "output" => DEFAULT_DB,
        "expected_species" => EXPECTED_SPECIES,
        "expected_intervals" => EXPECTED_INTERVALS,
        "expected_coeffs" => EXPECTED_COEFFS,
        "skip_gates" => false,
        "force" => false,
    )

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg in ("-h", "--help")
            opts["help"] = true
        elseif arg in ("-i", "--input")
            i += 1
            opts["input"] = args[i]
        elseif arg in ("-o", "--output")
            i += 1
            opts["output"] = args[i]
        elseif arg == "--expected-species"
            i += 1
            opts["expected_species"] = parse(Int, args[i])
        elseif arg == "--expected-intervals"
            i += 1
            opts["expected_intervals"] = parse(Int, args[i])
        elseif arg == "--expected-coeffs"
            i += 1
            opts["expected_coeffs"] = parse(Int, args[i])
        elseif arg == "--skip-gates"
            opts["skip_gates"] = true
        elseif arg == "--force"
            opts["force"] = true
        else
            println(stderr, "Unknown argument: $arg")
            opts["help"] = true
        end
        i += 1
    end

    return opts
end

function print_help()
    println("""
    Rebuild the Glenn.jl database from thermo.inp atomically.

    USAGE:
        julia --project=. scripts/rebuild_database.jl [options]

    OPTIONS:
        -i, --input <file>            Input FORTRAN file (default: data/thermo.inp)
        -o, --output <file>           Output database (default: data/thermo.db)
            --expected-species <n>    Release gate (default: $EXPECTED_SPECIES)
            --expected-intervals <n>  Release gate (default: $EXPECTED_INTERVALS)
            --expected-coeffs <n>     Release gate (default: $EXPECTED_COEFFS)
            --skip-gates              Do not enforce the release gates
            --force                   Allow writing when gates are skipped
        -h, --help                    Show this message

    The database is built next to the target and only replaces it after every
    check passes. A failed rebuild leaves the previous database untouched.
    """)
end

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

function main(args::Vector{String} = ARGS)
    opts = parse_args(args)
    if get(opts, "help", false)
        print_help()
        return 0
    end

    inp = String(opts["input"])
    out = abspath(String(opts["output"]))

    if !isfile(inp)
        println(stderr, "ERROR: input file not found: $inp")
        return 1
    end

    if opts["skip_gates"] && !opts["force"] && isfile(out)
        println(stderr, "ERROR: --skip-gates requires --force to overwrite $out")
        return 1
    end

    tmp_db = tempname(dirname(out)) * ".db"
    rm(tmp_db, force = true)

    println("="^70)
    println("GLENN.JL DATABASE REBUILD")
    println("="^70)
    println("  input : $inp")
    println("  output: $out")
    println("  temp  : $tmp_db")
    println()

    try
        build_database(inp, tmp_db)

        report = integrity_report(tmp_db)
        counts = report.counts

        println()
        println("-"^70)
        println("INTEGRITY CHECKS")
        println("-"^70)
        println("  species   : $(get(counts, "total_species", 0))")
        println("  intervals : $(get(counts, "total_intervals", 0))")
        println("  coeff sets: $(get(counts, "total_coeff_sets", 0))")

        for w in report.warnings
            println("  [warn]  $w")
        end
        for e in report.errors
            println("  [error] $e")
        end

        if !report.valid
            println()
            println("FAILED: integrity checks did not pass; $out left untouched.")
            return 1
        end

        gates_ok = true
        if !opts["skip_gates"]
            checks = (
                ("species", get(counts, "total_species", 0), opts["expected_species"]),
                (
                    "intervals",
                    get(counts, "total_intervals", 0),
                    opts["expected_intervals"],
                ),
                (
                    "coeff sets",
                    get(counts, "total_coeff_sets", 0),
                    opts["expected_coeffs"],
                ),
            )
            for (label, actual, expected) in checks
                if actual == expected
                    println("  [gate ok] $label = $actual")
                else
                    println("  [gate FAIL] $label = $actual (expected $expected)")
                    gates_ok = false
                end
            end
        else
            println("  [gates skipped]")
        end

        if !gates_ok
            println()
            println("FAILED: release gates not met; $out left untouched.")
            return 1
        end

        mv(tmp_db, out; force = true)
        println()
        println("SUCCESS: wrote $out")
        return 0
    catch err
        println(stderr, "ERROR: rebuild failed: $err")
        return 1
    finally
        rm(tmp_db, force = true)
        rm(tmp_db * "-wal", force = true)
        rm(tmp_db * "-shm", force = true)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
