"""
    builder.jl — Database builder: converts thermo.inp (NASA FORTRAN format) → SQLite3.

Parses NASA-format `thermo.inp` files (FORTRAN Appendix C) and populates
a SQLite3 database with the same normalized schema used by `pyglenn`.

# FORTRAN Record Structure (Appendix C)

| Record   | Content                                                        |
|:-------- |:-------------------------------------------------------------- |
| RECORD 1 | Species identification (name, comments)                        |
| RECORD 2 | General information (num_intervals, ref_code, phase, MW, ΔH°f) |
| RECORD 3 | Temperature interval definition (T_min, T_max, H_298→0)        |
| RECORD 4 | First 5 polynomial coefficients (a₁–a₅)                        |
| RECORD 5 | Last 2 coefficients + integration constants (a₆, a₇, b₁, b₂)   |

Records 3–5 repeat for each temperature interval.
"""
module ThermoBuilder

using SQLite
using Logging
using ..ThermoDatabase: R_GLENN, ThermoDB

# ------------------------------------------------------------------
# Regex: match FORTRAN double-precision scientific notation (e.g. 1.234567890D+05)
# ------------------------------------------------------------------
const _FORTRAN_D_RE = r"\d\.\d{0,9}D[+\-]\d{1,2}"i

# ------------------------------------------------------------------
# ThermoDBBuilder struct
# ------------------------------------------------------------------

"""
    ThermoDBBuilder

Builds a SQLite database from a `thermo.inp` file (NASA FORTRAN format).

# Example

```julia
builder = ThermoDBBuilder("thermo.inp", "thermo.db")
connect(builder)
create_tables(builder)
parse_and_load(builder)
close(builder)
```
"""
mutable struct ThermoDBBuilder
    inp_file::String
    db_file::String
    conn::Union{SQLite.DB, Nothing}
end

"""
    ThermoDBBuilder(inp_file::AbstractString, db_file::AbstractString) -> ThermoDBBuilder

Create a new builder for converting `inp_file` (thermo.inp) to `db_file` (SQLite).
"""
function ThermoDBBuilder(inp_file::AbstractString, db_file::AbstractString)
    return ThermoDBBuilder(String(inp_file), String(db_file), nothing)
end

# ------------------------------------------------------------------
# Database lifecycle
# ------------------------------------------------------------------

"""
    connect(builder::ThermoDBBuilder)

Connect to (or create) the SQLite database.
"""
function connect(builder::ThermoDBBuilder)
    builder.conn = SQLite.DB(builder.db_file)
    SQLite.execute(builder.conn, "PRAGMA foreign_keys = ON")
    SQLite.execute(builder.conn, "PRAGMA journal_mode = WAL")
end

"""
    close(builder::ThermoDBBuilder)

Close the database connection and commit changes.
"""
function Base.close(builder::ThermoDBBuilder)
    if builder.conn !== nothing && isopen(builder.conn)
        SQLite.close(builder.conn)
    end
    builder.conn = nothing
end

# ------------------------------------------------------------------
# Schema
# ------------------------------------------------------------------

"""
    create_tables(builder::ThermoDBBuilder)

Create the normalized table structure in the database.
"""
function create_tables(builder::ThermoDBBuilder)
    conn = builder.conn
    @assert conn !== nothing "Database not connected"

    SQLite.execute(
        conn,
        """
    CREATE TABLE IF NOT EXISTS species (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        formula TEXT,
        comments TEXT,
        reference_code TEXT,
        phase TEXT CHECK(phase IN ('gas', 'condensed')),
        molecular_weight REAL,
        heat_of_formation_298K REAL,
        num_intervals INTEGER,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
""",
    )

    SQLite.execute(
        conn,
        """
    CREATE TABLE IF NOT EXISTS temperature_intervals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        species_id INTEGER NOT NULL,
        interval_number INTEGER NOT NULL,
        temp_min REAL NOT NULL,
        temp_max REAL NOT NULL,
        h_298_to_0 REAL,
        FOREIGN KEY (species_id)
            REFERENCES species(id) ON DELETE CASCADE,
        UNIQUE(species_id, interval_number)
    )
""",
    )

    SQLite.execute(
        conn,
        """
    CREATE TABLE IF NOT EXISTS coefficients (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        interval_id INTEGER NOT NULL UNIQUE,
        a1 REAL, a2 REAL, a3 REAL, a4 REAL, a5 REAL,
        a6 REAL, a7 REAL,
        b1 REAL, b2 REAL,
        FOREIGN KEY (interval_id)
            REFERENCES temperature_intervals(id) ON DELETE CASCADE
    )
""",
    )

    SQLite.execute(
        conn,
        """
    CREATE TABLE IF NOT EXISTS file_metadata (
        id INTEGER PRIMARY KEY,
        temp_min_global REAL,
        temp_500_K REAL,
        temp_1500_K REAL,
        temp_max_global REAL,
        reference_date TEXT,
        total_species INTEGER
    )
""",
    )

    SQLite.execute(
        conn,
        """
    CREATE TABLE IF NOT EXISTS metadata (
        key   TEXT PRIMARY KEY,
        value TEXT
    )
""",
    )
