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
Wraps a `ThermoDB` connection and the dataset reference gas constant.

Call without arguments to use the bundled `thermo.db`:
calc = Calculator()
"""
mutable struct Calculator
    db::ThermoDatabase.ThermoDB
    R_ref::Float64
end

"""
    Calculator(path::String) -> Calculator

Create a Calculator connected to a thermo.db database.
Defaults to the bundled database shipped with the package.

The reference gas constant `R_ref` is read from the dataset `metadata` table
so that dimensionless NASA-7 coefficients are denormalised with the same
constant used in the original fit.
"""
function Calculator(path::String = default_db_path())
    db = ThermoDatabase.ThermoDB(path)
    return Calculator(db, ThermoDatabase.get_gas_constant_ref(db.db))
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
    get_available_species(calc::Calculator, pattern::AbstractString=""; exact_match::Bool=false) -> Vector{SpeciesInfo}

Return a list of available species, optionally filtered by name pattern.

If `exact_match=false` (default), performs a substring search. Use
`exact_match=true` for case-insensitive exact match — only the species
whose name matches the pattern exactly is returned (e.g. ``"N2"`` returns
only N₂, not Be₃N₂).
"""
function get_available_species(
    calc::Calculator,
    pattern::AbstractString = "";
    exact_match::Bool = false,
)
    if isempty(pattern)
        # Single query for all species — much faster than paginating
        return ThermoDatabase.list_all_species(calc.db)
    else
        return ThermoDatabase.find_species(calc.db, pattern; exact_match = exact_match)
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
        throw(SpeciesNotFoundError(species_id))
    end

    interval_data = ThermoDatabase.get_species_for_temperature(calc.db, species_id, T)

    if interval_data === nothing
        throw(
            TemperatureOutOfRangeError(
                T,
                info.name,
                ThermoDatabase.get_temperature_bounds(calc.db, species_id),
            ),
        )
    end

    cp_r = ThermoDatabase.calculate_cp(interval_data.coefficients, T)
    h_rt = ThermoDatabase.calculate_h(interval_data.coefficients, T)
    s_r = ThermoDatabase.calculate_s(interval_data.coefficients, T)

    R = calc.R_ref   # dataset reference gas constant, not the system universal one

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
    calculate_properties_range(calc::Calculator, species_id::Int, T_range;
                               strict::Bool=false) -> Vector{ThermoProperties}

Calculate thermochemical properties for many temperatures at once.

The species' intervals are loaded with a single query and the polynomials are
evaluated in memory, which is much faster than calling the scalar
`calculate_properties` in a loop. Input order is preserved.

Temperatures outside the species' valid intervals are skipped when
`strict=false` (default). With `strict=true` the first out-of-range temperature
raises `TemperatureOutOfRangeError`.

Throws `SpeciesNotFoundError` if the species ID is invalid.
"""
function calculate_properties_range(
    calc::Calculator,
    species_id::Int,
    T_range::AbstractVector{<:Real};
    strict::Bool = false,
)
    info = ThermoDatabase.get_species_info(calc.db, species_id)
    if info === nothing
        throw(SpeciesNotFoundError(species_id))
    end

    # Load ALL intervals for this species (single query)
    species_data = ThermoDatabase.get_species_data(calc.db, species_id)
    if species_data === nothing
        throw(SpeciesNotFoundError(species_id))
    end
    intervals = species_data.intervals  # Vector{IntervalData}
    R = calc.R_ref   # dataset reference gas constant

    bounds = nothing
    if strict
        bounds = ThermoDatabase.get_temperature_bounds(calc.db, species_id)
    end

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
        if interval_data === nothing
            strict && throw(TemperatureOutOfRangeError(Tf, info.name, bounds))
            continue  # skip out-of-range
        end

        cp_r = ThermoDatabase.calculate_cp(interval_data.coefficients, Tf)
        h_rt = ThermoDatabase.calculate_h(interval_data.coefficients, Tf)
        s_r = ThermoDatabase.calculate_s(interval_data.coefficients, Tf)

        push!(
            results,
            ThermoProperties(
                Tf,
                cp_r * R,
                h_rt * Tf * R,
                s_r * R,
                interval_data.temp_min,
                interval_data.temp_max,
                info.name,
                info.phase,
            ),
        )
    end

    return results
end

"""
    calculate_properties(calc::Calculator, species_id::Int,
                         T_range::AbstractVector{<:Real}) -> Vector{ThermoProperties}

Vectorized form of `calculate_properties`, kept for convenience.

Equivalent to [`calculate_properties_range`](@ref) with `strict=false`:
temperatures outside the valid intervals are skipped.
"""
function calculate_properties(
    calc::Calculator,
    species_id::Int,
    T_range::AbstractVector{<:Real},
)
    return calculate_properties_range(calc, species_id, T_range)
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
        throw(SpeciesNotFoundError(species_id))
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
function calculate_enthalpy_change(
    calc::Calculator,
    species_id::Int,
    T1::Float64,
    T2::Float64,
)
    props1 = calculate_properties(calc, species_id, T1)
    props2 = calculate_properties(calc, species_id, T2)
    return props2.h_relative - props1.h_relative
end

"""
    h_sensible_to(calc::Calculator, species_id::Int, T::Float64,
                  t_ref::Float64=298.15) -> Float64

Sensible enthalpy ΔH = H(T) − H(t_ref), in J/mol.

Convenience wrapper around `calculate_enthalpy_change` with a default reference
temperature of 298.15 K.
"""
function h_sensible_to(
    calc::Calculator,
    species_id::Int,
    T::Float64,
    t_ref::Float64 = 298.15,
)
    return calculate_enthalpy_change(calc, species_id, t_ref, T)
end

"""
    dcp_dt(calc::Calculator, species_id::Int, T::Float64) -> Float64

