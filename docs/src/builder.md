```@meta
CurrentModule = Glenn
```

# Builder API

Converts NASA FORTRAN `thermo.inp` files → SQLite3 database.

## FORTRAN Record Structure (Appendix C)

| Record | Content |
|--------|---------|
| RECORD 1 | Species identification (name, comments) |
| RECORD 2 | General information (num_intervals, ref_code, phase, MW, ΔH°f) |
| RECORD 3 | Temperature interval definition (T_min, T_max, H_298→0) |
| RECORD 4 | First 5 polynomial coefficients (a₁–a₅) |
| RECORD 5 | Last 2 coefficients + integration constants (a₆, a₇, b₁, b₂) |

Records 3–5 repeat for each temperature interval.

## Quick Start

```julia
using Glenn

# Build from the bundled thermo.inp (shipped with the package)
builder = ThermoDBBuilder(default_inp_path(), "thermo.db")
ThermoBuilder.connect(builder)
ThermoBuilder.create_tables(builder)
ThermoBuilder.parse_and_load(builder)
ThermoBuilder.close(builder)

# Or use a custom thermo.inp
builder = ThermoDBBuilder("my_thermo.inp", "my_thermo.db")
ThermoBuilder.connect(builder)
ThermoBuilder.create_tables(builder)
ThermoBuilder.parse_and_load(builder)
ThermoBuilder.close(builder)
```

## API Reference

```@docs
ThermoDBBuilder
ThermoBuilder.connect
ThermoBuilder.create_tables
ThermoBuilder.parse_and_load
```

## Parser Utilities

```@docs
ThermoBuilder.parse_float
ThermoBuilder.parse_species_record
ThermoBuilder.parse_general_info_record
ThermoBuilder.parse_temp_interval_record
ThermoBuilder.parse_coefficients_record
ThermoBuilder.is_temperature_line
ThermoBuilder.is_coefficient_line
ThermoBuilder.read_thermo_file
```