end

"""
    write_metadata(builder::ThermoDBBuilder)

Write the dataset reference gas constant into the `metadata` table.

The bundled NASA Glenn/CEA polynomials were fitted with `R_GLENN = 8.314510`
(CODATA 1986, NASA TP-2002-211556). Uses `INSERT OR REPLACE` for idempotency.
"""
function write_metadata(builder::ThermoDBBuilder)
    conn = builder.conn
    @assert conn !== nothing "Database not connected"

    SQLite.execute(
        conn,
        """
        INSERT OR REPLACE INTO metadata (key, value)
        VALUES ('gas_constant_ref', ?), ('gas_constant_ref_source', ?);
        """,
        (string(R_GLENN), "NASA TP-2002-211556 (CODATA 1986)"),
    )
end

"""
    migrate_metadata!(db::SQLite.DB)
    migrate_metadata!(tdb::ThermoDB)

Self-contained migration for legacy databases that predate the `metadata` table.

Creates the table (if missing) and writes `gas_constant_ref = R_GLENN`, so that
older databases are denormalised with the NASA Glenn reference constant instead
of falling back to `R_UNIVERSAL`.
"""
function migrate_metadata!(db::SQLite.DB)
    SQLite.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS metadata (
        key   TEXT PRIMARY KEY,
        value TEXT
    )
""",
    )

    SQLite.execute(
        db,
        """
        INSERT OR REPLACE INTO metadata (key, value)
        VALUES ('gas_constant_ref', ?), ('gas_constant_ref_source', ?);
        """,
        (string(R_GLENN), "NASA TP-2002-211556 (CODATA 1986)"),
    )
    return nothing
end

migrate_metadata!(tdb::ThermoDB) = migrate_metadata!(tdb.db)

# ------------------------------------------------------------------
# Low-level parsers
# ------------------------------------------------------------------

"""
    parse_float(value::AbstractString) -> Union{Float64, Nothing}

Parse a FORTRAN-style float ('D' → 'E' notation).
Returns `nothing` if parsing fails.
"""
function parse_float(value::AbstractString)
    stripped = strip(value)
    if isempty(stripped)
        return nothing
    end
    try
        # Replace FORTRAN D/d notation with E
        normalized = replace(stripped, r"[Dd]" => "E")
        return parse(Float64, normalized)
    catch
        return nothing
    end
end

"""
    parse_species_record(line::AbstractString) -> Tuple{String, String}

Extract species name (cols 1-16) and comments (cols 19-80) from RECORD 1.

Returns `(species_name, comments)`.
"""
function parse_species_record(line::AbstractString)
    name = length(line) > 16 ? strip(line[1:16]) : strip(line)
    comments = length(line) > 18 ? strip(line[19:min(end, 80)]) : ""
    return name, comments
end

"""
    parse_general_info_record(line::AbstractString) -> Dict{String, Any}

Parse RECORD 2 – general information.

