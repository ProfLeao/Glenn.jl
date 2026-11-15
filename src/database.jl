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

Abstract base type for every error raised by Glenn.jl. Catching
`ThermoCalcError` catches the whole hierarchy.

For backwards compatibility, `ThermoCalcError("message")` still builds a
generic `ThermoError`, so existing `throw(ThermoCalcError(...))` code keeps
working.
"""
abstract type ThermoCalcError <: Exception end

"""
    ThermoError

Generic `ThermoCalcError` used when no more specific error applies.
"""
struct ThermoError <: ThermoCalcError
    msg::String
end
Base.showerror(io::IO, e::ThermoError) = print(io, "ThermoCalcError: ", e.msg)

# Historical constructor: `ThermoCalcError` used to be a concrete struct.
(::Type{ThermoCalcError})(msg::AbstractString) = ThermoError(String(msg))

"""
    DatabaseNotConnectedError

Raised when attempting a calculation without an active database connection.
"""
struct DatabaseNotConnectedError <: ThermoCalcError
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
struct SpeciesNotFoundError <: ThermoCalcError
    msg::String
    species_id::Int
end
function SpeciesNotFoundError(species_id::Int)
    return SpeciesNotFoundError("Species ID $species_id not found in database", species_id)
end
Base.showerror(io::IO, e::SpeciesNotFoundError) = print(io, "SpeciesNotFoundError: ", e.msg)

"""
    CompositionError

Raised when a mixture composition is invalid (empty mixture, duplicate
species IDs, negative mole fractions, or fractions that do not sum to 1).
"""
struct CompositionError <: ThermoCalcError
    msg::String
end
Base.showerror(io::IO, e::CompositionError) = print(io, "CompositionError: ", e.msg)

"""
    TemperatureOutOfRangeError

Raised when the requested temperature is outside all valid intervals
for the given species.

`temp_bounds` carries the overall `(T_min, T_max)` of the species when known,
so callers can report a useful diagnostic.
"""
struct TemperatureOutOfRangeError <: ThermoCalcError
    msg::String
    temperature::Float64
    species_name::String
    temp_bounds::Union{Tuple{Float64, Float64}, Nothing}
end
function TemperatureOutOfRangeError(
    temperature::Float64,
    species_name::AbstractString,
    temp_bounds::Union{Tuple{Float64, Float64}, Nothing} = nothing,
)
    msg = "Temperature $temperature K is out of valid range for species '$species_name'"
    if temp_bounds !== nothing
        msg *= " (valid range: $(temp_bounds[1])–$(temp_bounds[2]) K)"
    end
    return TemperatureOutOfRangeError(msg, temperature, String(species_name), temp_bounds)
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

"""
    ValidationReport

Result of `validate_database`.

# Fields

  - `valid::Bool`             : `true` when no error was found
  - `errors::Vector{String}`  : integrity problems; any entry makes `valid` false
  - `warnings::Vector{String}`: concerns that do not invalidate the database
  - `counts::Dict{String, Int}`: row counts for species, intervals and coefficients
"""
struct ValidationReport
    valid::Bool
    errors::Vector{String}
    warnings::Vector{String}
    counts::Dict{String, Int}
end

function Base.show(io::IO, report::ValidationReport)
    return print(
        io,
        "ValidationReport(valid=",
        report.valid,
        ", errors=",
        length(report.errors),
        ", warnings=",
        length(report.warnings),
        ")",
    )
end

"""
    SpeciesData

Complete record of a species: identification metadata plus every temperature
interval with its NASA-7 coefficients.

Returned by `get_species_data`. Field access is the recommended form
(`data.name`, `data.intervals`); dictionary-style access (`data["name"]`) is
kept for backwards compatibility with versions that returned a `Dict`.
"""
struct SpeciesData
    id::Int
    name::String
    formula::Union{String, Nothing}
    comments::Union{String, Nothing}
    reference_code::Union{String, Nothing}
    phase::String
    molecular_weight::Union{Float64, Nothing}
    heat_of_formation_298K::Union{Float64, Nothing}
    num_intervals::Int
    intervals::Vector{IntervalData}
end

"""
    to_dict(data::SpeciesData) -> Dict{String, Any}

