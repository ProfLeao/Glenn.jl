```@meta
CurrentModule = Glenn
```

# Fitting NASA-7 coefficients

Glenn.jl can also go the other way: given tabulated heat-capacity data, it
produces NASA-7 coefficient sets that can be stored in a database and evaluated
with `calculate_cp`, `calculate_h` and `calculate_s`.

Two entry points are available:

| Function | Use |
|---|---|
| [`Glenn.fit_nasa7`](@ref) | one temperature interval |
| [`Glenn.fit_nasa7_multi`](@ref) | several intervals, with continuity at the breakpoints |

## Quick start

```julia
using Glenn

# Heat capacity of O2 over 200-1000 K, in J/(mol·K)
temperatures = collect(200.0:20.0:1000.0)
cp_values = 29.0 .+ 0.004 .* temperatures      # stand-in for measured data

coeffs = fit_nasa7(temperatures, cp_values; t_ref = 298.15, h_ref = 0.0)

cp_1000 = calculate_cp(coeffs, 1000.0) * R_GLENN
```

## The enthalpy convention

The integration constant for enthalpy is **`b1`**, not `a6`: `a6` and `a7`
multiply `T³` and `T⁴` in the `Cp` polynomial. `fit_nasa7` derives `b1` so that

```math
H^\circ(t_{ref}) = h_{ref}
```

holds exactly, which is the same convention used by the bundled dataset. The
entropy constant `b2` is derived from `s_ref` when it is given, and is `0.0`
otherwise.

```julia
coeffs = fit_nasa7(temperatures, cp_values; t_ref = 298.15, h_ref = -74_800.0)

calculate_h(coeffs, 298.15) * 298.15 * R_GLENN   # ≈ -74_800.0 J/mol
```

## Multiple intervals

NASA datasets split each species into several temperature intervals because a
single degree-7 polynomial is a poor fit over a very wide range. `fit_nasa7_multi`
fits one set per interval while requiring that `Cp/R` **and its first
temperature derivative** are continuous at every internal breakpoint. `H°` and
`S°` are propagated so that they are continuous too.

```julia
coeffs = fit_nasa7_multi(
    temperatures,
    cp_values,
    [1000.0];              # internal breakpoints
    t_ref = 298.15,
    h_ref = 0.0,
    s_ref = 205.0,
)

length(coeffs)   # 2 — one coefficient set per interval
```

A point with `T <= breakpoint` belongs to the lower interval, matching the
convention used by `get_species_for_temperature`.

## Conditioning

Both functions fit in the scaled variable `u = T / T_scale`, where `T_scale` is
the geometric mean temperature, so the design matrix stays well conditioned.
Very wide ranges are still inherently ill-conditioned — that is exactly why NASA
splits them into intervals.

`fit_nasa7` requires at least seven data points; `fit_nasa7_multi` requires at
least seven points **per interval**. Invalid inputs raise `ArgumentError`.

## Writing the result to a database

The fitted coefficients follow the same convention as the bundled database, so
they can be stored in a `coefficients` row and evaluated later with
`calculate_cp`, `calculate_h` and `calculate_s` without any conversion.

There is no helper that inserts fitted coefficients yet: create the schema with
`Glenn.connect` / `Glenn.create_tables` and insert the `species`,
`temperature_intervals` and `coefficients` rows yourself, then run
[`Glenn.validate_database`](@ref) to confirm the result is consistent.

## API reference

```@docs
Glenn.fit_nasa7
Glenn.fit_nasa7_multi
```