Returns a Dict with keys: `num_intervals`, `ref_code`, `phase`,
`molecular_weight`, `heat_of_formation`.
"""
function parse_general_info_record(line::AbstractString)
    data = Dict{String, Any}()

    try
        num_int_str = length(line) > 2 ? strip(line[1:2]) : ""
        data["num_intervals"] = tryparse(Int, num_int_str) |> x -> x === nothing ? 0 : x

        data["ref_code"] = length(line) > 9 ? strip(line[4:9]) : ""

        phase_code = length(line) > 52 ? strip(line[51:52]) : "0"
        data["phase"] = isempty(phase_code) || phase_code == "0" ? "gas" : "condensed"

        mw_str = length(line) > 65 ? strip(line[53:65]) : ""
        data["molecular_weight"] = parse_float(mw_str)

        hf_str =
            length(line) > 80 ? strip(line[66:80]) :
            (length(line) > 65 ? strip(line[66:end]) : "")
        data["heat_of_formation"] = parse_float(hf_str)
    catch e
        @warn "Error parsing RECORD 2: $e"
    end

    return data
end

"""
    parse_temp_interval_record(line::AbstractString) -> Dict{String, Any}

Parse RECORD 3 – temperature interval.

Returns a Dict with keys: `temp_min`, `temp_max`, `h_298_to_0`.
"""
function parse_temp_interval_record(line::AbstractString)
    data = Dict{String, Any}()

    temp_min_str = length(line) > 11 ? strip(line[1:11]) : ""
    temp_max_str = length(line) > 22 ? strip(line[12:22]) : ""
    h298_str =
        length(line) > 80 ? strip(line[66:80]) :
        (length(line) > 65 ? strip(line[66:end]) : "")

    data["temp_min"] = parse_float(temp_min_str)
    data["temp_max"] = parse_float(temp_max_str)
    data["h_298_to_0"] = parse_float(h298_str)

    return data
end

"""
    parse_coefficients_record(lines::Vector{<:AbstractString}) -> Dict{String, Any}

Parse RECORDS 4-5 – polynomial coefficients.

Line 4: a₁[1:16], a₂[17:32], a₃[33:48], a₄[49:64], a₅[65:80]
Line 5: a₆[1:16], a₇[17:32], (skip 33:48), b₁[49:64], b₂[65:80]

Returns a Dict with keys: `a1`–`a7`, `b1`, `b2`.
"""
function parse_coefficients_record(lines::Vector{<:AbstractString})
    coeffs = Dict{String, Any}()

    if length(lines) >= 1
        line4 = lines[1]
        coeffs["a1"] = parse_float(length(line4) >= 16 ? line4[1:16] : line4)
        coeffs["a2"] = parse_float(length(line4) >= 32 ? line4[17:32] : "")
        coeffs["a3"] = parse_float(length(line4) >= 48 ? line4[33:48] : "")
        coeffs["a4"] = parse_float(length(line4) >= 64 ? line4[49:64] : "")
        coeffs["a5"] = parse_float(
            length(line4) >= 80 ? line4[65:80] : (length(line4) >= 64 ? line4[65:end] : ""),
        )
    end

    if length(lines) >= 2
        line5 = lines[2]
        coeffs["a6"] = parse_float(length(line5) >= 16 ? line5[1:16] : line5)
        coeffs["a7"] = parse_float(length(line5) >= 32 ? line5[17:32] : "")
        coeffs["b1"] = parse_float(length(line5) >= 64 ? line5[49:64] : "")
        coeffs["b2"] = parse_float(
            length(line5) >= 80 ? line5[65:80] : (length(line5) >= 64 ? line5[65:end] : ""),
        )
    end

    return coeffs
end

# ------------------------------------------------------------------
# File reading & line-type detection
# ------------------------------------------------------------------

"""
    read_thermo_file(inp_file::AbstractString) -> Vector{String}

Read thermo.inp, stripping comments (lines starting with '!') and blank lines.
"""
function read_thermo_file(inp_file::AbstractString)
    lines = String[]
    open(inp_file, "r") do f
        for line in eachline(f)
            stripped = strip(line)
            if !isempty(stripped) && !startswith(stripped, "!")
                push!(lines, rstrip(line, ['\r', '\n']))
            end
        end
    end
    return lines
end

"""
    is_temperature_line(line::AbstractString) -> Bool

Detect RECORD 3 (temperature interval).