Return a `SpeciesData` as a plain `Dict`, matching the pre-0.5.0 return shape.
"""
function to_dict(data::SpeciesData)
    return Dict{String, Any}(
        "id" => data.id,
        "name" => data.name,
        "formula" => data.formula,
        "comments" => data.comments,
        "reference_code" => data.reference_code,
        "phase" => data.phase,
        "molecular_weight" => data.molecular_weight,
        "heat_of_formation_298K" => data.heat_of_formation_298K,
        "num_intervals" => data.num_intervals,
        "intervals" => data.intervals,
    )
end

# Backwards compatibility: `get_species_data` used to return a Dict.
function Base.getindex(data::SpeciesData, key::AbstractString)
    key == "id" && return data.id
    key == "name" && return data.name
    key == "formula" && return data.formula
    key == "comments" && return data.comments
    key == "reference_code" && return data.reference_code
    key == "phase" && return data.phase
    key == "molecular_weight" && return data.molecular_weight
    key == "heat_of_formation_298K" && return data.heat_of_formation_298K
    key == "num_intervals" && return data.num_intervals
    key == "intervals" && return data.intervals
    throw(KeyError(key))
end

Base.keys(::SpeciesData) = (
    "id",
    "name",
    "formula",
    "comments",
    "reference_code",
    "phase",
    "molecular_weight",
    "heat_of_formation_298K",
    "num_intervals",
    "intervals",
)

"""
    Mixture

A fixed-composition mixture defined by mole fractions.

`species` holds `(species_id, mole_fraction)` tuples. Call `validate` to check
that the composition is self-consistent before using it.
"""
struct Mixture
    species::Vector{Tuple{Int, Float64}}

    # Explicit inner constructor: prevents Julia from generating the generic
    # `Mixture(::Any)` constructor, which the outer constructor below would
    # otherwise overwrite.
    Mixture(species::Vector{Tuple{Int, Float64}}) = new(species)
end

"""
    Mixture(comps)

Build a `Mixture` from any iterable of `(species_id, mole_fraction)` pairs,
such as a tuple of tuples, a vector, or a generator.
"""
function Mixture(comps::Union{Tuple, AbstractVector})
    return Mixture(Tuple{Int, Float64}[(Int(id), Float64(x)) for (id, x) in comps])
end

"""
    validate(mixture::Mixture; tol=1e-9)

Check that the mixture is non-empty, has no duplicate species IDs, has
non-negative fractions, and that the mole fractions sum to 1 within `tol`.

Throws `CompositionError` on the first failed check.
"""
function validate(mixture::Mixture; tol::Float64 = 1e-9)
    isempty(mixture.species) && throw(CompositionError("mixture has no species"))

    seen = Set{Int}()
    total = 0.0
    for (species_id, fraction) in mixture.species
        species_id in seen &&
            throw(CompositionError("duplicate species ID $species_id in mixture"))
        push!(seen, species_id)
        fraction < 0.0 && throw(
            CompositionError("negative mole fraction $fraction for species ID $species_id"),
        )
        total += fraction
    end

    if abs(total - 1.0) > tol
        throw(CompositionError("mole fractions must sum to 1.0 (got $total)"))
    end
    return nothing
end

"""
    MixedProperties

Thermochemical properties of a mixture at a single temperature, on both a molar
(per mole of mixture) and a mass (per kilogram of mixture) basis.

