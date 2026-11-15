"""
    fitting.jl — Least-squares fitting of NASA-7 polynomials to Cp(T) data.

Provides `fit_nasa7` (single temperature interval) and `fit_nasa7_multi`
(several intervals with continuity of Cp and its first derivative at every
internal breakpoint).

Both derive the integration constants so that the NASA-7 enthalpy convention
`H°(t_ref) = h_ref` holds exactly. Note that `b1` — not `a6` — is the enthalpy
integration constant: `a6` and `a7` multiply `T³` and `T⁴` in the Cp polynomial.

The fitted coefficients use the same convention as the bundled database, so they
can be evaluated directly with `calculate_cp`, `calculate_h` and `calculate_s`.
"""
module ThermoFitting

using LinearAlgebra

using ..ThermoDatabase: R_GLENN, NASACoefficients

# Minimum number of data points required to determine the seven a-coefficients.
const _MIN_POINTS = 7

# ------------------------------------------------------------------
# NASA-7 helpers
# ------------------------------------------------------------------

# Polynomial part of H/RT (without `b1/T`).
function _h_poly(a::NTuple{7, Float64}, T::Float64)
    return -a[1] / T^2 +
           a[2] * log(T) / T +
           a[3] +
           a[4] * T / 2 +
           a[5] * T^2 / 3 +
           a[6] * T^3 / 4 +
           a[7] * T^4 / 5
end

# Polynomial part of S/R (without `b2`).
function _s_poly(a::NTuple{7, Float64}, T::Float64)
    return -a[1] / (2 * T^2) -
           a[2] / T +
           a[3] * log(T) +
           a[4] * T +
           a[5] * T^2 / 2 +
           a[6] * T^3 / 3 +
           a[7] * T^4 / 4
end

# Scaled Cp basis [u⁻², u⁻¹, 1, u, u², u³, u⁴] for a vector of scaled
# temperatures, as a matrix (rows = data points).
function _basis_matrix(u::AbstractVector{Float64})
    n = length(u)
    X = Matrix{Float64}(undef, n, 7)
    @inbounds for (i, ui) in enumerate(u)
        X[i, 1] = ui^-2
        X[i, 2] = ui^-1
        X[i, 3] = 1.0
        X[i, 4] = ui
        X[i, 5] = ui^2
        X[i, 6] = ui^3
        X[i, 7] = ui^4
    end
    return X
end

# The scaled Cp basis evaluated at a scalar `u`.
function _basis_vector(u::Float64)
    return [u^-2, u^-1, 1.0, u, u^2, u^3, u^4]
end

# d/du of the scaled Cp basis at a scalar `u`.
function _deriv_vector(u::Float64)
    return [-2.0 * u^-3, -u^-2, 0.0, 1.0, 2.0 * u, 3.0 * u^2, 4.0 * u^3]
end

# ------------------------------------------------------------------
# Input validation
# ------------------------------------------------------------------

function _check_scalar(name::String, value::Float64; positive::Bool = false)
    isfinite(value) || throw(ArgumentError("$name must be finite"))
    if positive && value <= 0.0
        throw(ArgumentError("$name must be strictly positive"))
    end
    return value
end

function _check_weights(weights, n::Int)
    weights === nothing && return ones(Float64, n)
    w = Float64.(weights)
    length(w) == n || throw(
        ArgumentError(
            "weights must match temperatures (got $(length(w)) and $n)",
        ),
    )
    all(isfinite, w) || throw(ArgumentError("weights must be finite"))
    all(>=(0.0), w) || throw(ArgumentError("weights must be non-negative"))
    any(>(0.0), w) || throw(ArgumentError("at least one weight must be positive"))
    return w
end

# ------------------------------------------------------------------
# Single-interval fit
# ------------------------------------------------------------------

