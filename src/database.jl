"""
    database.jl — SQLite query interface for thermochemical data.

Provides database connection, species lookup, and NASA-7 polynomial
calculations (Cp/R, H/RT, S/R) using coefficients stored in thermo.db.
"""
module ThermoDatabase

using SQLite

# ------------------------------------------------------------------
# Physical constant: Universal Gas Constant
# ------------------------------------------------------------------
"""
    const R_UNIVERSAL

Universal Gas Constant in J/(mol·K). Source: CODATA 2018.
"""
const R_UNIVERSAL = 8.314462618

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

"""
    _or_zero(x) -> Float64

Return `x` if not `nothing`, otherwise return 0.0.
"""
_or_zero(x::Nothing) = 0.0
_or_zero(x) = Float64(x)

# ------------------------------------------------------------------
# Database connection & queries
# ------------------------------------------------------------------

"""
    ThermoDB

Handle to an open thermochemical SQLite3 database.
"""
mutable struct ThermoDB
    db::SQLite.DB
    path::String
end

"""
    ThermoDB(path::String) -> ThermoDB

Open a connection to the thermo.db SQLite database.
Throws an error if the file does not exist.
"""
function ThermoDB(path::String)
    if !isfile(path)
        error("Database not found: $path")
    end
    db = SQLite.DB(path)
    # Enable foreign keys
    SQLite.execute(db, "PRAGMA foreign_keys = ON")
    return ThermoDB(db, path)
end

"""
    close(tdb::ThermoDB)

Close the database connection.
"""
function Base.close(tdb::ThermoDB)
    if isopen(tdb.db)
        SQLite.close(tdb.db)
    end
end

"""
    show(io::IO, tdb::ThermoDB)

Display a clean representation without exposing the local file path.
"""
function Base.show(io::IO, tdb::ThermoDB)
    print(io, "ThermoDB(\"thermo.db\")")
end

function Base.show(io::IO, ::MIME"text/plain", tdb::ThermoDB)
    print(io, "ThermoDB(\"thermo.db\")")
end

# ------------------------------------------------------------------
# Statistics
# ------------------------------------------------------------------

"""
    get_statistics(tdb::ThermoDB) -> Dict

Return summary statistics from the database.
"""
function get_statistics(tdb::ThermoDB)
    stats = Dict{String, Any}()

    row = first(SQLite.DBInterface.execute(tdb.db,
        "SELECT COUNT(*) FROM species"))
    stats["total_species"] = row[1]

    row = first(SQLite.DBInterface.execute(tdb.db,
        "SELECT COUNT(*) FROM temperature_intervals"))
    stats["total_intervals"] = row[1]

    row = first(SQLite.DBInterface.execute(tdb.db,
        "SELECT COUNT(*) FROM coefficients"))
    stats["total_coeff_sets"] = row[1]

    phases = Dict{String, Int}()
    for r in SQLite.DBInterface.execute(tdb.db,
        "SELECT phase, COUNT(*) as cnt FROM species GROUP BY phase")
        phases[r[1]] = r[2]
    end
    stats["species_by_phase"] = phases

    row = first(SQLite.DBInterface.execute(tdb.db,
        "SELECT AVG(molecular_weight) FROM species"))
    stats["avg_molecular_weight"] = row[1]

    return stats
end

# ------------------------------------------------------------------
# Species lookup
# ------------------------------------------------------------------

"""
    find_species(tdb::ThermoDB, name::AbstractString) -> Vector{Dict}

Find species by name or formula (supports partial/substring search).
Returns up to 20 matches.
"""
function find_species(tdb::ThermoDB, name::AbstractString)
    pattern = "%$name%"
    # Prioritize exact name matches first, then partial matches
    result = SQLite.DBInterface.execute(tdb.db, """
        SELECT id, name, formula, phase, molecular_weight,
               heat_of_formation_298K, num_intervals, comments
        FROM species
        WHERE name LIKE ? OR formula LIKE ?
        ORDER BY CASE WHEN name = ? THEN 0 ELSE 1 END, name
        LIMIT 20
    """, (pattern, pattern, name))
    return [Dict{String, Any}(String(k) => v for (k, v) in pairs(r)) for r in result]
