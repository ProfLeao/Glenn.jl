# Glenn.jl — Thermochemical Properties Calculator for Julia

[![Build Status](https://github.com/ProfLeao/Glenn.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/ProfLeao/Glenn.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Stable Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://profleao.github.io/Glenn.jl/)
[![Dev Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://profleao.github.io/Glenn.jl/)

Glenn.jl computes **Cp(T)**, **H°(T)**, and **S°(T)** from NASA-7 polynomial
coefficients stored in SQLite. The reference database is bundled with the
package, so `Calculator()` works immediately with no configuration.

The high-level API is intended for calculations and species lookup. A separate
builder and CLI are available when you need to create or inspect a database.

## What it provides

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
- ~2035 species, 3795 temperature intervals
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

**Requirements:** Julia 1.6 or later. SQLite.jl is installed automatically by
the Julia package manager.

## Quick Start

Use the `do`-block form to manage the database connection automatically. All
properties are returned in SI units: Cp and S° in J/(mol·K), and H° in J/mol.

```julia
using Glenn

Calculator() do calc
    o2 = only(get_available_species(calc, "O2", exact_match = true))
    props = calculate_properties(calc, o2.id, 1000.0)
    println("Cp(O2, 1000 K) = ", round(props.cp, digits = 2), " J/(mol·K)")
    println("H(O2, 1000 K) = ", round(props.h_relative, digits = 1), " J/mol")
    println("S(O2, 1000 K) = ", round(props.s, digits = 3), " J/(mol·K)")
end
```

`exact_match=true` performs a case-insensitive exact lookup. Without it, the
default is a case-insensitive substring search.

For a custom database, pass its path to `Calculator`:

```julia
Calculator("path/to/custom.db") do calc
    # ... same API ...
end
```

### Additional calculations

```julia
Calculator() do calc
    ch4 = only(get_available_species(calc, "CH4", exact_match = true))

    hf = calculate_formation_enthalpy(calc, ch4.id)       # J/mol
    dh = calculate_enthalpy_change(calc, ch4.id, 300.0, 1500.0)
    results = get_properties_range(calc, ch4.id, 300:50:2000)
end
```

### Building a database

> **⚠️ You do NOT need to build the database for normal use.**
> The package ships with a pre-built `thermo.db` containing 2035 species
> and 3795 temperature intervals. `Calculator()` uses it automatically.

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
build_database(default_inp_path(), "thermo.db")

# Build from a custom FORTRAN file
build_database("my_thermo.inp", "my_thermo.db")
```

The builder is only needed for a custom or regenerated dataset. The bundled
database should be used for normal calculations.

To regenerate the bundled database reproducibly — with integrity checks and
release gates (expected species, intervals and coefficient sets) — use the
rebuild script. It writes next to the target and only replaces it after every
check passes:

```bash
julia --project=. scripts/rebuild_database.jl
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

### Validation

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
| `calculate_properties_range(calc, id, Ts; strict)` | Properties over many temperatures (skips out-of-range, or raises with `strict=true`) |
| `calculate_formation_enthalpy(calc, id)` | ΔH°f at 298.15 K (J/mol) |
| `calculate_enthalpy_change(calc, id, T1, T2)` | ΔH = H(T2) − H(T1) |
| `h_sensible_to(calc, id, T, t_ref=298.15)` | Sensible enthalpy H(T) − H(t_ref) |
| `dcp_dt(calc, id, T)` | Analytical dCp/dT, J/(mol·K²) |
| `Glenn.gamma(calc, id, T)` | Cp/Cv for an ideal gas (not exported) |
| `mixture_properties(calc, mixture, T; strict)` | Mix properties on molar and mass basis → `MixedProperties` |
| `get_properties_range(calc, id, Ts)` | **Deprecated** — use `calculate_properties_range` |
| `close(calc)` | Close the connection |

### ThermoDBBuilder

| Function | Description |
|---|---|
| `ThermoDBBuilder(inp, db)` | Create a database builder |
| `build_database(inp, db)` | Build a database in one call (recommended) |
| `Glenn.connect(builder)` | Open the SQLite database |
| `Glenn.create_tables(builder)` | Create normalized schema |
| `Glenn.parse_and_load(builder)` | Parse thermo.inp and populate DB |
| `close(builder)` | Close and commit |

### ThermoDatabase (low-level)

| Function | Description |
|---|---|
| `ThermoDB(path)` | Raw SQLite connection |
| `get_statistics(tdb)` | Database summary stats → `DatabaseStats` |
| `get_gas_constant_ref(db)` | Dataset reference gas constant |
| `migrate_metadata!(db)` | Add the `metadata` table to a legacy database |
| `find_species(tdb, name; exact_match)` | Search species by name (case-insensitive exact with `exact_match=true`) |
| `list_species_page(tdb; page, page_size)` | Paginated species listing |
| `get_species_data(tdb, id)` | Full species + intervals + coeffs |
| `get_species_for_temperature(tdb, id, T)` | Interval valid for T |
| `get_temperature_bounds(tdb, id)` | Overall (T_min, T_max) of a species |
| `calculate_cp(coeffs, T)` | Cp/R (dimensionless), `coeffs::NASACoefficients` |
| `calculate_h(coeffs, T)` | H/RT (dimensionless), `coeffs::NASACoefficients` |
| `calculate_s(coeffs, T)` | S/R (dimensionless), `coeffs::NASACoefficients` |

### Constants

| Constant | Value | Description |
|---|---|---|
| `R_UNIVERSAL` | 8.31446261815324 | Universal gas constant, J/(mol·K) (CODATA 2018/2022) |
| `R_GLENN` | 8.314510 | Reference gas constant of the NASA Glenn/CEA dataset, J/(mol·K) (CODATA 1986) |

The NASA-7 coefficients are dimensionless (`Cp/R₀`, `H/R₀T`, `S/R₀`).
`Calculator` reads the dataset reference constant from the `metadata` table and
uses it to denormalise properties, ensuring consistency with the original
NASA CEA fit.

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
| `species` | 2035 | Chemical species (name, formula, phase, MW, ΔH°f) |
| `temperature_intervals` | 3795 | Valid T ranges per species |
| `coefficients` | 3795 | NASA-7 polynomial coefficients (a1–a7, b1, b2) |
| `file_metadata` | 1 | Global file metadata |
| `metadata` | 2 | Dataset metadata (reference gas constant) |

## Migrating from 0.4.x

Version 0.5.0 fixes the bundled dataset and completes the reference API. Three
things need attention:

- **`get_species_data` returns a typed `SpeciesData`.** Indexing (`data["name"]`)
  still works; `to_dict(data)` restores the old `Dict`.
- **`ThermoCalcError` is now an abstract base type.** `ThermoCalcError("msg")`
  still works and returns a `ThermoError`.
- **Species `id` values shifted for 14 species.** Persist names, not IDs, and
  resolve them with `get_available_species(..., exact_match=true)`.

See the [migration guide](https://profleao.github.io/Glenn.jl/migration/) for
before/after examples and a post-upgrade check script.

## Documentation

Full documentation is available at [profleao.github.io/Glenn.jl/](https://profleao.github.io/Glenn.jl/).

## License

MIT — see [LICENSE](LICENSE)