"""
    fit_nasa7(temperatures, cp_values; t_ref=298.15, h_ref=0.0,
              s_ref=nothing, weights=nothing, r_ref=R_GLENN) -> NASACoefficients

Fit the seven NASA-7 heat-capacity coefficients to tabulated `Cp(T)` data by
(weighted) least squares in the dimensionless form

```math
\\frac{C_p}{R} = \\frac{a_1}{T^2} + \\frac{a_2}{T} + a_3 + a_4 T + a_5 T^2
+ a_6 T^3 + a_7 T^4
```

The enthalpy integration constant `b1` is **not** fitted: it is derived so that
the NASA-7 convention `H°(t_ref) == h_ref` holds exactly. The entropy constant
`b2` is derived from `s_ref` when given, and set to `0.0` otherwise.

# Arguments

  - `temperatures`: temperatures in kelvin (strictly positive, at least 7 points)
  - `cp_values`: heat capacity at each temperature, in J/(mol·K)
  - `t_ref`: reference temperature for the enthalpy anchor (default 298.15 K)
  - `h_ref`: enthalpy `H°` at `t_ref`, in J/mol (default `0.0`)
  - `s_ref`: optional entropy `S°` at `t_ref`, in J/(mol·K)
  - `weights`: optional per-point weights, same length as `temperatures`
  - `r_ref`: reference gas constant used to denormalise `Cp` and `h_ref`
    (defaults to `R_GLENN`, the value used by the bundled dataset)

# Notes

The fit is performed in the scaled variable `u = T / T_scale`, with `T_scale`
the geometric mean temperature, to keep the design matrix well conditioned.
Very wide temperature ranges remain inherently ill-conditioned; the NASA
datasets split each species into several intervals for that reason, so prefer
one interval per fit or use [`fit_nasa7_multi`](@ref).

# Throws

`ArgumentError` for inconsistent, too short, non-finite or non-positive inputs.
"""
function fit_nasa7(
    temperatures,
    cp_values;
    t_ref::Real = 298.15,
    h_ref::Real = 0.0,
    s_ref::Union{Real, Nothing} = nothing,
    weights = nothing,
    r_ref::Real = R_GLENN,
)
    T = Float64.(temperatures)
    cp = Float64.(cp_values)

    length(T) == length(cp) || throw(
        ArgumentError(
            "temperatures and cp_values must have the same length " *
            "(got $(length(T)) and $(length(cp)))",
        ),
    )
    length(T) >= _MIN_POINTS || throw(
        ArgumentError(
            "at least $_MIN_POINTS data points are required to fit seven " *
            "coefficients (got $(length(T)))",
        ),
    )
    all(isfinite, T) || throw(ArgumentError("temperatures must be finite"))
    all(>(0.0), T) || throw(ArgumentError("temperatures must be strictly positive"))
    all(isfinite, cp) || throw(ArgumentError("cp_values must be finite"))

    t_ref = _check_scalar("t_ref", Float64(t_ref); positive = true)
    h_ref = _check_scalar("h_ref", Float64(h_ref))
    r_ref = _check_scalar("r_ref", Float64(r_ref); positive = true)
    s_ref_value = s_ref === nothing ? nothing : _check_scalar("s_ref", Float64(s_ref))

    w = _check_weights(weights, length(T))

    # Denormalise Cp with the chosen reference gas constant.
    y = cp ./ r_ref

    # Fit in the scaled variable u = T / T_scale (u is O(1)).
    T_scale = exp(sum(log, T) / length(T))
    u = T ./ T_scale

    sqrt_w = sqrt.(w)
    X = _basis_matrix(u)
    X = X .* sqrt_w
    y = y .* sqrt_w

    rank_x = rank(X)
    rank_x >= _MIN_POINTS || throw(
        ArgumentError(
            "design matrix is rank-deficient (rank $rank_x < $_MIN_POINTS); " *
            "provide at least $_MIN_POINTS distinct temperatures",
        ),
    )
    c = X \ y

    # Map the scaled coefficients back to the standard NASA-7 basis.
    a = (
        c[1] * T_scale^2,
        c[2] * T_scale,
        c[3],
        c[4] / T_scale,
        c[5] / T_scale^2,
        c[6] / T_scale^3,
        c[7] / T_scale^4,
    )

    # Enthalpy integration constant: enforce H°(t_ref) == h_ref exactly.
    b1 = h_ref / r_ref - t_ref * _h_poly(a, t_ref)

    # Entropy integration constant: optional anchor, otherwise 0.0.
    b2 = if s_ref_value === nothing
        0.0
    else
        s_ref_value / r_ref - _s_poly(a, t_ref)
    end

    return NASACoefficients(a[1], a[2], a[3], a[4], a[5], a[6], a[7], b1, b2)
