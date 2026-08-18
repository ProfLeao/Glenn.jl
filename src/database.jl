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
function Base.showerror(io::IO, e::DatabaseNotConnectedError)
    print(io, "DatabaseNotConnectedError: ", e.msg)
end

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
        temperature,
        species_name,
    )
end
function Base.showerror(io::IO, e::TemperatureOutOfRangeError)
    print(io, "TemperatureOutOfRangeError: ", e.msg)
end

# ------------------------------------------------------------------
# Physical constants: Universal Gas Constant
# ------------------------------------------------------------------
"""
    const R_UNIVERSAL

Universal Gas Constant in J/(mol·K). Source: CODATA 2018/2022 (full precision).
"""
const R_UNIVERSAL = 8.31446261815324

"""
    const R_GLENN

Reference gas constant in J/(mol·K) used when the bundled NASA Glenn/CEA
polynomial coefficients were fitted (NASA TP-2002-211556, `thermo.inp` dated
9/09/04). CODATA 1986 value.

The NASA-7 polynomials are dimensionless (`Cp/R₀`, `H/R₀T`, `S/R₀`), so the
original values are recovered by denormalising with this constant — not with
`R_UNIVERSAL`.
"""
const R_GLENN = 8.314510

# ------------------------------------------------------------------
# Typed data structures
# ------------------------------------------------------------------

"""
    NASACoefficients

Immutable struct holding the 9 NASA-7 polynomial coefficients (a₁–a₇, b₁, b₂).
All fields are `Float64` — use `0.0` for missing coefficients.
"""
struct NASACoefficients
    a1::Float64
    a2::Float64
    a3::Float64
    a4::Float64
    a5::Float64
    a6::Float64
    a7::Float64
    b1::Float64
    b2::Float64
end

