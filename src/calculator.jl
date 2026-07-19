"""
    calculator.jl — High-level thermochemical properties calculator.

Computes Cp(T), H°(T), S°(T) from NASA-7 polynomial coefficients
stored in a SQLite database.

All values returned in standard units:
  Cp, S°  → J/(mol·K)
  H°      → J/mol
"""
module ThermoCalculator

using ..ThermoDatabase

# ------------------------------------------------------------------
# Default database path
# ------------------------------------------------------------------

"""
    default_db_path() -> String

Return the path to the bundled `thermo.db` shipped with the package.
"""
function default_db_path()
    return normpath(joinpath(@__DIR__, "..", "data", "thermo.db"))
end

"""
    default_inp_path() -> String

Return the path to the bundled `thermo.inp` shipped with the package.

Used as the default input for `ThermoDBBuilder` when rebuilding the database.
"""
function default_inp_path()
    return normpath(joinpath(@__DIR__, "..", "data", "thermo.inp"))
end

# ------------------------------------------------------------------
# Calculator struct
# ------------------------------------------------------------------

"""
    ThermoProperties

Immutable struct holding calculated thermochemical properties at a given
temperature. All values in SI units: Cp, S° → J/(mol·K); H° → J/mol.

# Fields
- `temperature::Float64`  : Temperature (K)
- `cp::Float64`           : Heat capacity (J/(mol·K))
- `h_relative::Float64`   : Enthalpy relative to 0 K (J/mol)
- `s::Float64`            : Absolute entropy (J/(mol·K))
- `temp_min::Float64`     : Lower bound of valid interval (K)
- `temp_max::Float64`     : Upper bound of valid interval (K)
- `species_name::String`  : Species name
- `phase::String`         : Phase ("gas" or "condensed")
"""
struct ThermoProperties
    temperature::Float64
    cp::Float64
    h_relative::Float64
    s::Float64
    temp_min::Float64
    temp_max::Float64
    species_name::String
    phase::String
end

"""
    Calculator

High-level interface for calculating thermochemical properties.
Wraps a `ThermoDB` connection.

Call without arguments to use the bundled `thermo.db`:
    calc = Calculator()
"""
mutable struct Calculator
    db::ThermoDatabase.ThermoDB
end

"""
    Calculator(path::String) -> Calculator

Create a Calculator connected to a thermo.db database.
Defaults to the bundled database shipped with the package.
"""
function Calculator(path::String=default_db_path())
    db = ThermoDatabase.ThermoDB(path)
    return Calculator(db)
end

"""
    close(calc::Calculator)

Close the underlying database connection.
"""
function Base.close(calc::Calculator)
    ThermoDatabase.close(calc.db)
end

"""
    show(io::IO, calc::Calculator)

Display the calculator with the database filename.
"""
function Base.show(io::IO, calc::Calculator)
    print(io, "Calculator(\"", basename(calc.db.path), "\")")
end

function Base.show(io::IO, ::MIME"text/plain", calc::Calculator)
    print(io, "Calculator(\"", basename(calc.db.path), "\")")
end

# ------------------------------------------------------------------
# Species lookup
# ------------------------------------------------------------------

"""
    get_available_species(calc::Calculator, pattern::AbstractString="") -> Vector{SpeciesInfo}

Return a list of available species, optionally filtered by name pattern.
"""
function get_available_species(calc::Calculator, pattern::AbstractString="")
    if isempty(pattern)
        # Single query for all species — much faster than paginating
        return ThermoDatabase.list_all_species(calc.db)
    else
        return ThermoDatabase.find_species(calc.db, pattern)
    end
end

# ------------------------------------------------------------------
# Core calculations
# ------------------------------------------------------------------

"""
    calculate_properties(calc::Calculator, species_id::Int, T::Float64)
       -> ThermoProperties

Calculate thermochemical properties at a given temperature.

Returns a `ThermoProperties` struct with Cp, H°, S° and metadata.

Throws `SpeciesNotFoundError` if the species ID is invalid.
Throws `TemperatureOutOfRangeError` if T is outside all valid intervals.
"""
function calculate_properties(calc::Calculator, species_id::Int, T::Float64)
    # Lightweight lookup: only need name & phase, not all intervals/coeffs
    info = ThermoDatabase.get_species_info(calc.db, species_id)
    if info === nothing
        throw(ThermoCalcError("Species ID $species_id not found in database"))
    end

    interval_data = ThermoDatabase.get_species_for_temperature(
        calc.db, species_id, T)

    if interval_data === nothing
        throw(ThermoCalcError(
            "Temperature $T K is out of valid range for '$(info.name)'. " *
            "Use get_species_data($species_id) to check available intervals."))
    end

    cp_r = ThermoDatabase.calculate_cp(interval_data.coefficients, T)
    h_rt = ThermoDatabase.calculate_h(interval_data.coefficients, T)
    s_r  = ThermoDatabase.calculate_s(interval_data.coefficients, T)

    R = ThermoDatabase.R_UNIVERSAL

    return ThermoProperties(
        T,
        cp_r * R,
        h_rt * T * R,
        s_r * R,
        interval_data.temp_min,
        interval_data.temp_max,
        info.name,
        info.phase,
    )