end

# ------------------------------------------------------------------
# Multi-interval fit
# ------------------------------------------------------------------

"""
    fit_nasa7_multi(temperatures, cp_values, breakpoints; t_ref=298.15,
                    h_ref=0.0, s_ref=nothing, weights=nothing,
                    r_ref=R_GLENN) -> Vector{NASACoefficients}

Fit NASA-7 coefficients across several temperature intervals.

One set of seven heat-capacity coefficients is fitted per interval, requiring
that both `Cp/R` and its first temperature derivative are continuous at every
internal breakpoint (a linear equality constraint in the least-squares problem).

The enthalpy constant `b1` is anchored in the interval containing `t_ref` and
propagated so that `H°` is continuous across breakpoints. `b2` is anchored from
`s_ref` when given and propagated so that `S°` is continuous, otherwise it is
`0.0` everywhere.

A point with `T <= breakpoint` belongs to the lower interval, matching the
interval-selection convention used by `get_species_for_temperature`.

Returns one `NASACoefficients` per interval, in increasing temperature order.

# Throws

`ArgumentError` for inconsistent inputs, invalid breakpoints, or an interval with
fewer than 7 data points.
"""
function fit_nasa7_multi(
    temperatures,
    cp_values,
    breakpoints;
    t_ref::Real = 298.15,
    h_ref::Real = 0.0,
    s_ref::Union{Real, Nothing} = nothing,
    weights = nothing,
    r_ref::Real = R_GLENN,
)
    T = Float64.(temperatures)
    cp = Float64.(cp_values)

    length(T) == length(cp) || throw(
        ArgumentError(
            "temperatures and cp_values must have the same length " *
            "(got $(length(T)) and $(length(cp)))",
        ),
    )
    all(isfinite, T) || throw(ArgumentError("temperatures must be finite"))
    all(>(0.0), T) || throw(ArgumentError("temperatures must be strictly positive"))
    all(isfinite, cp) || throw(ArgumentError("cp_values must be finite"))

    t_ref = _check_scalar("t_ref", Float64(t_ref); positive = true)
    h_ref = _check_scalar("h_ref", Float64(h_ref))
    r_ref = _check_scalar("r_ref", Float64(r_ref); positive = true)
    s_ref_value = s_ref === nothing ? nothing : _check_scalar("s_ref", Float64(s_ref))

    bps = Float64.(breakpoints)
    isempty(bps) &&
        throw(ArgumentError("breakpoints must be a non-empty sequence"))
    all(isfinite, bps) || throw(ArgumentError("breakpoints must be finite"))
    all(>(0.0), bps) ||
        throw(ArgumentError("breakpoints must be strictly positive"))
    all(diff(bps) .> 0.0) ||
        throw(ArgumentError("breakpoints must be strictly increasing"))
    (bp_min, bp_max) = (minimum(bps), maximum(bps))
    (bp_min > minimum(T) && bp_max < maximum(T)) || throw(
        ArgumentError("breakpoints must lie strictly inside the temperature range"),
    )

    w = _check_weights(weights, length(T))

    n_intervals = length(bps) + 1

    # Interval index per point; a point at a breakpoint belongs to the lower one.
    idx = [searchsortedfirst(bps, t) for t in T]
    counts = zeros(Int, n_intervals)
    for k in idx
        counts[k] += 1
    end
    all(>=(_MIN_POINTS), counts) || throw(
        ArgumentError(
            "every interval needs at least $_MIN_POINTS points " *
            "(got $(counts))",
        ),
    )

    y = cp ./ r_ref
    sqrt_w = sqrt.(w)

    # Per-interval scaled design matrix, stacked block-diagonally.
    n_unknowns = 7 * n_intervals
    X = zeros(Float64, length(T), n_unknowns)
    scales = zeros(Float64, n_intervals)

    for k = 1:n_intervals
        mask = findall(==(k), idx)
        Tk = T[mask]
        scales[k] = exp(sum(log, Tk) / length(Tk))
        X[mask, (7 * (k - 1) + 1):(7 * k)] = _basis_matrix(Tk ./ scales[k])
    end

    X = X .* sqrt_w
    y = y .* sqrt_w

    # Continuity constraints C c = 0: value and first derivative of Cp/R at each
    # breakpoint (two rows per breakpoint).
    n_bp = length(bps)
    C = zeros(Float64, 2 * n_bp, n_unknowns)
    for r = 1:n_bp
        Tb = bps[r]
        left = (7 * (r - 1) + 1):(7 * r)
        right = (7 * r + 1):(7 * (r + 1))
        u_left = Tb / scales[r]
        u_right = Tb / scales[r + 1]

        C[2 * r - 1, left] = _basis_vector(u_left)
        C[2 * r - 1, right] = -_basis_vector(u_right)
        C[2 * r, left] = _deriv_vector(u_left) ./ scales[r]
        C[2 * r, right] = -_deriv_vector(u_right) ./ scales[r + 1]
    end

    # Solve min ||X c - y|| subject to C c = 0 with a null-space projection:
    # the feasible set is c = N z, where the columns of N span null(C).
    # `full = true` is required: Julia returns the thin Vt by default, and the
    # null space lives in the rows of Vt beyond the rank of C.
    F = svd(C; full = true)
    tol_c = maximum(F.S) * max(size(C)...) * eps(Float64)
    rank_c = count(>(tol_c), F.S)
    null_dim = n_unknowns - rank_c
    null_dim > 0 ||
        throw(ArgumentError("continuity constraints have no feasible solution"))

    N = F.Vt[(rank_c + 1):end, :]'   # n_unknowns × null_dim

    XN = X * N
    rank_z = rank(XN)
    rank_z >= null_dim || throw(
        ArgumentError(
            "insufficient independent data to fit all intervals " *
            "(rank deficiency in the reduced system)",
        ),
    )
    z = XN \ y
    c = N * z   # scaled coefficients, length 7 * n_intervals

    # Map scaled coefficients back to the standard NASA-7 basis per interval.
    a_coeffs = Vector{NTuple{7, Float64}}(undef, n_intervals)
    for k = 1:n_intervals
        ck = c[(7 * (k - 1) + 1):(7 * k)]
        S = scales[k]
        a_coeffs[k] = (
            ck[1] * S^2,
            ck[2] * S,
            ck[3],
            ck[4] / S,
            ck[5] / S^2,
            ck[6] / S^3,
            ck[7] / S^4,
        )
    end

    # Integration constants: anchor at the interval containing t_ref, then
    # propagate so H° (and S°, when s_ref is given) stay continuous.
    anchor = clamp(searchsortedfirst(bps, t_ref), 1, n_intervals)
    b1 = zeros(Float64, n_intervals)
    b2 = zeros(Float64, n_intervals)

    b1[anchor] = h_ref / r_ref - t_ref * _h_poly(a_coeffs[anchor], t_ref)
    if s_ref_value !== nothing
        b2[anchor] = s_ref_value / r_ref - _s_poly(a_coeffs[anchor], t_ref)
    end

    for k = anchor:(n_intervals - 1)
        Tb = bps[k]
        b1[k + 1] =
            b1[k] + Tb * (_h_poly(a_coeffs[k], Tb) - _h_poly(a_coeffs[k + 1], Tb))
        if s_ref_value !== nothing
            b2[k + 1] =
                b2[k] + (_s_poly(a_coeffs[k], Tb) - _s_poly(a_coeffs[k + 1], Tb))
        end
    end

    for k = (anchor - 1):-1:1
        Tb = bps[k]
        b1[k] =
            b1[k + 1] + Tb * (_h_poly(a_coeffs[k + 1], Tb) - _h_poly(a_coeffs[k], Tb))
        if s_ref_value !== nothing
            b2[k] =
                b2[k + 1] + (_s_poly(a_coeffs[k + 1], Tb) - _s_poly(a_coeffs[k], Tb))
        end
    end

    return [
        NASACoefficients(
            a[1],
            a[2],
            a[3],
            a[4],
            a[5],
            a[6],
            a[7],
            b1[k],
            b2[k],
        ) for (k, a) in enumerate(a_coeffs)
    ]
end

end # module ThermoFitting