"""
    NASACoefficients(coeffs::Dict) -> NASACoefficients

Construct from a dictionary (backward compatibility).
Missing keys default to `0.0`.
"""
function NASACoefficients(coeffs::Dict)
    return NASACoefficients(
        Float64(get(coeffs, "a1", 0.0)),
        Float64(get(coeffs, "a2", 0.0)),
        Float64(get(coeffs, "a3", 0.0)),
        Float64(get(coeffs, "a4", 0.0)),
        Float64(get(coeffs, "a5", 0.0)),
        Float64(get(coeffs, "a6", 0.0)),
        Float64(get(coeffs, "a7", 0.0)),
        Float64(get(coeffs, "b1", 0.0)),
        Float64(get(coeffs, "b2", 0.0)),
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

"""
    DatabaseStats

Immutable struct holding database summary statistics.

# Fields

  - `total_species::Int`            : Number of chemical species
  - `total_intervals::Int`          : Number of temperature intervals
  - `total_coeff_sets::Int`         : Number of coefficient sets
  - `species_by_phase::Dict`        : Species count grouped by phase
  - `avg_molecular_weight::Union`   : Mean molecular weight (g/mol), or `nothing`
"""
struct DatabaseStats
    total_species::Int
    total_intervals::Int
    total_coeff_sets::Int
    species_by_phase::Dict{String, Int}
    avg_molecular_weight::Union{Float64, Nothing}
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
# Reference gas constant (dataset metadata)
# ------------------------------------------------------------------

"""
    _table_exists(db::SQLite.DB, name::String) -> Bool

Return `true` if a table named `name` exists in the database.
"""
function _table_exists(db::SQLite.DB, name::String)::Bool
    rows = SQLite.DBInterface.execute(
        db,
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
        (name,),
    )
    return !isempty(collect(rows))
end

"""
    get_gas_constant_ref(db::SQLite.DB) -> Float64

Return the reference gas constant stored in the dataset metadata, or fall back
to `R_UNIVERSAL` for legacy databases that predate the `metadata` table.

The check is explicit (no generic `try/catch`) so that connection or corruption
errors are not silently masked.
"""
function get_gas_constant_ref(db::SQLite.DB)::Float64
    if !_table_exists(db, "metadata")
        @warn "database has no 'metadata' table; falling back to R_UNIVERSAL (CODATA 2018/2022)"
        return R_UNIVERSAL
    end

    R_ref = nothing
    for row in SQLite.DBInterface.execute(
        db,
        "SELECT value FROM metadata WHERE key='gas_constant_ref' LIMIT 1",
    )
        R_ref = parse(Float64, row[1])
        break
    end

    if R_ref === nothing
        @warn "metadata key 'gas_constant_ref' not found; falling back to R_UNIVERSAL"
        return R_UNIVERSAL
    end

    # Sanity check: a plausible molar gas constant must lie in (8, 9) J/(mol·K).
    if 8.0 < R_ref < 9.0
        return R_ref
    end

    @warn "gas_constant_ref=$R_ref is implausible; falling back to R_UNIVERSAL"
    return R_UNIVERSAL
end

# ------------------------------------------------------------------
# Statistics
# ------------------------------------------------------------------

"""
    get_statistics(tdb::ThermoDB) -> DatabaseStats

Return summary statistics from the database.
"""
function get_statistics(tdb::ThermoDB)
    row = first(SQLite.DBInterface.execute(tdb.db, "SELECT COUNT(*) FROM species"))
    total_species = row[1]

    row = first(
        SQLite.DBInterface.execute(tdb.db, "SELECT COUNT(*) FROM temperature_intervals"),
    )
    total_intervals = row[1]

    row = first(SQLite.DBInterface.execute(tdb.db, "SELECT COUNT(*) FROM coefficients"))
    total_coeff_sets = row[1]

    phases = Dict{String, Int}()
    for r in SQLite.DBInterface.execute(
        tdb.db,
        "SELECT phase, COUNT(*) as cnt FROM species GROUP BY phase",
    )
        phases[r[1]] = r[2]
    end

    row = first(
        SQLite.DBInterface.execute(tdb.db, "SELECT AVG(molecular_weight) FROM species"),
    )
    avg_mw = row[1]
    avg_mw = avg_mw === nothing || ismissing(avg_mw) ? nothing : Float64(avg_mw)

    return DatabaseStats(
        total_species,
        total_intervals,
        total_coeff_sets,
        phases,
        avg_mw,
    )
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
        Float64(get(d, "a1", 0.0)),
        Float64(get(d, "a2", 0.0)),
        Float64(get(d, "a3", 0.0)),
        Float64(get(d, "a4", 0.0)),
        Float64(get(d, "a5", 0.0)),
        Float64(get(d, "a6", 0.0)),
        Float64(get(d, "a7", 0.0)),
        Float64(get(d, "b1", 0.0)),
        Float64(get(d, "b2", 0.0)),
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
    find_species(tdb::ThermoDB, name::AbstractString; exact_match::Bool=false) -> Vector{SpeciesInfo}

Find species by name or formula.

If `exact_match=false` (default), performs a substring search (LIKE) and
returns up to 20 matches, with exact matches prioritised first.

If `exact_match=true`, performs a case-insensitive exact match — only the
species whose name matches the pattern exactly is returned (e.g. ``"N2"``
returns only N₂, not Be₃N₂).
"""
function find_species(tdb::ThermoDB, name::AbstractString; exact_match::Bool = false)
    if exact_match
        # Case-insensitive exact match
        result = SQLite.DBInterface.execute(
            tdb.db,
            """
    SELECT id, name, formula, phase, molecular_weight,
           heat_of_formation_298K, num_intervals, comments
    FROM species
    WHERE UPPER(name) = UPPER(?)
    ORDER BY name
    LIMIT 20
""",
            (name,),
        )
    else
        pattern = "%$name%"
        # Prioritize exact name matches first, then partial matches
        result = SQLite.DBInterface.execute(
            tdb.db,
            """
    SELECT id, name, formula, phase, molecular_weight,
           heat_of_formation_298K, num_intervals, comments
    FROM species
    WHERE name LIKE ? OR formula LIKE ?
    ORDER BY CASE WHEN name = ? THEN 0 ELSE 1 END, name
    LIMIT 20
""",
            (pattern, pattern, name),
        )
    end
    return [_row_to_speciesinfo(r) for r in result]
end

"""
    list_species_page(tdb::ThermoDB; page=1, page_size=20) -> (Vector{SpeciesInfo}, Int)

List species with pagination. Returns a tuple `(species_list, total_pages)`.
"""
function list_species_page(tdb::ThermoDB; page::Int = 1, page_size::Int = 20)
    row = first(SQLite.DBInterface.execute(tdb.db, "SELECT COUNT(*) FROM species"))
    total = row[1]

    offset = (page - 1) * page_size
    result = SQLite.DBInterface.execute(
        tdb.db,
        """
    SELECT id, name, phase, molecular_weight,
           heat_of_formation_298K, num_intervals
    FROM species
    ORDER BY name
    LIMIT ? OFFSET ?
""",
        (page_size, offset),
    )

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
    result = SQLite.DBInterface.execute(
        tdb.db,
        """
    SELECT id, name, formula, phase, molecular_weight,
           heat_of_formation_298K, num_intervals
    FROM species
    ORDER BY name
""",
    )
    return [_row_to_speciesinfo(r) for r in result]
end

"""
    get_species_data(tdb::ThermoDB, species_id::Int) -> Union{Dict, Nothing}

Get complete data for a species including all its temperature intervals
and polynomial coefficients.
"""
function get_species_data(tdb::ThermoDB, species_id::Int)
    # Species basic info
    result = SQLite.DBInterface.execute(
        tdb.db,
        """
    SELECT id, name, formula, comments, reference_code, phase,
           molecular_weight, heat_of_formation_298K, num_intervals
    FROM species WHERE id = ?
""",
        (species_id,),
    )

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
    int_result = SQLite.DBInterface.execute(
        tdb.db,
        """
    SELECT ti.id, ti.interval_number, ti.temp_min, ti.temp_max,
           ti.h_298_to_0,
           c.id AS coeff_id, c.a1, c.a2, c.a3, c.a4, c.a5,
           c.a6, c.a7, c.b1, c.b2
    FROM temperature_intervals ti
    JOIN coefficients c ON ti.id = c.interval_id
    WHERE ti.species_id = ?
    ORDER BY ti.interval_number
""",
        (species_id,),
    )

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
    result = SQLite.DBInterface.execute(
        tdb.db,
        """
    SELECT id, name, formula, phase, molecular_weight,
           heat_of_formation_298K, num_intervals
    FROM species WHERE id = ?
""",
        (species_id,),
    )

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
    result = SQLite.DBInterface.execute(
        tdb.db,
        """
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
""",
        (species_id, temperature, temperature),
    )

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
    return coeffs.a1 / T^2 +
           coeffs.a2 / T +
           coeffs.a3 +
           coeffs.a4 * T +
           coeffs.a5 * T^2 +
           coeffs.a6 * T^3 +
           coeffs.a7 * T^4
end

# Deprecated Dict methods (converts to NASACoefficients)
Base.@deprecate calculate_cp(coeffs::Dict, T::Float64) calculate_cp(NASACoefficients(coeffs), T)

"""
    calculate_h(coeffs::NASACoefficients, T::Float64) -> Float64

Calculate H°(T)/RT using NASA-7 polynomial coefficients.

Equation: -a1·T⁻² + a2·ln(T)/T + a3 + a4·T/2 + a5·T²/3
+ a6·T³/4 + a7·T⁴/5 + b1/T
"""
function calculate_h(coeffs::NASACoefficients, T::Float64)
    return -coeffs.a1 / T^2 +
           coeffs.a2 * log(T) / T +
           coeffs.a3 +
           coeffs.a4 * T / 2 +
           coeffs.a5 * T^2 / 3 +
           coeffs.a6 * T^3 / 4 +
           coeffs.a7 * T^4 / 5 +
           coeffs.b1 / T
end

# Deprecated Dict method (converts to NASACoefficients)
Base.@deprecate calculate_h(coeffs::Dict, T::Float64) calculate_h(NASACoefficients(coeffs), T)

"""
    calculate_s(coeffs::NASACoefficients, T::Float64) -> Float64

Calculate S°(T)/R using NASA-7 polynomial coefficients.

Equation: -a1·T⁻²/2 - a2·T⁻¹ + a3·ln(T) + a4·T + a5·T²/2
+ a6·T³/3 + a7·T⁴/4 + b2
"""
function calculate_s(coeffs::NASACoefficients, T::Float64)
    return -coeffs.a1 / (2 * T^2) - coeffs.a2 / T +
           coeffs.a3 * log(T) +
           coeffs.a4 * T +
           coeffs.a5 * T^2 / 2 +
           coeffs.a6 * T^3 / 3 +
           coeffs.a7 * T^4 / 4 +
           coeffs.b2
end

# Deprecated Dict method (converts to NASACoefficients)
Base.@deprecate calculate_s(coeffs::Dict, T::Float64) calculate_s(NASACoefficients(coeffs), T)

# Export public symbols (used by parent module Glenn)
export ThermoCalcError,
    DatabaseNotConnectedError, SpeciesNotFoundError, TemperatureOutOfRangeError
export NASACoefficients, SpeciesInfo, IntervalData, DatabaseStats
export ThermoDB, R_UNIVERSAL, R_GLENN
export get_gas_constant_ref

end # module ThermoDatabase
