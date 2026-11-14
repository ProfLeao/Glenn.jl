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
# They match the reference implementation (pyglenn) so both packages ship the
# same dataset.
# =====================================================================

import Pkg

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
Pkg.activate(REPO_ROOT; io = devnull)

using Glenn
using SQLite

const DEFAULT_INP = joinpath(REPO_ROOT, "data", "thermo.inp")
const DEFAULT_DB = joinpath(REPO_ROOT, "data", "thermo.db")

const EXPECTED_SPECIES = 2035
const EXPECTED_INTERVALS = 3779
const EXPECTED_COEFFS = 3779

# ------------------------------------------------------------------
# Integrity checks (read-only)
# ------------------------------------------------------------------

_scalar(db, sql) = first(SQLite.DBInterface.execute(db, sql))[1]

_has_table(db, name) = !isempty(
    collect(
        SQLite.DBInterface.execute(
            db,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
            (name,),
        ),
    ),
)

"""
    integrity_report(db_path) -> NamedTuple

Run read-only integrity checks against a database and return
`(valid, errors, warnings, counts)`.
"""
function integrity_report(db_path::AbstractString)
    errors = String[]
    warnings = String[]
    counts = Dict{String, Int}()

    db = SQLite.DB(db_path)
    try
        required = ("species", "temperature_intervals", "coefficients")
        missing = [t for t in required if !_has_table(db, t)]
        if !isempty(missing)
            push!(errors, "missing required table(s): " * join(missing, ", "))
            return (; valid = false, errors, warnings, counts)
        end

        counts["total_species"] = _scalar(db, "SELECT COUNT(*) FROM species")
        counts["total_intervals"] =
            _scalar(db, "SELECT COUNT(*) FROM temperature_intervals")
        counts["total_coeff_sets"] = _scalar(db, "SELECT COUNT(*) FROM coefficients")

        # Referential integrity
        orphans = _scalar(
            db,
            "SELECT COUNT(*) FROM coefficients c
             LEFT JOIN temperature_intervals ti ON c.interval_id = ti.id
             WHERE ti.id IS NULL",
        )
        orphans > 0 &&
            push!(errors, "$orphans coefficient row(s) reference a missing interval")

        orphans = _scalar(
            db,
            "SELECT COUNT(*) FROM temperature_intervals ti
             LEFT JOIN species s ON ti.species_id = s.id
             WHERE s.id IS NULL",
        )
        orphans > 0 &&
            push!(errors, "$orphans interval row(s) reference a missing species")

        # Exactly one coefficient row per interval
        dup = _scalar(
            db,
            "SELECT COUNT(*) FROM (
                 SELECT interval_id, COUNT(*) AS n FROM coefficients
                 GROUP BY interval_id
             ) WHERE n != 1",
        )
        dup > 0 && push!(
            errors,
            "$dup interval(s) do not have exactly one coefficient row",
        )

        # num_intervals must agree with the rows actually present
        mismatch = _scalar(
            db,
            "SELECT COUNT(*) FROM species s WHERE s.num_intervals != (
                 SELECT COUNT(*) FROM temperature_intervals ti WHERE ti.species_id = s.id
             )",
        )
        mismatch > 0 &&
            push!(errors, "$mismatch species have num_intervals disagreeing with rows")

        # Ordered, finite bounds
        bad_bounds = _scalar(
            db,
            "SELECT COUNT(*) FROM temperature_intervals
             WHERE temp_min IS NULL OR temp_max IS NULL OR temp_min >= temp_max",
        )
        bad_bounds > 0 && push!(errors, "$bad_bounds interval(s) have invalid bounds")

        # Complete coefficient sets
        bad_coeffs = _scalar(
            db,
            "SELECT COUNT(*) FROM coefficients WHERE a1 IS NULL OR a2 IS NULL
             OR a3 IS NULL OR a4 IS NULL OR a5 IS NULL OR a6 IS NULL
             OR a7 IS NULL OR b1 IS NULL OR b2 IS NULL",
        )
        bad_coeffs > 0 && push!(errors, "$bad_coeffs coefficient set(s) contain NULL values")

        # Semantic guard: species names must not look like FORTRAN numbers
        bad_names = _scalar(
            db,
            "SELECT COUNT(*) FROM species WHERE name LIKE '%.%D%' OR name LIKE '%.%E%'",
        )
        bad_names > 0 && push!(
            errors,
            "$bad_names species name(s) look like FORTRAN coefficient tokens",
        )

        # Dataset metadata
        if _has_table(db, "metadata")
            n = _scalar(
                db,
                "SELECT COUNT(*) FROM metadata WHERE key='gas_constant_ref'",
            )
            n == 0 && push!(warnings, "metadata table lacks 'gas_constant_ref'")
        else
            push!(warnings, "database has no 'metadata' table")
        end

        # Known upstream limitation: phase-transition records that reuse a
        # species name are stored only for their first temperature range.
        if _has_table(db, "file_metadata")
            row = collect(
                SQLite.DBInterface.execute(
                    db,
                    "SELECT total_species FROM file_metadata WHERE id = 1",
                ),
            )
            if isempty(row) || row[1][1] === nothing
                push!(warnings, "file_metadata.total_species is not set")
            end
        end

        return (; valid = isempty(errors), errors, warnings, counts)
    finally
        close(db)
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
