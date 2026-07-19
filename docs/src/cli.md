```@meta
CurrentModule = Glenn
```

# Command-Line Interface

Glenn.jl provides a command-line interface for building databases and querying species properties.

## Usage

```bash
# Build database from bundled thermo.inp
julia --project -e 'using Glenn; Glenn.cli_main()' -- build

# Build from custom input
julia --project -e 'using Glenn; Glenn.cli_main()' -- build -i my_thermo.inp -o my_thermo.db

# Query species properties (uses bundled thermo.db)
julia --project -e 'using Glenn; Glenn.cli_main()' -- query -s O2

# Query with custom database
julia --project -e 'using Glenn; Glenn.cli_main()' -- query -d my_thermo.db -s CO2
```

## Commands

### `build` — Convert thermo.inp → SQLite3

| Option | Description | Default |
|--------|-------------|---------|
| `-i, --input` | Input FORTRAN file | Bundled `thermo.inp` |
| `-o, --output` | Output SQLite database | `thermo.db` |
| `-v, --verbose` | Enable verbose logging | `false` |

### `query` — Run example queries

| Option | Description | Default |
|--------|-------------|---------|
| `-d, --database` | SQLite database file | Bundled `thermo.db` |
| `-s, --species` | Species name pattern | `O2` |
| `-v, --verbose` | Enable verbose logging | `false` |

## API Reference

```@docs
cli_main
```
