# Glenn.jl usage examples

This folder contains scripts and **Pluto.jl notebooks** demonstrating how to use the **Glenn.jl** library for thermochemical property calculations ($C_p(T)$, $H^\circ(T)$, $S^\circ(T)$) from NASA polynomial coefficients.

The scripts are mirrored as tutorial pages rendered in the [Documenter.jl documentation](https://profl.github.io/Glenn.jl/dev/).

## How to run

From the repository root:

```bash
# 1. Activate the project environment
julia --project -e 'import Pkg; Pkg.instantiate()'

# 2. Run examples directly
julia --project examples/01_basic_usage.jl
julia --project examples/02_fuel_comparison.jl

# 3. Or open the Pluto notebooks (interactive)
julia --project -e 'using Pluto; Pluto.run(notebook="examples/01_basic_usage.jl")'
julia --project -e 'using Pluto; Pluto.run(notebook="examples/02_fuel_comparison.jl")'
```

> **Note:** `02_fuel_comparison.jl` requires `Plots.jl`. Pluto notebooks require `Pluto.jl`.

## Examples

### Core examples

| File | Type | Description |
|------|------|-------------|
| [`01_basic_usage.jl`](01_basic_usage.jl) | Script | First steps: look up species and compute $C_p$, $H^\circ$, $S^\circ$. |
| [`02_fuel_comparison.jl`](02_fuel_comparison.jl) | Script | Compares CH₄, ethanol, and propane with plots of $C_p$ and sensible enthalpy (requires `Plots.jl`). |

### Pluto Notebooks

These `.jl` files double as **Pluto.jl** reactive notebooks — just open them
with Pluto for an interactive experience:

| File | Description |
|------|-------------|
| `01_basic_usage.jl` | Interactive version of the basic usage tutorial |
| `02_fuel_comparison.jl` | Interactive fuel comparison with live plots |

### Additional examples

Extra notebooks live in [`extra/`](extra/) — drop new `.jl` files there
and they will appear in the documentation on the next build.

### Additional examples

Extra scripts live in [`extra/`](extra/) — drop new `.jl` files there.
