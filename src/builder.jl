"""
    builder.jl — Database builder: converts thermo.inp (NASA FORTRAN format) → SQLite3.

Parses NASA-format `thermo.inp` files (FORTRAN Appendix C) and populates
a SQLite3 database with the same normalized schema used by `pyglenn`.

# FORTRAN Record Structure (Appendix C)

| Record | Content |
|--------|---------|
| RECORD 1 | Species identification (name, comments) |
| RECORD 2 | General information (num_intervals, ref_code, phase, MW, ΔH°f) |
| RECORD 3 | Temperature interval definition (T_min, T_max, H_298→0) |
| RECORD 4 | First 5 polynomial coefficients (a₁–a₅) |
| RECORD 5 | Last 2 coefficients + integration constants (a₆, a₇, b₁, b₂) |

Records 3–5 repeat for each temperature interval.
"""
module ThermoBuilder

using SQLite
using Logging

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

    SQLite.execute(conn, """
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
    """)

    SQLite.execute(conn, """
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
    """)

    SQLite.execute(conn, """
        CREATE TABLE IF NOT EXISTS coefficients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            interval_id INTEGER NOT NULL UNIQUE,
            a1 REAL, a2 REAL, a3 REAL, a4 REAL, a5 REAL,
            a6 REAL, a7 REAL,
            b1 REAL, b2 REAL,
            FOREIGN KEY (interval_id)
                REFERENCES temperature_intervals(id) ON DELETE CASCADE
        )
    """)

    SQLite.execute(conn, """
        CREATE TABLE IF NOT EXISTS file_metadata (
            id INTEGER PRIMARY KEY,
            temp_min_global REAL,
            temp_500_K REAL,
            temp_1500_K REAL,
            temp_max_global REAL,
            reference_date TEXT,
            total_species INTEGER
        )
    """)
end

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

        hf_str = length(line) > 80 ? strip(line[66:80]) : (length(line) > 65 ? strip(line[66:end]) : "")
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
    h298_str = length(line) > 80 ? strip(line[66:80]) : (length(line) > 65 ? strip(line[66:end]) : "")

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
        coeffs["a5"] = parse_float(length(line4) >= 80 ? line4[65:80] : (length(line4) >= 64 ? line4[65:end] : ""))
    end

    if length(lines) >= 2
        line5 = lines[2]
        coeffs["a6"] = parse_float(length(line5) >= 16 ? line5[1:16] : line5)
        coeffs["a7"] = parse_float(length(line5) >= 32 ? line5[17:32] : "")
        coeffs["b1"] = parse_float(length(line5) >= 64 ? line5[49:64] : "")
        coeffs["b2"] = parse_float(length(line5) >= 80 ? line5[65:80] : (length(line5) >= 64 ? line5[65:end] : ""))
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

# ------------------------------------------------------------------
# Main parse & load
# ------------------------------------------------------------------