A temperature line has two valid floats in cols 1-11 and 12-22
where the first is strictly less than the second.
"""
function is_temperature_line(line::AbstractString)
    if length(line) < 22
        return false
    end
    try
        t1 = parse_float(line[1:11])
        t2 = parse_float(line[12:22])
        return t1 !== nothing && t2 !== nothing && t1 < t2
    catch
        return false
    end
end

"""
    is_coefficient_line(line::AbstractString) -> Bool

Detect coefficient lines containing FORTRAN D notation.

Uses regex to match the standard FORTRAN double-precision format
(e.g. `1.23456789D+01`).
"""
function is_coefficient_line(line::AbstractString)
    return occursin(_FORTRAN_D_RE, line)
end

"""
    is_species_header(line::AbstractString) -> Bool

Return whether a line can be a species-identification record (RECORD 1).

A coefficient line can fit entirely inside the fixed-width species-name field,
so it must be rejected explicitly instead of relying on whitespace in the
apparent name.
"""
function is_species_header(line::AbstractString)
    name, _ = parse_species_record(line)
    return !isempty(name) &&
           length(split(name)) == 1 &&
           !is_temperature_line(line) &&
           !is_coefficient_line(line)
end

"""
    _has_finite_coefficients(coeffs::Dict{String, Any}) -> Bool

Return whether a parsed NASA-7 coefficient set is complete (all values present
and finite).
"""
function _has_finite_coefficients(coeffs::Dict{String, Any})
    isempty(coeffs) && return false
    for value in values(coeffs)
        (value isa Real && isfinite(value)) || return false
    end
    return true
end

"""
    _parse_intervals(lines, start, num_intervals) -> Union{Tuple, Nothing}

Parse a complete set of interval records without modifying the database.

Returning `nothing` lets the caller resynchronise at a later verified species
header, so a malformed block can neither create a partial species nor turn
coefficient lines into new species.
"""
function _parse_intervals(lines::Vector{String}, start::Int, num_intervals::Int)
    intervals = Tuple{Dict{String, Any}, Dict{String, Any}}[]
    index = start

    for _ = 1:num_intervals
        if index + 2 > length(lines)
            @warn "Incomplete interval records at line $index"
            return nothing
        end
        if !is_temperature_line(lines[index])
            @warn "Invalid temperature interval record at line $index"
            return nothing
        end

        interval = parse_temp_interval_record(lines[index])
        coeff_lines = lines[(index + 1):(index + 2)]
        if !all(is_coefficient_line, coeff_lines)
            @warn "Invalid coefficient records at line $(index + 1)"
            return nothing
        end

        coeffs = parse_coefficients_record(coeff_lines)
        temp_min = get(interval, "temp_min", nothing)
        temp_max = get(interval, "temp_max", nothing)

        if temp_min === nothing ||
           temp_max === nothing ||
           !isfinite(temp_min) ||
           !isfinite(temp_max) ||
           temp_min >= temp_max ||
           !_has_finite_coefficients(coeffs)
            @warn "Invalid interval values at line $index"
            return nothing
        end

        push!(intervals, (interval, coeffs))
        index += 3
    end

    return intervals, index
end

# ------------------------------------------------------------------
# Main parse & load
# ------------------------------------------------------------------

"""
    _insert_interval(conn, species_id, interval_number, interval, coeffs)

Insert one temperature interval and its NASA-7 coefficient set.
"""
function _insert_interval(
    conn,
    species_id::Integer,
    interval_number::Integer,
    interval::Dict{String, Any},
    coeffs::Dict{String, Any},
)
    SQLite.execute(
        conn,
        """
           INSERT INTO temperature_intervals
               (species_id, interval_number, temp_min,
                temp_max, h_298_to_0)
           VALUES (?, ?, ?, ?, ?)
       """,
        (
            species_id,
            interval_number,
            interval["temp_min"],
            interval["temp_max"],
            get(interval, "h_298_to_0", nothing),
        ),
    )
    interval_id = SQLite.last_insert_rowid(conn)

    SQLite.execute(
        conn,
        """
           INSERT INTO coefficients
               (interval_id, a1, a2, a3, a4, a5,
                a6, a7, b1, b2)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       """,
        (
            interval_id,
            coeffs["a1"],
            coeffs["a2"],
            coeffs["a3"],
            coeffs["a4"],
            coeffs["a5"],
            coeffs["a6"],
            coeffs["a7"],
            coeffs["b1"],
            coeffs["b2"],
        ),
    )
    return interval_id
end

"""
    _merge_intervals(conn, species_id, species_name, intervals) -> Int

