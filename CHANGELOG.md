# Changelog

All notable changes to Glenn.jl are documented in this file.

---

## [0.4.1] — 2026-08-22

### ✨ Added

- **Wrapper methods:** Added `get_gas_constant_ref(tdb::ThermoDB)` and `migrate_metadata!(tdb::ThermoDB)` to allow passing the high-level `ThermoDB` struct directly, ensuring API consistency.

### 🐛 Fixed

- Fixed a `MethodError` in the `Calculator` context manager docstring by replacing dictionary access with struct property access (`species[1].id`).
- Corrected misleading "legacy" comments in `01_basic_usage.jl` and `basic_usage.md` regarding substring searches.
- Documented a previously missing breaking change note for v0.2.0 (introduction of `ThermoCalcError`).

---

## [0.4.0] — 2026-08-21

### 🐛 Fixed

- **Incorrect reference gas constant in property denormalisation.**
  The bundled NASA Glenn/CEA polynomials (`thermo.inp` dated 9/09/04) are
  dimensionless (`Cp/R₀`, `H/R₀T`, `S/R₀`) and were fitted with the CODATA 1986
  gas constant **R₀ = 8.314510 J/(mol·K)** (NASA TP-2002-211556). The runtime
  previously denormalised them with `R_UNIVERSAL = 8.314462618` (CODATA 2018),
  producing a systematic **−5.7 ppm** bias relative to the original NASA CEA
  values. Results are now denormalised with the dataset reference constant.

### ✨ Added

- **`R_GLENN = 8.314510`** — reference gas constant of the bundled NASA Glenn/CEA
  dataset (CODATA 1986).
- **`get_gas_constant_ref(db)`** — reads the dataset reference constant from the
  SQLite `metadata` table, with explicit fallback to `R_UNIVERSAL` for legacy
  databases.
- **`migrate_metadata!(db)`** — adds the `metadata` table and `gas_constant_ref`
  to an existing database (self-contained migration).
- **`metadata` table** in the builder schema, storing `gas_constant_ref` and
  `gas_constant_ref_source`.
- **`DatabaseStats`** — typed struct replacing the `Dict` returned by
  `get_statistics` (total species/intervals/coefficients, species by phase,
  average molecular weight).

### 🔧 Changed

- **`R_UNIVERSAL`** now uses full CODATA 2018/2022 precision
  (`8.31446261815324` instead of the truncated `8.314462618`).
- **`Calculator`** now stores a `R_ref` field read from the dataset, and uses it
  (instead of `R_UNIVERSAL`) for all Cp/H/S denormalisation — scalar and
  vectorised paths.
- **`ThermoDBBuilder`** writes dataset metadata automatically during `build`.
- **`parse_and_load`** now reports `New species loaded` and `Already existing`
  separately, instead of a single misleading `Total species loaded: 0` when
  rebuilding into an already-populated database.
- **`calculate_cp`/`calculate_h`/`calculate_s`** now deprecate the `Dict`
  coefficient methods (`Base.@deprecate`) in favour of `NASACoefficients`.

### 📝 Documentation

- Documented `R_GLENN`, `get_gas_constant_ref`, `write_metadata`, and
  `migrate_metadata!` in the API reference (Calculator, Database, and Builder
  pages).
- Added the `metadata` table to the database contents in `docs` and `README.md`.
- Added a Constants section to `README.md` describing `R_UNIVERSAL` and
  `R_GLENN`.

### ⚠️ Breaking Changes

- **`get_statistics` now returns a `DatabaseStats` struct** (instead of a `Dict`).
  Callers using `stats["total_species"]` must switch to `stats.total_species`.
- `R_UNIVERSAL` remains exported; databases without the `metadata` table fall
  back gracefully with a warning. Numerical results of regenerated databases
  rise by ~5.7 ppm — this is a precision correction, not a change of contract.

### 🙏 Acknowledgements

- Thanks to [@longemen3000](https://github.com/longemen3000) for identifying the
  reference gas constant inconsistency.

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
