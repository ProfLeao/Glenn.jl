# Glenn.jl — Cheat Sheet

Molar SI units: Cp and S in J/(mol·K); H in J/mol; molecular weight in kg/mol.

## Setup

```julia
using Pkg; Pkg.add("Glenn"); using Glenn

calc = Calculator()                    # bundled database, no configuration
close(calc)

Calculator() do calc                   # preferred: closes even on error
    # ...
end

calc = Calculator("my_thermo.db")      # custom database
tdb  = ThermoDB("my_thermo.db")        # low-level handle
```

## Find species

| Call | Result |
|---|---|
| `get_available_species(calc)` | all species |
| `get_available_species(calc, "CH4")` | substring search, exact hits first |
| `get_available_species(calc, "N2"; exact_match = true)` | case-insensitive exact |
| `get_available_species(calc, "gas"; exact_match = true)` | phase filter |
| `find_species(tdb, "N2")` | same, on a `ThermoDB` |
| `list_species_page(tdb; page = 2, page_size = 50)` | pagination |
| `get_species_info(tdb, id)` / `get_species_data(tdb, id)` | one row / full record |

```julia
sp = only(get_available_species(calc, "O2", exact_match = true))
sp.id                                 # needed by every property function
sp.name; sp.formula; sp.phase         # "O2", "O2", "gas" or "condensed"
sp.molecular_weight                   # kg/mol, may be nothing
sp.heat_of_formation_298K             # J/mol, may be nothing
sp.num_intervals                      # number of temperature intervals

d = get_species_data(tdb, sp.id)      # full record, incl. coefficients
d.intervals                           # Vector{IntervalData}
first(d.intervals).coefficients.a1    # NASACoefficients
```

`exact_match` folds case: `"CO"` matches both `CO` and cobalt `Co`. Check
`sp.name` instead of assuming one hit.

## Properties

```julia
p = calculate_properties(calc, sp.id, 1000.0)
p.cp; p.s                             # J/(mol K)
p.h_relative                          # J/mol (includes dHf)
p.temp_min; p.temp_max                # interval actually used

props = calculate_properties_range(calc, sp.id, 300.0:100.0:2000.0)
props = calculate_properties_range(calc, sp.id, T; strict = false)  # skip gaps
get_temperature_bounds(calc, sp.id)   # (t_min, t_max) or nothing

dcp_dt(calc, sp.id, 1000.0)           # dCp/dT, J/(mol K^2), analytic
Glenn.gamma(calc, sp.id, 300.0)       # Cp/Cv — NOT exported
```

## Enthalpy

```julia
calculate_enthalpy_change(calc, sp.id, 300.0, 1500.0)   # H(1500) - H(300)
h_sensible_to(calc, sp.id, 1500.0)                      # from 298.15 K
h_sensible_to(calc, sp.id, 1500.0, 300.0)               # from a custom Tref
calculate_formation_enthalpy(calc, sp.id)               # J/mol or nothing
```

`h_relative` already contains the enthalpy of formation, so this identity holds
and is a good self-check:

```julia
hf = calculate_formation_enthalpy(calc, sp.id)
hf + h_sensible_to(calc, sp.id, 1500.0) ~=
    calculate_properties(calc, sp.id, 1500.0).h_relative
```

## Mixtures

```julia
mix = Mixture(((o2.id, 0.21), (n2.id, 0.79)))   # (species_id, mole fraction)
validate(mix)                                   # throws CompositionError

mp = mixture_properties(calc, mix, 1000.0)
mp.cp_molar; mp.h_molar; mp.s_molar             # molar basis
mp.cp_mass;  mp.h_mass;  mp.s_mass              # per kilogram
mp.molar_mass                                   # kg/mol

mixture_properties(calc, mix, 4000.0; strict = false)   # drop out-of-range
```

Fractions must be non-negative, sum to 1 within `1e-9`, and every component
needs a molar mass.

## Errors

```julia
try
    calculate_properties(calc, sp.id, 9000.0)
catch e
    e isa ThermoCalcError             # abstract supertype of all of these
    e isa TemperatureOutOfRangeError  # .temperature .species_name .temp_bounds
    e isa SpeciesNotFoundError        # .species_id
    e isa CompositionError            # mixture problems
    e isa DatabaseNotConnectedError   # handle was closed
    e isa ThermoError                 # anything else
end
```

Both interval endpoints are inclusive; a shared boundary uses the lower
interval.

## Validate a database

```julia
report = validate_database(calc.db)     # read-only
report.valid                            # Bool
report.errors; report.warnings          # Vector{String}
report.counts; println(report)
```

## Build a database

```julia
build_database("thermo.inp", "thermo.db")
build_database("thermo.inp", "thermo.db"; merge_duplicates = true)

default_inp_path(); default_db_path()   # bundled files
```

```julia
b = Glenn.ThermoDBBuilder()             # low-level steps
Glenn.connect(b, "thermo.inp"); Glenn.create_tables(b)
Glenn.parse_and_load(b); Glenn.close(b)
```

## Fit NASA-7 coefficients

```julia
c = fit_nasa7(T, cp)                             # -> NASACoefficients
c = fit_nasa7(T, cp; t_ref = 298.15, h_ref = -74600.0, s_ref = 186.25)
c = fit_nasa7(T, cp; weights = w)
cs = fit_nasa7_multi(T, cp, [1000.0, 2500.0])    # -> Vector{NASACoefficients}

c.a1: c.a7; c.b1; c.b2
calculate_cp(c, 1200.0); calculate_h(c, 1200.0); calculate_s(c, 1200.0)
```

## Constants

```julia
R_UNIVERSAL                  # 8.31446261815324  (CODATA)
R_GLENN                      # 8.314510          (dataset reference)
Glenn.R                      # alias of R_UNIVERSAL — NOT exported
get_gas_constant_ref(tdb)    # value the database was fitted with
```

## Command line

```bash
julia --project -e 'using Glenn; Glenn.cli_main()' -- query -s CH4
julia bin/glenn.jl validate -d thermo.db
```

| Command | Purpose |
|---|---|
| `build` | `thermo.inp` -> SQLite |
| `query` | example lookups |
| `validate` | read-only integrity checks |
| `migrate-metadata` | add dataset metadata to a legacy database |
| `--version`, `-h` | version, usage |

| Option | Meaning |
|---|---|
| `-i, --input` | input FORTRAN `thermo.inp` |
| `-o, --output` | output SQLite file |
| `-d, --database` | database to read |
| `-s, --species` | name pattern for `query` |
| `-v, --verbose` | debug logging |

Exit code is `0` on success and `1` on any failure, including a typo in a command
or option.

## Gotchas

* **Species IDs change between dataset rebuilds.** Persist names, not `id`s.
* **`h_relative` includes the enthalpy of formation.** For an interval plot use
  `h_sensible_to`; for a difference use `calculate_enthalpy_change`.
* **Default lookup is a substring search** (up to 20 hits). Use
  `exact_match = true` to mean one species.
* **`Mixture` takes mole fractions**, not masses.
* **Missing data yields `nothing`**, not an error — guard before formatting.
* **`Glenn.gamma` and `Glenn.R` must be qualified**; they are not exported.