Append the intervals of a repeated species record to the species already
stored under that name.

`thermo.inp` splits some condensed substances into several records that reuse
the same name — for example `Cr(cr)` appears once `Below lambda trans.` and once
`Above lambda trans.`, and `Cr2O3(I)` appears three times. Keeping only the
first record leaves those substances without their high-temperature range.

Intervals whose bounds coincide with, or overlap, an already stored range are
skipped with a warning, so a duplicated record can never corrupt the data.
Returns the number of intervals added.
"""
function _merge_intervals(
    conn,
    species_id::Integer,
    species_name::AbstractString,
    intervals::Vector{Tuple{Dict{String, Any}, Dict{String, Any}}},
)
    existing = Tuple{Float64, Float64}[]
    next_number = 1
    for row in SQLite.DBInterface.execute(
        conn,
        """
        SELECT interval_number, temp_min, temp_max
        FROM temperature_intervals WHERE species_id = ?
        ORDER BY interval_number
        """,
        (species_id,),
    )
        push!(existing, (Float64(row[2]), Float64(row[3])))
        next_number = max(next_number, Int(row[1]) + 1)
    end

    added = 0
    for (interval, coeffs) in intervals
        temp_min = Float64(interval["temp_min"])
        temp_max = Float64(interval["temp_max"])

        if any(b -> isapprox(b[1], temp_min) && isapprox(b[2], temp_max), existing)
            @debug "Skipping duplicate interval [$temp_min, $temp_max] for '$species_name'"
            continue
        end
        if any(b -> temp_min < b[2] && temp_max > b[1], existing)
            @warn "Skipping overlapping interval [$temp_min, $temp_max] for '$species_name'"
            continue
        end

        _insert_interval(conn, species_id, next_number, interval, coeffs)
        push!(existing, (temp_min, temp_max))
        next_number += 1
        added += 1
    end

    if added > 0
        SQLite.execute(
            conn,
            "UPDATE species SET num_intervals = ? WHERE id = ?",
            (length(existing), species_id),
        )
    end

    return added
end

"""
    parse_and_load(builder::ThermoDBBuilder; merge_duplicates::Bool=true)

Parse the thermo.inp file and populate the database.

Reads the FORTRAN file line by line, detects record types,
extracts species data, temperature intervals, and polynomial
coefficients, then inserts everything into the normalized
SQLite schema.

A species is inserted only after every declared interval and its two coefficient
records have been parsed and validated, so malformed blocks are skipped without
leaving partial rows behind.

Some condensed substances appear as several records that reuse the same name
(phase transitions, e.g. `Cr(cr)` below/above the lambda transformation). With
`merge_duplicates=true` (default) the extra records are appended as additional
temperature intervals, so the full temperature range stays available. Set it to
`false` to keep only the first record, matching the reference implementation.
"""
function parse_and_load(builder::ThermoDBBuilder; merge_duplicates::Bool = true)
    conn = builder.conn
    @assert conn !== nothing "Database not connected"

    lines = read_thermo_file(builder.inp_file)

    if isempty(lines)
        @warn "Empty thermo.inp file!"
        return
    end

    # Wrap all inserts in a transaction for massive performance gain
    SQLite.execute(conn, "BEGIN")
    species_count = 0
    skipped = 0

    try
        # --- Global metadata (line index 2, 1-based) ---
        if length(lines) >= 2
            metadata_line = lines[2]
            parts = split(metadata_line)
            if length(parts) >= 4
                SQLite.execute(
                    conn,
                    """
    INSERT OR REPLACE INTO file_metadata
        (id, temp_min_global, temp_500_K, temp_1500_K,
         temp_max_global, reference_date)
    VALUES (1, ?, ?, ?, ?, ?)