`molar_mass` is the mole-fraction-weighted mean molar mass in kg/mol.
"""
struct MixedProperties
    temperature::Float64
    cp_molar::Float64
    h_molar::Float64
    s_molar::Float64
    molar_mass::Float64
    cp_mass::Float64
    h_mass::Float64
    s_mass::Float64
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
    get_gas_constant_ref(tdb::ThermoDB) -> Float64

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

get_gas_constant_ref(tdb::ThermoDB)::Float64 = get_gas_constant_ref(tdb.db)

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

Because the comparison folds case, a pattern may still match more than one
species when names differ only by capitalisation (``"CO"`` matches both carbon
monoxide `CO` and cobalt `Co`). Use `only(...)` only when the name is
unambiguous, or compare the returned `name` field explicitly.
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
    get_species_data(tdb::ThermoDB, species_id::Int) -> Union{SpeciesData, Nothing}

Get complete data for a species including all its temperature intervals
and polynomial coefficients.

Returns a typed [`SpeciesData`](@ref), or `nothing` when the ID is unknown.
Dictionary-style access (`data["name"]`) remains supported for compatibility.
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
    row_data = nothing
    for row in result
        row_data = Dict{String, Any}(String(k) => v for (k, v) in pairs(row))
        break
    end
    if row_data === nothing
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

    _str_or_nothing(x) = x === nothing || ismissing(x) ? nothing : String(x)
    _float_or_nothing(x) = x === nothing || ismissing(x) ? nothing : Float64(x)

    return SpeciesData(
        Int(row_data["id"]),
        String(row_data["name"]),
        _str_or_nothing(get(row_data, "formula", nothing)),
        _str_or_nothing(get(row_data, "comments", nothing)),
        _str_or_nothing(get(row_data, "reference_code", nothing)),
        String(row_data["phase"]),
        _float_or_nothing(get(row_data, "molecular_weight", nothing)),
        _float_or_nothing(get(row_data, "heat_of_formation_298K", nothing)),
        Int(get(row_data, "num_intervals", 0)),
        intervals,
    )
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

When two intervals share a boundary temperature, the lower one (smallest
`interval_number`) is returned. This is deterministic thanks to the `ORDER BY`.
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
    ORDER BY ti.interval_number
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

"""
    get_temperature_bounds(tdb::ThermoDB, species_id::Int)
       -> Union{Tuple{Float64, Float64}, Nothing}

Return the overall `(T_min, T_max)` covered by a species' temperature intervals,
or `nothing` when the species has no intervals (or does not exist).

Useful to report a precise diagnostic when a temperature is out of range.
"""
function get_temperature_bounds(tdb::ThermoDB, species_id::Int)
    for row in SQLite.DBInterface.execute(
        tdb.db,
        """
        SELECT MIN(temp_min), MAX(temp_max)
        FROM temperature_intervals WHERE species_id = ?
        """,
        (species_id,),
    )
        tmin, tmax = row[1], row[2]
        (tmin === nothing || tmax === nothing) && return nothing
        (ismissing(tmin) || ismissing(tmax)) && return nothing
        return (Float64(tmin), Float64(tmax))
    end
    return nothing
end

# ------------------------------------------------------------------
# Integrity validation
# ------------------------------------------------------------------

"""
    _count(db::SQLite.DB, sql::AbstractString) -> Int

Run a `COUNT(*)` query and return the value as an `Int` (0 when no row).
"""
function _count(db::SQLite.DB, sql::AbstractString)
    for row in SQLite.DBInterface.execute(db, sql)
        return Int(row[1])
    end
    return 0
end

"""
    validate_database(tdb::ThermoDB) -> ValidationReport

Run read-only integrity and semantic checks against a database and return a
`ValidationReport`. Nothing is modified.

Checks performed:

  - the `species`, `temperature_intervals` and `coefficients` tables exist;
  - no coefficient row references a missing interval;
  - no interval row references a missing species;
  - every interval has exactly one coefficient row;
  - `species.num_intervals` agrees with the stored intervals;
  - interval bounds are present, ordered (`temp_min < temp_max`) and not degenerate;
  - no coefficient set contains `NULL` values;
  - no species name looks like a FORTRAN coefficient token (parser guard).

Warnings (reported, but not fatal):

  - missing `metadata` table or missing `gas_constant_ref` entry, which means the
    dataset reference gas constant is unknown and `R_UNIVERSAL` is used instead;
  - `file_metadata.total_species` not set.