"""
    parse_and_load(builder::ThermoDBBuilder)

Parse the thermo.inp file and populate the database.

Reads the FORTRAN file line by line, detects record types,
extracts species data, temperature intervals, and polynomial
coefficients, then inserts everything into the normalized
SQLite schema.
"""
function parse_and_load(builder::ThermoDBBuilder)
    conn = builder.conn
    @assert conn !== nothing "Database not connected"

    lines = read_thermo_file(builder.inp_file)

    if isempty(lines)
        @warn "Empty thermo.inp file!"
        return
    end

    # --- Global metadata (line index 2, 1-based) ---
    if length(lines) >= 2
        metadata_line = lines[2]
        parts = split(metadata_line)
        if length(parts) >= 4
            SQLite.execute(conn, """
                INSERT OR REPLACE INTO file_metadata
                    (id, temp_min_global, temp_500_K, temp_1500_K,
                     temp_max_global, reference_date)
                VALUES (1, ?, ?, ?, ?, ?)
            """, (
                parse_float(parts[1]),
                parse_float(parts[2]),
                parse_float(parts[3]),
                parse_float(parts[4]),
                length(parts) > 4 ? parts[5] : nothing,
            ))
        end
    end

    # --- Species loop ---
    i = 3  # 1-based index (skip THERMO header + metadata)
    species_count = 0
    skipped = 0

    while i <= length(lines)
        try
            # RECORD 1 – species name
            if i > length(lines)
                break
            end

            species_name, comments = parse_species_record(lines[i])

            if isempty(species_name) ||
               length(split(species_name)) > 1 ||
               is_temperature_line(lines[i])
                i += 1
                skipped += 1
                continue
            end

            @info "Processing species: $species_name"
            i += 1

            # RECORD 2 – general info
            if i > length(lines)
                break
            end
            general_info = parse_general_info_record(lines[i])
            i += 1

            if get(general_info, "num_intervals", 0) <= 0
                skipped += 1
                continue
            end

            # Insert species
            species_id = nothing
            try
                SQLite.execute(conn, """
                    INSERT INTO species
                        (name, comments, reference_code, phase,
                         molecular_weight, heat_of_formation_298K,
                         num_intervals)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, (
                    species_name,
                    comments,
                    get(general_info, "ref_code", nothing),
                    get(general_info, "phase", "gas"),
                    get(general_info, "molecular_weight", nothing),
                    get(general_info, "heat_of_formation", nothing),
                    get(general_info, "num_intervals", 0),
                ))
                species_id = SQLite.last_insert_rowid(conn)
                species_count += 1
            catch e
                if e isa SQLite.SQLiteException
                    # Species might already exist, try to get its id
                    result = SQLite.DBInterface.execute(conn,
                        "SELECT id FROM species WHERE name = ?", (species_name,))
                    for row in result
                        species_id = row[1]
                        break
                    end
                    if species_id === nothing
                        skipped += 1
                        continue
                    end
                else
                    rethrow(e)
                end
            end

            if species_id === nothing
                skipped += 1
                continue
            end

            # --- Temperature intervals ---
            num_intervals = get(general_info, "num_intervals", 0)

            for interval_num in 0:(num_intervals - 1)
                if i > length(lines)
                    break
                end

                if !is_temperature_line(lines[i])
                    break
                end

                temp_interval = parse_temp_interval_record(lines[i])
                i += 1

                if i + 1 > length(lines)
                    break
                end

                if !(is_coefficient_line(lines[i]) &&
                     is_coefficient_line(lines[i + 1]))
                    break
                end

                coeffs = parse_coefficients_record([lines[i], lines[i + 1]])
                i += 2

                if get(temp_interval, "temp_min", nothing) === nothing ||
                   get(temp_interval, "temp_max", nothing) === nothing
                    continue
                end

                try
                    SQLite.execute(conn, """
                        INSERT INTO temperature_intervals
                            (species_id, interval_number, temp_min,
                             temp_max, h_298_to_0)
                        VALUES (?, ?, ?, ?, ?)
                    """, (
                        species_id,
                        interval_num + 1,
                        get(temp_interval, "temp_min", nothing),
                        get(temp_interval, "temp_max", nothing),
                        get(temp_interval, "h_298_to_0", nothing),
                    ))
                    interval_id = SQLite.last_insert_rowid(conn)

                    SQLite.execute(conn, """
                        INSERT INTO coefficients
                            (interval_id, a1, a2, a3, a4, a5,
                             a6, a7, b1, b2)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, (
                        interval_id,
                        get(coeffs, "a1", nothing),
                        get(coeffs, "a2", nothing),
                        get(coeffs, "a3", nothing),
                        get(coeffs, "a4", nothing),
                        get(coeffs, "a5", nothing),
                        get(coeffs, "a6", nothing),
                        get(coeffs, "a7", nothing),
                        get(coeffs, "b1", nothing),
                        get(coeffs, "b2", nothing),
                    ))

                    @debug "  Interval $(interval_num + 1): $(temp_interval["temp_min"])K - $(temp_interval["temp_max"])K"
                catch e
                    @warn "Error inserting interval $(interval_num + 1): $e"
                end
            end

        catch e
            @warn "Error processing line $i: $e"
            i += 1
        end
    end

    # Final metadata update
    SQLite.execute(conn,
        "UPDATE file_metadata SET total_species = ? WHERE id = 1",
        (species_count,))

    @info repeat("=", 70)
    @info "Total species loaded: $species_count"
    @info "Skipped lines: $skipped"
    @info "Database: $(builder.db_file)"
end

end # module ThermoBuilder
