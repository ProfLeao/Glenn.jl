"""
    database.jl — SQLite query interface for thermochemical data.

Provides database connection, species lookup, and NASA-7 polynomial
calculations (Cp/R, H/RT, S/R) using coefficients stored in thermo.db.
"""
module ThermoDatabase

using SQLite

# ------------------------------------------------------------------
# Exception hierarchy
# ------------------------------------------------------------------

"""
    ThermoCalcError

Base exception type for thermochemical calculation errors.
"""
struct ThermoCalcError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ThermoCalcError) = print(io, "ThermoCalcError: ", e.msg)

"""
    DatabaseNotConnectedError

Raised when attempting a calculation without an active database connection.
"""
struct DatabaseNotConnectedError <: Exception
    msg::String
end
function DatabaseNotConnectedError()
    return DatabaseNotConnectedError("Calculation attempted without database connection")
end
Base.showerror(io::IO, e::DatabaseNotConnectedError) = print(io, "DatabaseNotConnectedError: ", e.msg)

"""
    SpeciesNotFoundError

Raised when a species ID is not found in the database.
"""
struct SpeciesNotFoundError <: Exception
    msg::String
    species_id::Int
end
function SpeciesNotFoundError(species_id::Int)
    return SpeciesNotFoundError("Species ID $species_id not found in database", species_id)
end
Base.showerror(io::IO, e::SpeciesNotFoundError) = print(io, "SpeciesNotFoundError: ", e.msg)

"""
    TemperatureOutOfRangeError

Raised when the requested temperature is outside all valid intervals
for the given species.
"""
struct TemperatureOutOfRangeError <: Exception
    msg::String
    temperature::Float64
    species_name::String
end
function TemperatureOutOfRangeError(temperature::Float64, species_name::String)
    return TemperatureOutOfRangeError(
        "Temperature $temperature K is out of valid range for species '$species_name'",
        temperature, species_name)
end
Base.showerror(io::IO, e::TemperatureOutOfRangeError) = print(io, "TemperatureOutOfRangeError: ", e.msg)

# ------------------------------------------------------------------
# Physical constant: Universal Gas Constant
# ------------------------------------------------------------------
"""
    const R_UNIVERSAL

Universal Gas Constant in J/(mol·K). Source: CODATA 2018.
"""
const R_UNIVERSAL = 8.314462618

# ------------------------------------------------------------------
# Typed data structures
# ------------------------------------------------------------------

"""
    NASACoefficients

Immutable struct holding the 9 NASA-7 polynomial coefficients (a₁–a₇, b₁, b₂).
All fields are `Float64` — use `0.0` for missing coefficients.
"""
struct NASACoefficients
    a1::Float64; a2::Float64; a3::Float64; a4::Float64
    a5::Float64; a6::Float64; a7::Float64
    b1::Float64; b2::Float64
end

"""
    NASACoefficients(coeffs::Dict) -> NASACoefficients

Construct from a dictionary (backward compatibility).
Missing keys default to `0.0`.
"""
function NASACoefficients(coeffs::Dict)
    return NASACoefficients(
        Float64(get(coeffs, "a1", 0.0)), Float64(get(coeffs, "a2", 0.0)),
        Float64(get(coeffs, "a3", 0.0)), Float64(get(coeffs, "a4", 0.0)),
        Float64(get(coeffs, "a5", 0.0)), Float64(get(coeffs, "a6", 0.0)),
        Float64(get(coeffs, "a7", 0.0)),
        Float64(get(coeffs, "b1", 0.0)), Float64(get(coeffs, "b2", 0.0)),
    )
end

"""
    SpeciesInfo

Lightweight immutable struct with basic species metadata.
"""
struct SpeciesInfo
    id::Int
    name::String
    formula::Union{String, Nothing}
    phase::String
    molecular_weight::Union{Float64, Nothing}
    heat_of_formation_298K::Union{Float64, Nothing}
    num_intervals::Int
end

"""
    IntervalData

Combines a temperature interval with its NASA-7 coefficients.
"""
struct IntervalData
    interval_id::Int
    interval_number::Int
    temp_min::Float64
    temp_max::Float64
    h_298_to_0::Union{Float64, Nothing}
    coefficients::NASACoefficients
end

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

"""
    _or_zero(x) -> Float64

Return `x` if not `nothing`, otherwise return 0.0.
Type-stable: dispatches on concrete types.
"""
_or_zero(x::Nothing) = 0.0
_or_zero(x::Float64) = x
_or_zero(x::Real) = Float64(x)
_or_zero(x::Any) = 0.0  # fallback for safety

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
# Row → struct helpers
# ------------------------------------------------------------------

"""
    _row_to_speciesinfo(row) -> SpeciesInfo

Convert a SQLite result row to a `SpeciesInfo` struct.
Missing fields default to `nothing`.
"""
function _row_to_speciesinfo(row)
    d = Dict{String, Any}(String(k) => v for (k, v) in pairs(row))
    _str_or_nothing(x) = x === nothing || ismissing(x) ? nothing : String(x)
    _float_or_nothing(x) = x === nothing || ismissing(x) ? nothing : Float64(x)
    return SpeciesInfo(
        d["id"],
        d["name"],
        _str_or_nothing(get(d, "formula", nothing)),
        d["phase"],
        _float_or_nothing(get(d, "molecular_weight", nothing)),
        _float_or_nothing(get(d, "heat_of_formation_298K", nothing)),
        get(d, "num_intervals", 0),
    )
end

