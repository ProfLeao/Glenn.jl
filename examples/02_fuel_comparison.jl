#!/usr/bin/env julia
#=
# Thermochemical comparison of fuels

This script compares the thermal behavior of three fuels of interest in
energy systems, using **Glenn.jl**:

| Species | Fuel                    |
|---------|-------------------------|
| CH₄     | Methane (natural gas)   |
| C₂H₅OH  | Ethanol (biofuel)       |
| C₃H₈    | Propane (LPG)           |

We will visualize Cₚ(T), S°(T) and the sensible enthalpy change
ΔH(298.15 K → T) over a temperature range relevant to combustion.

> **Requires** `Plots.jl` — install with `] add Plots StatsPlots`.
=#

using Glenn
using Printf

# ------------------------------------------------------------------
# Fuel definitions
# ------------------------------------------------------------------

FUELS = Dict(
    "CH4"    => "Methane (natural gas)",
    "C2H5OH" => "Ethanol",
    "C3H8"   => "Propane (LPG)",
)

# ------------------------------------------------------------------
# Resolving the identifiers
# ------------------------------------------------------------------

println("="^60)
println("Resolving species identifiers")
println("="^60)

function resolve_id(calc, name, phase="gas")
    for s in get_available_species(calc, name)
        if s["name"] == name && s["phase"] == phase
            return s["id"]
        end
    end
    error("Species '$name' ($phase) not found")
end

calc = Calculator()
ids = Dict(name => resolve_id(calc, name) for name in keys(FUELS))

for (name, sid) in ids
    @printf("  %-8s -> id %d\n", name, sid)
end

# ------------------------------------------------------------------
# Collecting properties over 300–2000 K
# ------------------------------------------------------------------

println()
println("="^60)
println("Collecting properties over 300–2000 K")
println("="^60)

temperatures = collect(300:50:2000)

data = Dict()
for (name, sid) in ids
    results = get_properties_range(calc, sid, temperatures)
    Ts = [r["temperature"] for r in results]
    cp_vals = [r["cp"] for r in results]
    s_vals = [r["s"] for r in results]
    dh_vals = [
        something(calculate_enthalpy_change(calc, sid, 298.15, T), 0.0) / 1000.0
        for T in Ts
    ]  # kJ/mol
    data[name] = Dict(
        "T"  => Ts,
        "cp" => cp_vals,
        "s"  => s_vals,
        "dh" => dh_vals,
    )
end

println("Properties collected for: ", join(keys(data), ", "))

# ------------------------------------------------------------------
# Numerical summary at reference points
# ------------------------------------------------------------------

println()
println("="^60)
println("Numerical summary at reference points")
println("="^60)

targets = [300, 1000, 2000]
@printf("  %-22s %6s %10s %10s\n", "Fuel", "T (K)", "Cp", "S°")
println("  " * "-"^50)
for (name, d) in data
    for T in targets
        i = findfirst(x -> x == Float64(T), d["T"])
        if i !== nothing
            @printf("  %-22s %6d %10.3f %10.3f\n",
                FUELS[name], T, d["cp"][i], d["s"][i])
        end
    end
    println()
end

close(calc)

# ------------------------------------------------------------------
# Try to plot (non-blocking — skip if Plots not available)
# ------------------------------------------------------------------

println("="^60)
println("Generating plots...")
println("="^60)

try
    using Plots
    gr()

    # --- Cp(T) plot ---
    p1 = plot(
        title  = "Molar specific heat at constant pressure",
        xlabel = "Temperature (K)",
        ylabel = "Cp  (J·mol⁻¹·K⁻¹)",
        legend = :topleft,
        grid   = true,
    )
    colors = palette(:default, length(data))
    for (i, (name, d)) in enumerate(data)
        plot!(p1, d["T"], d["cp"], label=FUELS[name], lw=2, color=colors[i])
    end
    savefig(p1, "examples/cp_comparison.png")
    println("  -> Saved examples/cp_comparison.png")

    # --- Sensible enthalpy plot ---
    p2 = plot(
        title  = "Sensible enthalpy relative to 298.15 K",
        xlabel = "Temperature (K)",
        ylabel = "ΔH  (kJ·mol⁻¹)",
        legend = :topleft,
        grid   = true,
    )
    hline!(p2, [0.0], color=:gray, lw=0.8, label=nothing)
    for (i, (name, d)) in enumerate(data)
        plot!(p2, d["T"], d["dh"], label=FUELS[name], lw=2, color=colors[i])
    end
    savefig(p2, "examples/dh_comparison.png")
    println("  -> Saved examples/dh_comparison.png")

    # --- S°(T) plot ---
    p3 = plot(
        title  = "Absolute entropy",
        xlabel = "Temperature (K)",
        ylabel = "S°  (J·mol⁻¹·K⁻¹)",
        legend = :topleft,
        grid   = true,
    )
    for (i, (name, d)) in enumerate(data)
        plot!(p3, d["T"], d["s"], label=FUELS[name], lw=2, color=colors[i])
    end
    savefig(p3, "examples/s_comparison.png")
    println("  -> Saved examples/s_comparison.png")

catch e
    println("  Plots.jl not available — skipping graphs.")
    println("  Install with: ] add Plots")
    println("  Error: ", e isa ArgumentError ? "Package not found" : sprint(showerror, e))
end

println()
println("Done!")