end

"""
    calculate_properties(calc::Calculator, species_id::Int,
                         T_range::AbstractVector{<:Real}) -> Vector{ThermoProperties}

Vectorized: calculate thermochemical properties for multiple temperatures.

Loads coefficients once from the database and evaluates the polynomial
for each temperature in memory — much faster than calling the scalar
version in a loop.

Throws `SpeciesNotFoundError` if the species ID is invalid.
Skips temperatures outside valid intervals (returns only valid results).
"""
function calculate_properties(calc::Calculator, species_id::Int,
                               T_range::AbstractVector{<:Real})
    info = ThermoDatabase.get_species_info(calc.db, species_id)
    if info === nothing
        throw(ThermoCalcError("Species ID $species_id not found in database"))
    end

    # Load ALL intervals for this species (single query)
    species_data = ThermoDatabase.get_species_data(calc.db, species_id)
    if species_data === nothing
        throw(ThermoCalcError("Species ID $species_id has no data"))
    end
    intervals = species_data["intervals"]  # Vector{IntervalData}
    R = ThermoDatabase.R_UNIVERSAL

    results = ThermoProperties[]
    sizehint!(results, length(T_range))

    for T in T_range
        Tf = Float64(T)
        # Find the right interval
        interval_data = nothing
        for iv in intervals
            if iv.temp_min <= Tf <= iv.temp_max
                interval_data = iv
                break
            end
        end
        interval_data === nothing && continue  # skip out-of-range

        cp_r = ThermoDatabase.calculate_cp(interval_data.coefficients, Tf)
        h_rt = ThermoDatabase.calculate_h(interval_data.coefficients, Tf)
        s_r  = ThermoDatabase.calculate_s(interval_data.coefficients, Tf)

        push!(results, ThermoProperties(
            Tf, cp_r * R, h_rt * Tf * R, s_r * R,
            interval_data.temp_min, interval_data.temp_max,
            info.name, info.phase,
        ))
    end

    return results
end

"""
    calculate_formation_enthalpy(calc::Calculator, species_id::Int) -> Union{Float64, Nothing}

Return the enthalpy of formation at 298.15 K (J/mol).

Returns `nothing` if the species exists but has no formation enthalpy data.
Throws `SpeciesNotFoundError` if the species ID is invalid.
"""
function calculate_formation_enthalpy(calc::Calculator, species_id::Int)
    info = ThermoDatabase.get_species_info(calc.db, species_id)
    if info === nothing
        throw(ThermoCalcError("Species ID $species_id not found"))
    end
    hf = info.heat_of_formation_298K
    if hf === nothing || ismissing(hf)
        return nothing
    end
    return Float64(hf)
end

"""
    calculate_enthalpy_change(calc::Calculator, species_id::Int,
                              T1::Float64, T2::Float64) -> Float64

Calculate ΔH = H(T2) - H(T1) for a species (J/mol).

Throws on invalid species or out-of-range temperatures.
"""
function calculate_enthalpy_change(calc::Calculator, species_id::Int,
                                    T1::Float64, T2::Float64)
    props1 = calculate_properties(calc, species_id, T1)
    props2 = calculate_properties(calc, species_id, T2)
    return props2.h_relative - props1.h_relative
end

"""
    get_properties_range(calc::Calculator, species_id::Int,
                         T_range::AbstractVector{<:Real}) -> Vector{ThermoProperties}

Calculate thermochemical properties over a range of temperatures.

Delegates to the vectorized `calculate_properties` for efficiency.
"""
function get_properties_range(calc::Calculator, species_id::Int,
                               T_range::AbstractVector{<:Real})
    return calculate_properties(calc, species_id, T_range)
end

end # module ThermoCalculator
