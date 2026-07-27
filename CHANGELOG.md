# Changelog

All notable changes to Glenn.jl are documented in this file.

---

## [0.3.0] — 2026-07-26

### ⚠️ Breaking Changes

- **No breaking changes.** All additions in this release are backwards-compatible.
  The `exact_match` keyword parameter defaults to `false`, preserving existing
  behaviour for all callers.

### ✨ Added

- **`exact_match` parameter** in `find_species` and `get_available_species` for
  case-insensitive exact species lookup (`"N2"` returns only N₂, not Be₃N₂).
- **NIST-JANAF cross-validation audit** (`docs/audit/audit.jl`) — validates
  Cp, ΔH, and S° against NIST reference data (Chase 1998) for 7 species
  (CO₂, N₂, CO, H₂O, O₂, NH₃, SO₂) over 300–3000 K.
- **CLI convenience script** (`bin/glenn.jl`) — executable entry point with
  automatic project activation.
- **Pluto.jl interactive notebooks** for both examples:
  `01_basic_usage_pluto.jl` and `02_fuel_comparison_pluto.jl`.
- **Aqua.jl static analysis** in test suite — checks for method ambiguities,
  unbound type parameters, and type piracies.
- **JuliaFormatter** code style configuration (`.JuliaFormatter.toml`).
- **`dev/` folder** (git-ignored) for local-only development notes.

### 🔧 Changed

- All documentation and examples updated to use `exact_match=true`.
- CLI docs updated to reference `bin/glenn.jl` convenience script.
- All source files formatted with JuliaFormatter (indent=4, margin=92).

### 🐛 Fixed

- Removed orphaned `JuliaFormatter` compat entry from `Project.toml`.

---

## [0.2.1] — 2026-07-25

- Fix CI and Documentation workflows.
- Switch sidebar logo to `logo_glennjl.png` with transparent background.

## [0.2.0] — 2026-07-25

- Initial release with typed structs (`ThermoProperties`, `SpeciesInfo`,
  `NASACoefficients`, `IntervalData`).
- `Calculator()` with context manager (do-block) support.
- SQLite database with ~2030 species, 3772 temperature intervals.
- NASA-7 polynomial calculations (Cp/R, H/RT, S/R).
- Builder for converting FORTRAN `thermo.inp` → SQLite3.
- Command-line interface (`build` and `query`).
- Full Documenter.jl documentation.
