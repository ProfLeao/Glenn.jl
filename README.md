# Glenn.jl — Thermochemical Properties Calculator for Julia

[![Build Status](https://github.com/ProfLeao/Glenn.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/ProfLeao/Glenn.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Stable Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://profleao.github.io/Glenn.jl/)
[![Dev Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://profleao.github.io/Glenn.jl/)

Computes **Cp(T)**, **H°(T)**, **S°(T)** from NASA-7 polynomial coefficients
stored in a SQLite database. The database is **bundled** with the package —
`Calculator()` works out of the box with zero configuration.

## Features

- **Zero-config**: `Calculator()` uses the bundled `thermo.db` — no setup needed
- **Context manager**: Automatic connection management with `do`-block syntax
- **Exact-match species lookup**: `exact_match=true` for case-insensitive exact search (e.g. `"N2"` returns only N₂, not Be₃N₂)
- Query species by name, phase, molecular weight
- Calculate Cp(T), H°(T), S°(T) at any valid temperature
- Enthalpy of formation lookup
- Enthalpy change between two temperatures (ΔH)
- Properties over arbitrary temperature ranges
- Build databases from NASA FORTRAN `thermo.inp` files
- Command-line interface (`build` and `query`)
- **NIST-JANAF cross-validation** — validated against reference data for 7 species (CO₂, N₂, CO, H₂O, O₂, NH₃, SO₂)
- ~2030 species, 3772 temperature intervals
- Full [Documenter.jl](https://documenter.juliadocs.org) documentation

## Installation

```julia
using Pkg
Pkg.add("Glenn")
```

Or from source:

```bash
git clone https://github.com/ProfLeao/Glenn.jl.git
cd Glenn.jl
julia --project -e 'import Pkg; Pkg.instantiate()'
```

## Quick Start

### Basic usage

The database ships **inside the package** — `Calculator()` works immediately
with zero configuration. All properties are returned in SI units
(Cp, S° → J/(mol·K); H° → J/mol).

```julia
using Glenn

# No setup needed — uses the bundled thermo.db
calc = Calculator()

# exact_match=true: case-insensitive exact lookup
# "O2" returns only O₂, not Al₂O₂ or Be₃N₂
o2 = only(get_available_species(calc, "O2", exact_match = true))

# Single-point calculation at 1000 K
props = calculate_properties(calc, o2.id, 1000.0)
println("Species:  ", props.species_name, " (", props.phase, ")")
println("T       = ", props.temperature, " K")
println("Cp      = ", round(props.cp, digits = 2), " J/(mol·K)")
println("H°      = ", round(props.h_relative, digits = 1), " J/mol")
println("S°      = ", round(props.s, digits = 3), " J/(mol·K)")

# Enthalpy of formation
hf = calculate_formation_enthalpy(calc, o2.id)   # J/mol

# Enthalpy change between two temperatures
dh = calculate_enthalpy_change(calc, o2.id, 300.0, 1500.0)

# Properties over a temperature range (vectorized — fast)
results = get_properties_range(calc, o2.id, 300:50:2000)

close(calc)
```

### Context manager (`do`-block)

Use the `do`-block syntax for **automatic connection management** — the database
is opened before the block and closed after, even if an exception occurs.

```julia
using Glenn

# Recommended pattern: no manual connect/close needed
Calculator() do calc
    ch4 = only(get_available_species(calc, "CH4", exact_match = true))
    props = calculate_properties(calc, ch4.id, 500.0)
    println("Cp(CH₄, 500 K) = ", round(props.cp, digits = 2), " J/(mol·K)")
end
# Database is automatically closed here
```

You can also point to a custom database:

```julia
Calculator("path/to/custom.db") do calc
    # ... same API ...
end
```

### Building the database

> **⚠️ You do NOT need to build the database for normal use.**
> The package ships with a pre-built `thermo.db` containing ~2030 species
> and 3772 temperature intervals. `Calculator()` uses it automatically.

You only need to rebuild the database in these situations:

| Scenario | Why rebuild? |
|---|---|
| 🔧 **Custom coefficients** | You modified `thermo.inp` with your own NASA-7 parameters |
| 🔬 **Extended dataset** | You added new species to the FORTRAN source file |
| 🩹 **Corrupted database** | The `thermo.db` file was accidentally deleted or damaged |
| 📦 **Embedded deployment** | You want to ship a minimal DB with only specific species |

```julia
using Glenn

# Build from the bundled thermo.inp (shipped with the package)
builder = ThermoDBBuilder(default_inp_path(), "thermo.db")
ThermoBuilder.connect(builder)
ThermoBuilder.create_tables(builder)
ThermoBuilder.parse_and_load(builder)
ThermoBuilder.close(builder)

# Build from a custom FORTRAN file
builder = ThermoDBBuilder("my_thermo.inp", "my_thermo.db")
# ... same connect → create → parse → close cycle
```

### CLI

The command-line interface provides quick access to species data and
database operations without opening a REPL.

```bash
# Quick species lookup
julia --project -e 'using Glenn; Glenn.cli_main()' -- query -s CH4
julia --project -e 'using Glenn; Glenn.cli_main()' -- query -s CO2

# Or use the convenience script
julia --project bin/glenn.jl query -s O2

# Database rebuild (only if needed — see section above)
julia --project -e 'using Glenn; Glenn.cli_main()' -- build
julia --project bin/glenn.jl build -i custom.inp -o custom.db
```

### NIST-JANAF Cross-Validation

Run the cross-validation audit to compare Glenn.jl against NIST-JANAF reference data:

```bash
julia --project docs/audit/audit.jl
```

Outputs: `glenn_vs_nist.csv` (point-by-point comparison) and `validation_summary.txt` (aggregated statistics).

## API Reference

### Calculator (high-level)

| Function | Description |
|---|---|
| `Calculator()` | Open the **bundled** `thermo.db` |
| `Calculator(path)` | Open a custom database |
| `default_db_path()` | Resolve path to the bundled database |
| `get_available_species(calc, pattern; exact_match)` | List/filter species |
| `calculate_properties(calc, id, T)` | Compute Cp, H°, S° at T (K) → `ThermoProperties` |
| `calculate_formation_enthalpy(calc, id)` | ΔH°f at 298.15 K (J/mol) |
| `calculate_enthalpy_change(calc, id, T1, T2)` | ΔH = H(T2) − H(T1) |
| `get_properties_range(calc, id, Ts)` | Properties over multiple T |
| `close(calc)` | Close the connection |

### ThermoDBBuilder

| Function | Description |
|---|---|
| `ThermoDBBuilder(inp, db)` | Create a database builder |
| `ThermoBuilder.connect(builder)` | Open the SQLite database |
| `ThermoBuilder.create_tables(builder)` | Create normalized schema |
| `ThermoBuilder.parse_and_load(builder)` | Parse thermo.inp and populate DB |
| `ThermoBuilder.close(builder)` | Close and commit |

### ThermoDatabase (low-level)

| Function | Description |
|---|---|
| `ThermoDB(path)` | Raw SQLite connection |
| `get_statistics(tdb)` | Database summary stats |
| `find_species(tdb, name; exact_match)` | Search species by name (case-insensitive exact with `exact_match=true`) |
| `list_species_page(tdb; page, page_size)` | Paginated species listing |
| `get_species_data(tdb, id)` | Full species + intervals + coeffs |
| `get_species_for_temperature(tdb, id, T)` | Interval valid for T |
| `calculate_cp(coeffs, T)` | Cp/R (dimensionless) |
| `calculate_h(coeffs, T)` | H/RT (dimensionless) |
| `calculate_s(coeffs, T)` | S/R (dimensionless) |

## NASA-7 Polynomial Equations

$$\frac{C_p(T)}{R} = a_1 T^{-2} + a_2 T^{-1} + a_3 + a_4 T + a_5 T^2 + a_6 T^3 + a_7 T^4$$

$$\frac{H^\circ(T)}{RT} = -a_1 T^{-2} + a_2 \frac{\ln T}{T} + a_3 + a_4 \frac{T}{2} + a_5 \frac{T^2}{3} + a_6 \frac{T^3}{4} + a_7 \frac{T^4}{5} + \frac{b_1}{T}$$

$$\frac{S^\circ(T)}{R} = -\frac{a_1}{2} T^{-2} - a_2 T^{-1} + a_3 \ln T + a_4 T + a_5 \frac{T^2}{2} + a_6 \frac{T^3}{3} + a_7 \frac{T^4}{4} + b_2$$

All results are returned in SI units: Cp, S° → J/(mol·K), H° → J/mol.

## Requirements

- Julia ≥ 1.6
- SQLite.jl

## Database

The `thermo.db` database is **bundled** with the package (`data/thermo.db`).
It was generated by [`pyglenn`](https://github.com/ProfLeao/pyglenn)
from the NASA Glenn FORTRAN thermochemical tables.

| Table | Records | Description |
|---|---|---|
| `species` | 2030 | Chemical species (name, formula, phase, MW, ΔH°f) |
| `temperature_intervals` | 3772 | Valid T ranges per species |
| `coefficients` | 3772 | NASA-7 polynomial coefficients (a1–a7, b1, b2) |
| `file_metadata` | 1 | Global file metadata |

## Documentation

Full documentation is available at [profl.github.io/Glenn.jl/stable](https://profl.github.io/Glenn.jl/stable/).

## License

MIT — see [LICENSE](LICENSE)