Analytical temperature derivative of the heat capacity at `T`, in
J/(mol·K²).

The NASA-7 polynomial is differentiated term by term and denormalised with the
dataset reference gas constant:

```math
\\frac{dC_p}{dT} = R_0 \\left( -\\frac{2a_1}{T^3} - \\frac{a_2}{T^2}
+ a_4 + 2a_5 T + 3a_6 T^2 + 4a_7 T^3 \\right)
```

Throws `SpeciesNotFoundError` for an invalid ID and
`TemperatureOutOfRangeError` outside the species' intervals.
"""
function dcp_dt(calc::Calculator, species_id::Int, T::Float64)
    info = ThermoDatabase.get_species_info(calc.db, species_id)
    if info === nothing
        throw(SpeciesNotFoundError(species_id))
    end

    interval_data = ThermoDatabase.get_species_for_temperature(calc.db, species_id, T)
    if interval_data === nothing
        throw(
            TemperatureOutOfRangeError(
                T,
                info.name,
                ThermoDatabase.get_temperature_bounds(calc.db, species_id),
            ),
        )
    end

    c = interval_data.coefficients
    dcp_r =
        -2.0 * c.a1 / T^3 - c.a2 / T^2 + c.a4 +
        2.0 * c.a5 * T + 3.0 * c.a6 * T^2 + 4.0 * c.a7 * T^3
    return dcp_r * calc.R_ref
end

"""
    gamma(calc::Calculator, species_id::Int, T::Float64) -> Float64

Ratio of specific heats `Cp/Cv` at `T`, assuming an ideal gas (`Cv = Cp - R`).

Not exported, because `gamma` is also the name of a well-known special function
(SpecialFunctions.jl); call it as `Glenn.gamma(calc, id, T)`.

Throws `SpeciesNotFoundError`, `TemperatureOutOfRangeError`, or `ThermoError`
when `Cp <= R` (which would make the ratio undefined).
"""
function gamma(calc::Calculator, species_id::Int, T::Float64)
    props = calculate_properties(calc, species_id, T)
    cv = props.cp - calc.R_ref
    if cv <= 0.0
        throw(
            ThermoCalcError(
                "Cp ($(props.cp) J/(mol·K)) is not greater than R_ref " *
                "($(calc.R_ref) J/(mol·K)) for '$(props.species_name)' at $T K; " *
                "Cp/Cv is undefined",
            ),
        )
    end
    return props.cp / cv
end

"""
    mixture_properties(calc::Calculator, mixture::Mixture, T::Float64;
                       strict::Bool=true) -> MixedProperties

Properties of a mixture with a known composition at temperature `T`.

No chemical equilibrium is solved: the composition is an input. Molar
properties are the mole-fraction-weighted sum of the components' properties;
mass properties divide them by the mole-fraction-weighted mean molar mass
`M = Σ xᵢ Mᵢ`.

With `strict=true` (default) any component outside its valid temperature range
raises `TemperatureOutOfRangeError`. With `strict=false` those components are
skipped, the remaining mole fractions are renormalised, and a warning is logged.

Throws `CompositionError` for an invalid composition or a component without a
usable molecular weight, and `SpeciesNotFoundError` for an unknown component.
"""
function mixture_properties(
    calc::Calculator,
    mixture::Mixture,
    T::Float64;
    strict::Bool = true,
)
    validate(mixture)

    comps = Tuple{Float64, ThermoProperties, Float64}[]
    skipped = String[]

    for (species_id, fraction) in mixture.species
        info = ThermoDatabase.get_species_info(calc.db, species_id)
        if info === nothing
            throw(SpeciesNotFoundError(species_id))
        end

        mw = info.molecular_weight
        if mw === nothing || ismissing(mw) || mw <= 0.0
            throw(
                CompositionError(
                    "species '$(info.name)' (id $species_id) has no valid molecular weight",
                ),
            )
        end

        props = try
            calculate_properties(calc, species_id, T)
        catch e
            if e isa TemperatureOutOfRangeError && !strict
                push!(skipped, info.name)
                continue
            end
            rethrow()
        end

        push!(comps, (fraction, props, Float64(mw) / 1000.0))
    end

    if isempty(comps)
        throw(TemperatureOutOfRangeError(T, "mixture", nothing))
    end

    if !isempty(skipped)
        total_x = sum(first, comps)
        comps = [(x / total_x, p, m) for (x, p, m) in comps]
        @warn "mixture_properties skipped out-of-range components at $T K and " *
              "renormalised the remaining mole fractions" skipped
    end

    molar_mass = sum(x * m for (x, _, m) in comps)
    cp_molar = sum(x * p.cp for (x, p, _) in comps)
    h_molar = sum(x * p.h_relative for (x, p, _) in comps)
    s_molar = sum(x * p.s for (x, p, _) in comps)

    return MixedProperties(
        T,
        cp_molar,
        h_molar,
        s_molar,
        molar_mass,
        cp_molar / molar_mass,
        h_molar / molar_mass,
        s_molar / molar_mass,
    )
end

# Deprecated 0.4.x name, kept for backwards compatibility.
# (`Base.@deprecate` expands to an `export` plus a method definition, so it
# cannot carry a docstring.)
Base.@deprecate get_properties_range(
    calc::Calculator,
    species_id::Int,
    T_range::AbstractVector{<:Real},
) calculate_properties_range(
    calc,
    species_id,
    T_range,
)

end # module ThermoCalculator
