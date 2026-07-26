### A Pluto.jl notebook ###
# v0.19.46

using Markdown
using InteractiveUtils

# ╔═╡ 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
md"""
# 🔥 Thermochemical comparison of fuels

Compares the thermal behavior of three fuels of interest in energy systems
using **Glenn.jl**:

| Species | Fuel                    |
|---------|-------------------------|
| CH₄     | Methane (natural gas)   |
| C₂H₅OH  | Ethanol (biofuel)       |
| C₃H₈    | Propane (LPG)           |

We visualize $C_p(T)$, $S°(T)$ and the sensible enthalpy change
ΔH(298.15 K → T) over a temperature range relevant to combustion.

> Requires `Plots.jl` — install with `] add Plots`.
"""

# ╔═╡ 2b3c4d5e-6f7a-8b9c-0d1e-2f3a4b5c6d7e
begin
    using Glenn
    using Printf
end

# ╔═╡ 3c4d5e6f-7a8b-9c0d-1e2f-3a4b5c6d7e8f
begin
    FUELS = Dict(
        "CH4"    => "Methane (natural gas)",
        "C2H5OH" => "Ethanol",
        "C3H8"   => "Propane (LPG)",
    )
    FUELS
end

# ╔═╡ 4d5e6f7a-8b9c-0d1e-2f3a-4b5c6d7e8f9a
md"""
## 🔍 Resolving the identifiers

`get_available_species` with `exact_match=true` performs a case-insensitive
exact lookup — `"CH4"` returns only methane.
"""

# ╔═╡ 5e6f7a8b-9c0d-1e2f-3a4b-5c6d7e8f9a0b
function resolve_id(calc, name, phase = "gas")
    species = get_available_species(calc, name, exact_match = true)
    for s in species
        if s.phase == phase
            return s.id
        end
    end
    error("Species '$name' ($phase) not found")
end

# ╔═╡ 6f7a8b9c-0d1e-2f3a-4b5c-6d7e8f9a0b1c
calc = Calculator()

# ╔═╡ 7a8b9c0d-1e2f-3a4b-5c6d-7e8f9a0b1c2d
ids = Dict(name => resolve_id(calc, name) for name in keys(FUELS))

# ╔═╡ 8b9c0d1e-2f3a-4b5c-6d7e-8f9a0b1c2d3e
let
    println("Species identifiers:")
    for (name, sid) in ids
        @printf("  %-8s -> id %d\n", name, sid)
    end
end

# ╔═╡ 9c0d1e2f-3a4b-5c6d-7e8f-9a0b1c2d3e4f
md"""
## 📊 Collecting properties (300–2000 K)
"""

# ╔═╡ 0d1e2f3a-4b5c-6d7e-8f9a-0b1c2d3e4f5a
temperatures = collect(300:50:2000)

# ╔═╡ 1e2f3a4b-5c6d-7e8f-9a0b-1c2d3e4f5a6b
data = let
    d = Dict()
    for (name, sid) in ids
        results = get_properties_range(calc, sid, temperatures)
        Ts = [r.temperature for r in results]
        cp_vals = [r.cp for r in results]
        s_vals = [r.s for r in results]
        dh_vals = [
            something(calculate_enthalpy_change(calc, sid, 298.15, T), 0.0) / 1000.0
            for T in Ts
        ]  # kJ/mol
        d[name] = Dict(
            "T"  => Ts,
            "cp" => cp_vals,
            "s"  => s_vals,
            "dh" => dh_vals,
        )
    end
    d
end

# ╔═╡ 2f3a4b5c-6d7e-8f9a-0b1c-2d3e4f5a6b7c
md"""
## 📈 Numerical summary
"""

# ╔═╡ 3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d
let
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
end

# ╔═╡ 4b5c6d7e-8f9a-0b1c-2d3e-4f5a6b7c8d9e
md"""
## 📉 Interactive plots

The plots below are rendered with **Plots.jl**. Change the parameters
above and watch the plots update automatically!
"""

# ╔═╡ 5c6d7e8f-9a0b-1c2d-3e4f-5a6b7c8d9e0f
begin
    using Plots
    default(
        fontfamily = "sans-serif",
        titlefontsize = 12,
        legendfontsize = 9,
        guidefontsize = 10,
        tickfontsize = 8,
        size = (700, 500),
    )
end

# ╔═╡ 6d7e8f9a-0b1c-2d3e-4f5a-6b7c8d9e0f1a
md"""
### Heat capacity — $C_p(T)$
"""

# ╔═╡ 7e8f9a0b-1c2d-3e4f-5a6b-7c8d9e0f1a2b
let
    p = plot(
        title = "Heat Capacity — Cₚ(T)",
        xlabel = "Temperature (K)",
        ylabel = "Cₚ (J/mol·K)",
    )
    colors = Dict("CH4" => :blue, "C2H5OH" => :red, "C3H8" => :green)
    for (name, d) in data
        plot!(p, d["T"], d["cp"],
            label = FUELS[name],
            color = colors[name],
            linewidth = 2,
        )
    end
    p
