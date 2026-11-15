```@meta
CurrentModule = Glenn
```

# Command-Line Interface

Glenn.jl provides a command-line interface for building, querying and validating
thermochemical databases.

## Usage

```bash
# Via julia -e (no extra scripts needed)
julia --project -e 'using Glenn; Glenn.cli_main()' -- build
julia --project -e 'using Glenn; Glenn.cli_main()' -- query -s O2

# Or use the convenience script, which propagates the exit status
julia --project bin/glenn.jl build -i my_thermo.inp -o my_thermo.db
julia --project bin/glenn.jl query -s CO2
```

`cli_main` returns `0` on success and `1` on failure, so it can be used in
scripts and CI pipelines:

```bash
julia --project bin/glenn.jl validate -d thermo.db || echo "database is broken"
```

Unknown commands and options are reported on stderr and exit with status `1`.

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

### `validate` — Read-only integrity checks

Runs [`Glenn.validate_database`](@ref) and prints the row counts, warnings and
errors. Exits with `1` when the database is inconsistent.

| Option | Description | Default |
|--------|-------------|---------|
| `-d, --database` | SQLite database file | Bundled `thermo.db` |
| `-v, --verbose` | Enable verbose logging | `false` |

```bash
julia --project bin/glenn.jl validate -d thermo.db
```

### `migrate-metadata` — Add dataset metadata to a legacy database

Adds the `metadata` table and the dataset reference gas constant
(`R_GLENN`) without touching the thermochemical rows.

| Option | Description | Default |
|--------|-------------|---------|
| `-d, --database` | SQLite database file | Bundled `thermo.db` |

```bash
julia --project bin/glenn.jl migrate-metadata -d legacy.db
```

### `--version` / `-h, --help`

Print the package version, or the full usage message.

## API Reference

```@docs
cli_main
```