"""
function validate_database(tdb::ThermoDB)
    errors = String[]
    warnings = String[]
    counts = Dict{String, Int}()

    missing_tables = [
        table for
        table in ("species", "temperature_intervals", "coefficients") if
        !_table_exists(tdb.db, table)
    ]
    if !isempty(missing_tables)
        push!(errors, "missing required table(s): " * join(missing_tables, ", "))
        return ValidationReport(false, errors, warnings, counts)
    end

    counts["total_species"] = _count(tdb.db, "SELECT COUNT(*) FROM species")
    counts["total_intervals"] = _count(
        tdb.db,
        "SELECT COUNT(*) FROM temperature_intervals",
    )
    counts["total_coeff_sets"] = _count(tdb.db, "SELECT COUNT(*) FROM coefficients")

    # --- Referential integrity ---
    n = _count(
        tdb.db,
        """
        SELECT COUNT(*) FROM coefficients c
        LEFT JOIN temperature_intervals ti ON c.interval_id = ti.id
        WHERE ti.id IS NULL
        """,
    )
    n > 0 && push!(errors, "$n coefficient row(s) reference a missing interval")

    n = _count(
        tdb.db,
        """
        SELECT COUNT(*) FROM temperature_intervals ti
        LEFT JOIN species s ON ti.species_id = s.id
        WHERE s.id IS NULL
        """,
    )
    n > 0 && push!(errors, "$n interval row(s) reference a missing species")

    # --- Exactly one coefficient set per interval ---
    n = _count(
        tdb.db,
        """
        SELECT COUNT(*) FROM (
            SELECT interval_id, COUNT(*) AS n FROM coefficients
            GROUP BY interval_id
        ) WHERE n != 1
        """,
    )
    n > 0 && push!(errors, "$n interval(s) do not have exactly one coefficient row")

    # --- num_intervals agreement ---
    n = _count(
        tdb.db,
        """
        SELECT COUNT(*) FROM species s WHERE s.num_intervals != (
            SELECT COUNT(*) FROM temperature_intervals ti
            WHERE ti.species_id = s.id
        )
        """,
    )
    n > 0 &&
        push!(errors, "$n species have num_intervals disagreeing with stored intervals")

    # --- Bounds ---
    n = _count(
        tdb.db,
        """
        SELECT COUNT(*) FROM temperature_intervals
        WHERE temp_min IS NULL OR temp_max IS NULL OR temp_min >= temp_max
        """,
    )
    n > 0 &&
        push!(errors, "$n interval(s) have null, unordered or degenerate bounds")

    # --- Coefficient completeness ---
    n = _count(
        tdb.db,
        """
        SELECT COUNT(*) FROM coefficients
        WHERE a1 IS NULL OR a2 IS NULL OR a3 IS NULL OR a4 IS NULL
           OR a5 IS NULL OR a6 IS NULL OR a7 IS NULL OR b1 IS NULL OR b2 IS NULL
        """,
    )
    n > 0 && push!(errors, "$n coefficient set(s) contain NULL values")

    # --- Semantic guard: a coefficient line must never become a species ---
    n = _count(
        tdb.db,
        """
        SELECT COUNT(*) FROM species
        WHERE name LIKE '%.%D%' OR name LIKE '%.%E%'
        """,
    )
    n > 0 &&
        push!(errors, "$n species name(s) look like FORTRAN coefficient tokens")

    # --- Warnings ---
    if _table_exists(tdb.db, "metadata")
        n = _count(
            tdb.db,
            "SELECT COUNT(*) FROM metadata WHERE key = 'gas_constant_ref'",
        )
        n == 0 && push!(
            warnings,
            "metadata table has no 'gas_constant_ref' entry; R_UNIVERSAL is used instead",
        )
    else
        push!(
            warnings,
            "database has no 'metadata' table; the reference gas constant is unknown",
        )
    end

    if _table_exists(tdb.db, "file_metadata")
        n = _count(
            tdb.db,
            "SELECT COUNT(*) FROM file_metadata WHERE id = 1 AND total_species IS NOT NULL",
        )
        n == 0 && push!(warnings, "file_metadata.total_species is not set")
    end

    return ValidationReport(isempty(errors), errors, warnings, counts)
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
    ThermoError,
    DatabaseNotConnectedError,
    SpeciesNotFoundError,
    TemperatureOutOfRangeError,
    CompositionError
export NASACoefficients, SpeciesInfo, SpeciesData, IntervalData, DatabaseStats
export ValidationReport
export Mixture, MixedProperties, to_dict, validate, validate_database
export ThermoDB, R_UNIVERSAL, R_GLENN
export get_gas_constant_ref, get_temperature_bounds

end # module ThermoDatabase