end

"""
    list_species_page(tdb::ThermoDB; page=1, page_size=20) -> (Vector{Dict}, Int)

List species with pagination. Returns a tuple `(species_list, total_pages)`.
"""
function list_species_page(tdb::ThermoDB; page::Int=1, page_size::Int=20)
    row = first(SQLite.DBInterface.execute(tdb.db,
        "SELECT COUNT(*) FROM species"))
    total = row[1]

    offset = (page - 1) * page_size
    result = SQLite.DBInterface.execute(tdb.db, """
        SELECT id, name, phase, molecular_weight,
               heat_of_formation_298K, num_intervals
        FROM species
        ORDER BY name
        LIMIT ? OFFSET ?
    """, (page_size, offset))

    cols = String.(result.names)
    species = [Dict{String, Any}(String(k) => v for (k, v) in pairs(r)) for r in result]
    total_pages = ceil(Int, total / page_size)
    return species, total_pages
end

"""
    list_all_species(tdb::ThermoDB) -> Vector{Dict}

Return all species in a single query (no pagination).
Faster than paginating when you need the full list.
"""
function list_all_species(tdb::ThermoDB)
    result = SQLite.DBInterface.execute(tdb.db, """
        SELECT id, name, formula, phase, molecular_weight,
               heat_of_formation_298K, num_intervals
        FROM species
        ORDER BY name
    """)
    return [Dict{String, Any}(String(k) => v for (k, v) in pairs(r)) for r in result]
end

"""
    get_species_data(tdb::ThermoDB, species_id::Int) -> Union{Dict, Nothing}

Get complete data for a species including all its temperature intervals
and polynomial coefficients.
"""
function get_species_data(tdb::ThermoDB, species_id::Int)
    # Species basic info
    result = SQLite.DBInterface.execute(tdb.db, """
        SELECT id, name, formula, comments, reference_code, phase,
               molecular_weight, heat_of_formation_298K, num_intervals
        FROM species WHERE id = ?
    """, (species_id,))

    # Get first row (avoid collect which returns missing)
    data = nothing
    for row in result
        data = Dict{String, Any}(String(k) => v for (k, v) in pairs(row))
        break
    end
    if data === nothing
        return nothing
    end

    # Temperature intervals with coefficients
    int_result = SQLite.DBInterface.execute(tdb.db, """
        SELECT ti.id, ti.interval_number, ti.temp_min, ti.temp_max,
               ti.h_298_to_0,
               c.id AS coeff_id, c.a1, c.a2, c.a3, c.a4, c.a5,
               c.a6, c.a7, c.b1, c.b2
        FROM temperature_intervals ti
        JOIN coefficients c ON ti.id = c.interval_id
        WHERE ti.species_id = ?
        ORDER BY ti.interval_number
    """, (species_id,))

    intervals = []
    for r in int_result
        d = Dict{String, Any}(String(k) => v for (k, v) in pairs(r))
        push!(intervals, d)
    end
    data["intervals"] = intervals

    return data
end

"""
    get_species_info(tdb::ThermoDB, species_id::Int) -> Union{Dict, Nothing}

Lightweight lookup: returns basic species metadata (id, name, formula,
phase, molecular_weight, heat_of_formation_298K) without loading
temperature intervals or coefficients.

Use this when you only need species identification, not the full
thermochemical data.
"""
function get_species_info(tdb::ThermoDB, species_id::Int)
    result = SQLite.DBInterface.execute(tdb.db, """
        SELECT id, name, formula, phase, molecular_weight,
               heat_of_formation_298K, num_intervals
        FROM species WHERE id = ?
    """, (species_id,))

    for row in result
        return Dict{String, Any}(String(k) => v for (k, v) in pairs(row))
    end
    return nothing
end

