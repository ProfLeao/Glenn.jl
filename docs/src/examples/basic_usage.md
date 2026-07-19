```@meta
CurrentModule = Glenn
```

# Getting started with Glenn.jl

This tutorial walks through the essential workflow of the **Glenn.jl** library:

1. Connect to the thermochemical database (bundled, no manual setup);
2. Look up a chemical species;
3. Compute $C_p(T)$, $H^\circ(T)$ and $S^\circ(T)$ at a given temperature.

The `thermo.db` database ships inside the package — just instantiate
`Calculator()` with no arguments.

## Import and connect

```@repl basic_usage
using Glenn
calc = Calculator()
```

## Looking up a species

Use `get_available_species` with a search pattern to find the identifier
(`id`) of the species you want.

```@repl basic_usage
species = get_available_species(calc, "CH4")
for s in species[1:min(5, end)]
    println("id=", lpad(s["id"], 5), "  ", rpad(s["name"], 12), " phase=", s["phase"])
end

# Also look up O2 with molecular weight
o2_species = get_available_species(calc, "O2")
for s in o2_species
    println("id=", lpad(s["id"], 5), "  ", rpad(s["name"], 12),
            " phase=", s["phase"], "  MW=", round(get(s, "molecular_weight", 0.0), digits=4))
end
```

## Computing thermochemical properties

With the `id` in hand, `calculate_properties(species_id, temperature)`
returns a dictionary with $C_p$, $H^\circ$ (relative to 0 K) and $S^\circ$.

```@repl basic_usage
species_ch4 = only(s for s in get_available_species(calc, "CH4") if s["name"] == "CH4")
result = calculate_properties(calc, species_ch4["id"], 298.15)
println("Species: ", result["species_name"], " (", result["phase"], ")")
println("T:       ", round(result["temperature"], digits=2), " K")
println("Cp:      ", round(result["cp"], digits=3), " J/(mol·K)")
println("H°:      ", round(result["h_relative"], digits=3), " J/mol")
println("S°:      ", round(result["s"], digits=3), " J/(mol·K)")
```

## Sweeping a temperature range

A common task is to evaluate $C_p$ across several temperatures.

```@repl basic_usage
temperatures = [300.0, 500.0, 800.0, 1000.0, 1500.0]
species_id = species_ch4["id"]
println(rpad("T (K)", 8), " | ", "Cp (J/mol·K)")
println("-"^27)
for T in temperatures
    r = calculate_properties(calc, species_id, T)
    if r !== nothing
        @printf("%8.1f | %14.3f\n", T, r["cp"])
    end
end
```

## Enthalpy of formation

```@repl basic_usage
for name in ["CH4", "O2", "CO2", "H2O"]
    sp = only(s for s in get_available_species(calc, name) if s["name"] == name)
    h_f = calculate_formation_enthalpy(calc, sp["id"])
    if h_f !== nothing
        @printf("%-8s  ΔH°f(298.15 K) = %12.1f J/mol  (%8.3f kJ/mol)\n",
            name, h_f, h_f / 1000.0)
    end
end
```

```@repl basic_usage
close(calc)
```
