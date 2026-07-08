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

# ------------------------------------------------------------------
# Calculator struct
# ------------------------------------------------------------------

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

# ------------------------------------------------------------------
# Species lookup
# ------------------------------------------------------------------

"""
    get_available_species(calc::Calculator, pattern::AbstractString="") -> Vector{Dict}

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
    calculate_properties(calc::Calculator, species_id::Int, T::Float64) -> Union{Dict, Nothing}

Calculate thermochemical properties at a given temperature.

Returns a Dict with keys:
- `temperature`   : Input temperature (K)
- `cp`            : Heat capacity in J/(mol·K)
- `h_relative`    : Enthalpy relative to 0 K in J/mol
- `s`             : Absolute entropy in J/(mol·K)
- `temp_min`      : Lower bound of valid interval (K)
- `temp_max`      : Upper bound of valid interval (K)
- `species_name`  : Species name
- `phase`         : Phase ("gas" or "condensed")

Returns `nothing` if the temperature is out of range or species not found.
"""
function calculate_properties(calc::Calculator, species_id::Int, T::Float64)
    # Lightweight lookup: only need name & phase, not all intervals/coeffs
    info = ThermoDatabase.get_species_info(calc.db, species_id)
    if info === nothing
        @warn "Species ID $species_id not found in database."
        return nothing
    end

    interval_data = ThermoDatabase.get_species_for_temperature(
        calc.db, species_id, T)

    if interval_data === nothing
        @warn "Temperature $T K is out of valid range for $(info["name"])." *
              " Use get_species_data($species_id) to check available intervals."
        return nothing
    end

    cp_r   = ThermoDatabase.calculate_cp(interval_data, T)
    h_rt   = ThermoDatabase.calculate_h(interval_data, T)
    s_r    = ThermoDatabase.calculate_s(interval_data, T)

    R = ThermoDatabase.R_UNIVERSAL

    return Dict{String, Any}(
        "temperature"   => T,
        "cp"            => cp_r * R,
        "h_relative"    => h_rt * T * R,
        "s"             => s_r * R,
        "temp_min"      => interval_data["temp_min"],
        "temp_max"      => interval_data["temp_max"],
        "species_name"  => info["name"],
        "phase"         => info["phase"],
    )
end

"""
    calculate_formation_enthalpy(calc::Calculator, species_id::Int) -> Union{Float64, Nothing}

Return the enthalpy of formation at 298.15 K (J/mol).
"""
function calculate_formation_enthalpy(calc::Calculator, species_id::Int)
    species_data = ThermoDatabase.get_species_data(calc.db, species_id)
    if species_data === nothing
        @warn "Species ID $species_id not found."
        return nothing
    end
    return get(species_data, "heat_of_formation_298K", nothing)
end

"""
    calculate_enthalpy_change(calc::Calculator, species_id::Int,
                              T1::Float64, T2::Float64) -> Union{Float64, Nothing}

Calculate ΔH = H(T2) - H(T1) for a species.

Returns the enthalpy change in J/mol, or `nothing` if calculation fails.
"""
function calculate_enthalpy_change(calc::Calculator, species_id::Int,
                                    T1::Float64, T2::Float64)
    props1 = calculate_properties(calc, species_id, T1)
    props2 = calculate_properties(calc, species_id, T2)

    if props1 === nothing || props2 === nothing
        return nothing
    end

    return props2["h_relative"] - props1["h_relative"]
end

"""
    get_properties_range(calc::Calculator, species_id::Int,
                         T_range::AbstractVector{<:Real}) -> Vector{Dict}

Calculate thermochemical properties over a range of temperatures.

Returns a vector of property dicts (same format as `calculate_properties`).
"""
function get_properties_range(calc::Calculator, species_id::Int,
                               T_range::AbstractVector{<:Real})
    results = Dict{String, Any}[]
    for T in T_range
        props = calculate_properties(calc, species_id, Float64(T))
        if props !== nothing
            push!(results, props)
        end
    end
    return results
end

end # module ThermoCalculator