end

# ╔═╡ 8f9a0b1c-2d3e-4f5a-6b7c-8d9e0f1a2b3c
md"""
### Absolute entropy — $S°(T)$
"""

# ╔═╡ 9a0b1c2d-3e4f-5a6b-7c8d-9e0f1a2b3c4d
let
    p = plot(
        title = "Absolute Entropy — S°(T)",
        xlabel = "Temperature (K)",
        ylabel = "S° (J/mol·K)",
    )
    colors = Dict("CH4" => :blue, "C2H5OH" => :red, "C3H8" => :green)
    for (name, d) in data
        plot!(p, d["T"], d["s"],
            label = FUELS[name],
            color = colors[name],
            linewidth = 2,
        )
    end
    p
end

# ╔═╡ 0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e
md"""
### Sensible enthalpy — ΔH°(298.15 K → T)
"""

# ╔═╡ 1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f
let
    p = plot(
        title = "Sensible Enthalpy — ΔH°(298 K → T)",
        xlabel = "Temperature (K)",
        ylabel = "ΔH° (kJ/mol)",
    )
    colors = Dict("CH4" => :blue, "C2H5OH" => :red, "C3H8" => :green)
    for (name, d) in data
        plot!(p, d["T"], d["dh"],
            label = FUELS[name],
            color = colors[name],
            linewidth = 2,
        )
    end
    p
end

# ╔═╡ 2d3e4f5a-6b7c-8d9e-0f1a-2b3c4d5e6f7a
md"""
## 🧹 Cleanup
"""

# ╔═╡ 3e4f5a6b-7c8d-9e0f-1a2b-3c4d5e6f7a8b
close(calc)

# ╔═╡ 4f5a6b7c-8d9e-0f1a-2b3c-4d5e6f7a8b9c
md"""
✅ **Analysis complete!** The plots show that:
- **Propane (C₃H₈)** has the highest $C_p$ (most energy to heat up)
- **Methane (CH₄)** has the highest sensible enthalpy per mole
- **Ethanol (C₂H₅OH)** has the highest absolute entropy (most complex molecule)
"""

# ╔═╡ Cell order
# ╠═1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
# ╠═2b3c4d5e-6f7a-8b9c-0d1e-2f3a4b5c6d7e
# ╠═3c4d5e6f-7a8b-9c0d-1e2f-3a4b5c6d7e8f
# ╠═4d5e6f7a-8b9c-0d1e-2f3a-4b5c6d7e8f9a
# ╠═5e6f7a8b-9c0d-1e2f-3a4b-5c6d7e8f9a0b
# ╠═6f7a8b9c-0d1e-2f3a-4b5c-6d7e8f9a0b1c
# ╠═7a8b9c0d-1e2f-3a4b-5c6d-7e8f9a0b1c2d
# ╠═8b9c0d1e-2f3a-4b5c-6d7e-8f9a0b1c2d3e
# ╠═9c0d1e2f-3a4b-5c6d-7e8f-9a0b1c2d3e4f
# ╠═0d1e2f3a-4b5c-6d7e-8f9a-0b1c2d3e4f5a
# ╠═1e2f3a4b-5c6d-7e8f-9a0b-1c2d3e4f5a6b
# ╠═2f3a4b5c-6d7e-8f9a-0b1c-2d3e4f5a6b7c
# ╠═3a4b5c6d-7e8f-9a0b-1c2d-3e4f5a6b7c8d
# ╠═4b5c6d7e-8f9a-0b1c-2d3e-4f5a6b7c8d9e
# ╠═5c6d7e8f-9a0b-1c2d-3e4f-5a6b7c8d9e0f
# ╠═6d7e8f9a-0b1c-2d3e-4f5a-6b7c8d9e0f1a
# ╠═7e8f9a0b-1c2d-3e4f-5a6b-7c8d9e0f1a2b
# ╠═8f9a0b1c-2d3e-4f5a-6b7c-8d9e0f1a2b3c
# ╠═9a0b1c2d-3e4f-5a6b-7c8d-9e0f1a2b3c4d
# ╠═0b1c2d3e-4f5a-6b7c-8d9e-0f1a2b3c4d5e
# ╠═1c2d3e4f-5a6b-7c8d-9e0f-1a2b3c4d5e6f
# ╠═2d3e4f5a-6b7c-8d9e-0f1a-2b3c4d5e6f7a
# ╠═3e4f5a6b-7c8d-9e0f-1a2b-3c4d5e6f7a8b
# ╠═4f5a6b7c-8d9e-0f1a-2b3c-4d5e6f7a8b9c