""",
                    (
                        parse_float(parts[1]),
                        parse_float(parts[2]),
                        parse_float(parts[3]),
                        parse_float(parts[4]),
                        length(parts) > 4 ? parts[5] : nothing,
                    ),
                )
            end
        end

        # --- Species loop ---
        species_count = 0
        duplicate_species = 0
        merged_intervals = 0
        skipped = 0
        i = 3  # 1-based index (skip THERMO header + metadata)

        while i <= length(lines)
            # Advance until a verified species header (RECORD 1).
            if !is_species_header(lines[i]) || i + 1 > length(lines)
                i += 1
                continue
            end

            species_name, comments = parse_species_record(lines[i])
            general_info = parse_general_info_record(lines[i+1])
            num_intervals = get(general_info, "num_intervals", 0)

            if !(num_intervals isa Integer) || num_intervals <= 0
                i += 1
                continue
            end

            parsed = _parse_intervals(lines, i + 2, num_intervals)
            if parsed === nothing
                @warn "Skipping malformed species block at line $i: $species_name"
                skipped += 1
                i += 1  # resynchronise at the next verified species header
                continue
            end

            intervals, next_index = parsed

            # Insert the species only after every interval has been validated,
            # so a malformed block leaves no partial species behind.
            species_id = nothing
            inserted = false
            try
                SQLite.execute(
                    conn,
                    """
       INSERT INTO species
           (name, comments, reference_code, phase,
            molecular_weight, heat_of_formation_298K,
            num_intervals)
       VALUES (?, ?, ?, ?, ?, ?, ?)
   """,
                    (
                        species_name,
                        comments,
                        get(general_info, "ref_code", nothing),
                        get(general_info, "phase", "gas"),
                        get(general_info, "molecular_weight", nothing),
                        get(general_info, "heat_of_formation", nothing),
                        num_intervals,
                    ),
                )
                species_id = SQLite.last_insert_rowid(conn)
                inserted = true
            catch e
                if e isa SQLite.SQLiteException
                    # Species already present: reuse its id, skip intervals.
                    for row in SQLite.DBInterface.execute(
                        conn,
                        "SELECT id FROM species WHERE name = ?",
                        (species_name,),
                    )
                        species_id = row[1]
                        break
                    end
                    if species_id === nothing
                        skipped += 1
                        i += 1
                        continue
                    end
                    duplicate_species += 1
                else
                    rethrow(e)
                end
            end

            if inserted
                for (interval_number, (interval, coeffs)) in enumerate(intervals)
                    _insert_interval(conn, species_id, interval_number, interval, coeffs)
                end
                species_count += 1
                @debug "Loaded species: $species_name"
            elseif merge_duplicates
                merged_intervals +=
                    _merge_intervals(conn, species_id, species_name, intervals)
            end

            i = next_index
        end

        # Final metadata update
        SQLite.execute(
            conn,
            "UPDATE file_metadata SET total_species = ? WHERE id = 1",
            (species_count,),
        )

        # Dataset reference gas constant metadata — inside the transaction, so a
        # failed build rolls the metadata back together with the data.
        write_metadata(builder)

        # Commit the transaction
        SQLite.execute(conn, "COMMIT")

        @info repeat("=", 70)
        @info "New species loaded:       $species_count"
        @info "Repeated species records: $duplicate_species"
        @info "Merged intervals:         $merged_intervals"
        @info "Malformed skipped:        $skipped"
        @info "Database: $(builder.db_file)"

    catch e
        SQLite.execute(conn, "ROLLBACK")
        @error "Build failed, rolling back: $e"
        rethrow(e)
    end
end

"""
    build_database(inp_file, db_file; merge_duplicates::Bool=true) -> String

Build a SQLite thermochemical database from a NASA FORTRAN `thermo.inp` file.

Convenience wrapper around the four-step lifecycle
(`connect` → `create_tables` → `parse_and_load` → `close`), so the connection
is always closed even if parsing fails. Returns the database path.

`merge_duplicates` is forwarded to `parse_and_load`; see its documentation for
how repeated species records (phase transitions) are handled.

# Example

```julia
using Glenn

build_database(default_inp_path(), "thermo.db")
```
"""
function build_database(
    inp_file::AbstractString,
    db_file::AbstractString;
    merge_duplicates::Bool = true,
)
    builder = ThermoDBBuilder(inp_file, db_file)
    try
        connect(builder)
        create_tables(builder)
        parse_and_load(builder; merge_duplicates = merge_duplicates)
    finally
        close(builder)
    end
    return String(db_file)
end

end # module ThermoBuilder
