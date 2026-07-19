#!/usr/bin/env julia
#=
# Getting started with Glenn.jl

This script walks through the essential workflow of the **Glenn.jl** library:

1. Connect to the thermochemical database (bundled, no manual setup);
2. Look up a chemical species;
3. Compute Cₚ(T), H°(T) and S°(T) at a given temperature.

The `thermo.db` database ships inside the package — just instantiate
`Calculator()` with no arguments.
=#

using Glenn
using Printf

println("Glenn.jl imported successfully")
println("Version: ", Glenn.__version__)
println()

# ------------------------------------------------------------------
# Looking up a species
# ------------------------------------------------------------------

println("="^60)
println("Looking up species")
println("="^60)

# Use get_available_species with a search pattern to find the identifier
# (`id`) of the species you want.
calc = Calculator()

species = get_available_species(calc, "CH4")
for s in species[1:min(5, end)]
    @printf("  id=%5d  %-12s phase=%s\n", s["id"], s["name"], s["phase"])
end

# Also try O2
println()
species = get_available_species(calc, "O2")
for s in species[1:min(5, end)]
    @printf("  id=%5d  %-12s phase=%s  MW=%.4f\n",
        s["id"], s["name"], s["phase"], get(s, "molecular_weight", 0.0))
end

# ------------------------------------------------------------------
# Computing thermochemical properties
# ------------------------------------------------------------------

println()
println("="^60)
println("Computing thermochemical properties")
println("="^60)

# With the `id` in hand, `calculate_properties(species_id, temperature)`
# returns a dictionary with Cp, H° (relative to 0 K) and S°.
species_ch4 = only(s for s in get_available_species(calc, "CH4") if s["name"] == "CH4")
result = calculate_properties(calc, species_ch4["id"], 298.15)

println("Species : ", result["species_name"], " (", result["phase"], ")")
println("T       : ", round(result["temperature"], digits=2), " K")
println("Cp      : ", round(result["cp"], digits=3), " J/(mol·K)")
println("H°      : ", round(result["h_relative"], digits=3), " J/mol")
println("S°      : ", round(result["s"], digits=3), " J/(mol·K)")

# ------------------------------------------------------------------
# Sweeping a temperature range
# ------------------------------------------------------------------

println()
println("="^60)
println("Sweeping a temperature range")
println("="^60)

temperatures = [300.0, 500.0, 800.0, 1000.0, 1500.0]

species_id = species_ch4["id"]
@printf("  %8s | %14s\n", "T (K)", "Cp (J/mol·K)")
println("  " * "-"^27)
for T in temperatures
    r = calculate_properties(calc, species_id, T)
    if r !== nothing
        @printf("  %8.1f | %14.3f\n", T, r["cp"])
    end
end

# ------------------------------------------------------------------
# Enthalpy of formation
# ------------------------------------------------------------------

println()
println("="^60)
println("Enthalpy of formation")
println("="^60)

for name in ["CH4", "O2", "CO2", "H2O"]
    sp_list = get_available_species(calc, name)
    sp_match = [s for s in sp_list if s["name"] == name && s["phase"] == "gas"]
    if isempty(sp_match)
        println("  $(rpad(name, 8))  species not found in database")
        continue
    end
    sp = sp_match[1]
    h_f = calculate_formation_enthalpy(calc, sp["id"])
    if h_f !== nothing && !ismissing(h_f)
        @printf("  %-8s  ΔH°f(298.15 K) = %12.1f J/mol  (%8.3f kJ/mol)\n",
            name, Float64(h_f), Float64(h_f) / 1000.0)
    else
        println("  $(rpad(name, 8))  ΔH°f(298.15 K) = N/A")
    end
end

close(calc)
println()
println("Done!")
