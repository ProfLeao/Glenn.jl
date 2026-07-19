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
connect(builder)
create_tables(builder)
parse_and_load(builder)
close(builder)

# Or use a custom thermo.inp
builder = ThermoDBBuilder("my_thermo.inp", "my_thermo.db")
connect(builder)
create_tables(builder)
parse_and_load(builder)
close(builder)
```

## API Reference

```@docs
ThermoDBBuilder
connect(::ThermoDBBuilder)
create_tables
parse_and_load
```

## Parser Utilities

```@docs
parse_float
parse_species_record
parse_general_info_record
parse_temp_interval_record
parse_coefficients_record
is_temperature_line
is_coefficient_line
read_thermo_file
```
