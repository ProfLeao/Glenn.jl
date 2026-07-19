# Glenn.jl usage examples

This folder contains scripts demonstrating how to use the **Glenn.jl** library for thermochemical property calculations ($C_p(T)$, $H^\circ(T)$, $S^\circ(T)$) from NASA polynomial coefficients.

The scripts are mirrored as tutorial pages rendered in the [Documenter.jl documentation](https://profl.github.io/Glenn.jl/dev/).

## How to run

From the repository root:

```bash
# 1. Activate the project environment
julia --project -e 'import Pkg; Pkg.instantiate()'

# 2. Run examples directly
julia --project examples/01_basic_usage.jl
julia --project examples/02_fuel_comparison.jl
```

> **Note:** `02_fuel_comparison.jl` requires `Plots.jl` and `StatsPlots.jl`.

## Scripts

### Core examples

| Script | Description |
|--------|-------------|
| [`01_basic_usage.jl`](01_basic_usage.jl) | First steps: look up species and compute $C_p$, $H^\circ$, $S^\circ$. |
| [`02_fuel_comparison.jl`](02_fuel_comparison.jl) | Compares CH₄, ethanol, and propane with plots of $C_p$ and sensible enthalpy (requires `Plots.jl`). |

### Additional examples

Extra scripts live in [`extra/`](extra/) — drop new `.jl` files there.