"""
    get_species_for_temperature(tdb::ThermoDB, species_id::Int, temperature::Float64)

Find the temperature interval and coefficients valid for the given temperature.
Returns a Dict with interval data and coefficients, or `nothing` if out of range.
"""
function get_species_for_temperature(tdb::ThermoDB, species_id::Int, temperature::Float64)
    result = SQLite.DBInterface.execute(tdb.db, """
        SELECT ti.id, ti.interval_number, ti.temp_min, ti.temp_max,
               ti.h_298_to_0,
               c.a1, c.a2, c.a3, c.a4, c.a5, c.a6, c.a7,
               c.b1, c.b2
        FROM temperature_intervals ti
        JOIN coefficients c ON ti.id = c.interval_id
        WHERE ti.species_id = ?
          AND ti.temp_min <= ?
          AND ti.temp_max >= ?
        LIMIT 1
    """, (species_id, temperature, temperature))

    # Get first row (avoid collect which returns missing)
    for row in result
        return Dict{String, Any}(String(k) => v for (k, v) in pairs(row))
    end
    return nothing
end

# ------------------------------------------------------------------
# NASA-7 polynomial calculations (dimensionless: Cp/R, H/RT, S/R)
# ------------------------------------------------------------------

"""
    calculate_cp(coeffs::Dict, T::Float64) -> Float64

Calculate Cp(T)/R using NASA-7 polynomial coefficients.

Equation: a1·T⁻² + a2·T⁻¹ + a3 + a4·T + a5·T² + a6·T³ + a7·T⁴
"""
function calculate_cp(coeffs::Dict, T::Float64)
    a1 = _or_zero(get(coeffs, "a1", nothing))
    a2 = _or_zero(get(coeffs, "a2", nothing))
    a3 = _or_zero(get(coeffs, "a3", nothing))
    a4 = _or_zero(get(coeffs, "a4", nothing))
    a5 = _or_zero(get(coeffs, "a5", nothing))
    a6 = _or_zero(get(coeffs, "a6", nothing))
    a7 = _or_zero(get(coeffs, "a7", nothing))

    return a1 / T^2 + a2 / T + a3 + a4 * T +
           a5 * T^2 + a6 * T^3 + a7 * T^4
end

"""
    calculate_h(coeffs::Dict, T::Float64) -> Float64

Calculate H°(T)/RT using NASA-7 polynomial coefficients.

Equation: -a1·T⁻² + a2·ln(T)/T + a3 + a4·T/2 + a5·T²/3
          + a6·T³/4 + a7·T⁴/5 + b1/T
"""
function calculate_h(coeffs::Dict, T::Float64)
    a1 = _or_zero(get(coeffs, "a1", nothing))
    a2 = _or_zero(get(coeffs, "a2", nothing))
    a3 = _or_zero(get(coeffs, "a3", nothing))
    a4 = _or_zero(get(coeffs, "a4", nothing))
    a5 = _or_zero(get(coeffs, "a5", nothing))
    a6 = _or_zero(get(coeffs, "a6", nothing))
    a7 = _or_zero(get(coeffs, "a7", nothing))
    b1 = _or_zero(get(coeffs, "b1", nothing))

    return -a1 / T^2 + a2 * log(T) / T + a3 +
           a4 * T / 2 + a5 * T^2 / 3 +
           a6 * T^3 / 4 + a7 * T^4 / 5 + b1 / T
end

"""
    calculate_s(coeffs::Dict, T::Float64) -> Float64

Calculate S°(T)/R using NASA-7 polynomial coefficients.

Equation: -a1·T⁻²/2 - a2·T⁻¹ + a3·ln(T) + a4·T + a5·T²/2
          + a6·T³/3 + a7·T⁴/4 + b2
"""
function calculate_s(coeffs::Dict, T::Float64)
    a1 = _or_zero(get(coeffs, "a1", nothing))
    a2 = _or_zero(get(coeffs, "a2", nothing))
    a3 = _or_zero(get(coeffs, "a3", nothing))
    a4 = _or_zero(get(coeffs, "a4", nothing))
    a5 = _or_zero(get(coeffs, "a5", nothing))
    a6 = _or_zero(get(coeffs, "a6", nothing))
    a7 = _or_zero(get(coeffs, "a7", nothing))
    b2 = _or_zero(get(coeffs, "b2", nothing))

    return -a1 / (2 * T^2) - a2 / T + a3 * log(T) +
           a4 * T + a5 * T^2 / 2 +
           a6 * T^3 / 3 + a7 * T^4 / 4 + b2
end

end # module ThermoDatabase
