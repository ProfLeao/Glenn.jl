```@meta
CurrentModule = Glenn
```

# Command-Line Interface

Glenn.jl provides a command-line interface for building databases and querying species properties.

## Usage

```bash
# Via julia -e (no extra scripts needed)
julia --project -e 'using Glenn; Glenn.cli_main()' -- build
julia --project -e 'using Glenn; Glenn.cli_main()' -- query -s O2

# Or use the convenience script
julia --project bin/glenn.jl build -i my_thermo.inp -o my_thermo.db
julia --project bin/glenn.jl query -s CO2
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