"""
    _row_to_intervaldata(row) -> IntervalData

Convert a SQLite result row (interval JOIN coefficients) to an `IntervalData` struct.
"""
function _row_to_intervaldata(row)
    d = Dict{String, Any}(String(k) => v for (k, v) in pairs(row))
    _float_or_nothing(x) = x === nothing || ismissing(x) ? nothing : Float64(x)
    coeffs = NASACoefficients(
        Float64(get(d, "a1", 0.0)), Float64(get(d, "a2", 0.0)),
        Float64(get(d, "a3", 0.0)), Float64(get(d, "a4", 0.0)),
        Float64(get(d, "a5", 0.0)), Float64(get(d, "a6", 0.0)),
        Float64(get(d, "a7", 0.0)),
        Float64(get(d, "b1", 0.0)), Float64(get(d, "b2", 0.0)),
    )
    return IntervalData(
        d["id"],
        get(d, "interval_number", 0),
        d["temp_min"],
        d["temp_max"],
        _float_or_nothing(get(d, "h_298_to_0", nothing)),
        coeffs,
    )
end

# ------------------------------------------------------------------
# Species lookup
# ------------------------------------------------------------------

"""
    find_species(tdb::ThermoDB, name::AbstractString) -> Vector{SpeciesInfo}

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
    return [_row_to_speciesinfo(r) for r in result]
end

"""
    list_species_page(tdb::ThermoDB; page=1, page_size=20) -> (Vector{SpeciesInfo}, Int)

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
    species = [_row_to_speciesinfo(r) for r in result]
    total_pages = ceil(Int, total / page_size)
    return species, total_pages
end

"""
    list_all_species(tdb::ThermoDB) -> Vector{SpeciesInfo}

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
    return [_row_to_speciesinfo(r) for r in result]
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

    intervals = [_row_to_intervaldata(r) for r in int_result]
    data["intervals"] = intervals

    return data
end

"""
    get_species_info(tdb::ThermoDB, species_id::Int) -> Union{SpeciesInfo, Nothing}

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
        return _row_to_speciesinfo(row)
    end
    return nothing
end

"""
    get_species_for_temperature(tdb::ThermoDB, species_id::Int, temperature::Float64)
       -> Union{IntervalData, Nothing}

Find the temperature interval and coefficients valid for the given temperature.
Returns an `IntervalData` struct, or `nothing` if out of range.
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
        return _row_to_intervaldata(row)
    end
    return nothing
end

# ------------------------------------------------------------------
# NASA-7 polynomial calculations (dimensionless: Cp/R, H/RT, S/R)
# ------------------------------------------------------------------

"""
    calculate_cp(coeffs::NASACoefficients, T::Float64) -> Float64

Calculate Cp(T)/R using NASA-7 polynomial coefficients.

Equation: a1·T⁻² + a2·T⁻¹ + a3 + a4·T + a5·T² + a6·T³ + a7·T⁴
"""
function calculate_cp(coeffs::NASACoefficients, T::Float64)
    return coeffs.a1 / T^2 + coeffs.a2 / T + coeffs.a3 +
           coeffs.a4 * T + coeffs.a5 * T^2 +
           coeffs.a6 * T^3 + coeffs.a7 * T^4
end

# Backward-compatible Dict method (converts to NASACoefficients)
function calculate_cp(coeffs::Dict, T::Float64)
    return calculate_cp(NASACoefficients(coeffs), T)
end

"""
    calculate_h(coeffs::NASACoefficients, T::Float64) -> Float64

Calculate H°(T)/RT using NASA-7 polynomial coefficients.

Equation: -a1·T⁻² + a2·ln(T)/T + a3 + a4·T/2 + a5·T²/3
          + a6·T³/4 + a7·T⁴/5 + b1/T
"""
function calculate_h(coeffs::NASACoefficients, T::Float64)
    return -coeffs.a1 / T^2 + coeffs.a2 * log(T) / T + coeffs.a3 +
           coeffs.a4 * T / 2 + coeffs.a5 * T^2 / 3 +
           coeffs.a6 * T^3 / 4 + coeffs.a7 * T^4 / 5 + coeffs.b1 / T
end

# Backward-compatible Dict method (converts to NASACoefficients)
function calculate_h(coeffs::Dict, T::Float64)
    return calculate_h(NASACoefficients(coeffs), T)
end

"""
    calculate_s(coeffs::NASACoefficients, T::Float64) -> Float64

Calculate S°(T)/R using NASA-7 polynomial coefficients.

Equation: -a1·T⁻²/2 - a2·T⁻¹ + a3·ln(T) + a4·T + a5·T²/2
          + a6·T³/3 + a7·T⁴/4 + b2
"""
function calculate_s(coeffs::NASACoefficients, T::Float64)
    return -coeffs.a1 / (2 * T^2) - coeffs.a2 / T + coeffs.a3 * log(T) +
           coeffs.a4 * T + coeffs.a5 * T^2 / 2 +
           coeffs.a6 * T^3 / 3 + coeffs.a7 * T^4 / 4 + coeffs.b2
end

# Backward-compatible Dict method (converts to NASACoefficients)
function calculate_s(coeffs::Dict, T::Float64)
    return calculate_s(NASACoefficients(coeffs), T)
end

# Export public symbols (used by parent module Glenn)
export ThermoCalcError, DatabaseNotConnectedError,
       SpeciesNotFoundError, TemperatureOutOfRangeError
export NASACoefficients, SpeciesInfo, IntervalData
export ThermoDB, R_UNIVERSAL

end # module ThermoDatabase
