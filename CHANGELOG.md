# Changelog

All notable changes to Glenn.jl are documented in this file.

---

## [Unreleased] — 0.5.0

### 🐛 Fixed

- **Dataset reconciliation.** The bundled `thermo.db` was rebuilt with a
  state-machine parser. The previous parser desynchronised on malformed blocks,
  which stored three FORTRAN coefficient lines as "species"
  (`-1.302004763D+06`, `-7.310769440D+05`, `4.461077310D+04`) and silently
  dropped eight genuine species. The dataset now holds **2035 species /
  3795 intervals** (previously 2030 / 3772), and every previously present
  species keeps identical coefficients.
- **Repeated species records are merged.** `thermo.inp` encodes phase
  transitions by repeating a species name (`Cr(cr)`, `Cr2O3(I)`, `Fe(a)`,
  `Ni(cr)`, …). Previously only the first record was kept — and intervals from
  the later ones were stored under colliding numbers, so `Cr(cr)` reported a
  bogus `[200, 311.5] K` + `[1000, 2130] K` pair and 500 K raised
  `TemperatureOutOfRangeError`. The extra records are now appended as additional
  intervals (16 recovered across 10 substances), giving each substance its
  complete contiguous range.
- **`parse_and_load` no longer creates partial species.** Every declared
  interval is validated before the species row is inserted, and malformed blocks
  are skipped by resynchronising at the next verified species header.
- **Builder examples in the README and manual** called `connect` /
  `create_tables` / `parse_and_load` without qualification; those functions are
  not exported. The examples now use `build_database`, and the low-level steps
  are shown as `Glenn.connect` etc.

### ✨ Added

- **`fit_nasa7(temperatures, cp_values; t_ref, h_ref, s_ref, weights, r_ref)`**
  — weighted least-squares fit of the seven NASA-7 heat-capacity coefficients to
  tabulated `Cp(T)` data. The enthalpy constant `b1` is derived so that
  `H°(t_ref) == h_ref` holds exactly (`b1`, not `a6`, is the integration
  constant); `b2` comes from `s_ref` when given. Round-trips exact polynomial
  data to ~1e-12 relative error.
- **`fit_nasa7_multi(temperatures, cp_values, breakpoints; ...)`** — one
  coefficient set per interval, with `Cp/R` and its first derivative constrained
  to be continuous at every breakpoint, and `H°`/`S°` propagated so they are
  continuous too. Returns one `NASACoefficients` per interval.
- **`validate_database(tdb)`** — read-only integrity and semantic checks
  returning a `ValidationReport` (`valid`, `errors`, `warnings`, `counts`):
  required tables, referential integrity, exactly one coefficient set per
  interval, `num_intervals` agreement, ordered bounds, complete coefficient
  sets, and the parser guard that rejects species names looking like FORTRAN
  tokens. Missing dataset metadata is reported as a warning. The rebuild script
  now uses it, so users and the release gate run identical checks.
- **`calculate_properties_range(calc, id, temps; strict=false)`** — canonical
  bulk-properties function, mirroring the reference implementation. Loads the
  species intervals once, preserves input order, and skips out-of-range
  temperatures unless `strict=true`, in which case the first one raises
  `TemperatureOutOfRangeError`. `calculate_properties(calc, id, temps)` now
  delegates to it.
- **`h_sensible_to(calc, id, T, t_ref=298.15)`** — sensible enthalpy
  `H(T) − H(t_ref)` in J/mol.
- **`dcp_dt(calc, id, T)`** — analytical temperature derivative of Cp in
  J/(mol·K²), obtained by differentiating the NASA-7 polynomial term by term.
- **`Glenn.gamma(calc, id, T)`** — Cp/Cv ratio for an ideal gas. Not exported,
  because `gamma` collides with `SpecialFunctions.gamma`.
- **`mixture_properties(calc, mixture, T; strict=true)`** — properties of a
  fixed-composition mixture on both a molar and a mass basis, returning the new
  `MixedProperties` type. With `strict=false`, components outside their valid
  range are skipped, the remaining mole fractions are renormalised, and a
  warning is logged.
- **`get_temperature_bounds(tdb, id)`** — overall `(T_min, T_max)` covered by a
  species. `TemperatureOutOfRangeError` now reports the valid range in its
  message and carries it in `temp_bounds`.
- **`build_database(inp, db; merge_duplicates=true)`** — one-call database build
  that always closes the connection, even when parsing fails.
- **`parse_and_load(builder; merge_duplicates)`** — set to `false` to keep only
  the first record of a repeated species, matching the reference
  implementation's dataset exactly.
- **`scripts/rebuild_database.jl`** — reproducible, atomic dataset rebuild:
  builds next to the target, runs integrity checks and release gates
  (expected species/intervals/coefficient sets), and only then replaces the
  bundled database.
- **`docs/PARSER_FIX_PORTING.md`** — porting guide for the parser and dataset
  fixes, including the checklist and regression tests for the reference
  implementation.
- **`SpeciesData`** — typed record returned by `get_species_data` (identification
  metadata plus every temperature interval). Dictionary-style access
  (`data["name"]`) still works, and `to_dict` restores the previous `Dict` shape.
- **`Mixture`**, **`MixedProperties`** and `validate` — fixed-composition
  mixtures and their molar/mass-basis properties.
- **`CompositionError`** — raised for invalid mixture compositions (empty,
  duplicate species IDs, negative fractions, fractions not summing to 1).
- **`ThermoError`** — generic concrete `ThermoCalcError`.
- **`Glenn.R`** — compatibility alias of `R_UNIVERSAL`, mirroring the `pyglenn`
  API. Not exported, to avoid clashing with the common local variable name `R`.

### 🔧 Changed

- **Exception hierarchy:** `DatabaseNotConnectedError`, `SpeciesNotFoundError`,
  `TemperatureOutOfRangeError`, `CompositionError` and `ThermoError` are now
  subtypes of the abstract `ThermoCalcError`, so a single
  `catch e::ThermoCalcError` covers the whole package. The historical
  `ThermoCalcError("msg")` constructor still works and returns a `ThermoError`.
- **`TemperatureOutOfRangeError`** now carries `temp_bounds` and includes the
  valid range in its message when known.
- **`calculate_properties`** and `calculate_formation_enthalpy` now raise
  `SpeciesNotFoundError` / `TemperatureOutOfRangeError` instead of a generic
  error, matching their documented contract.

### 🗑️ Deprecated

- `get_properties_range` is deprecated in favour of
  `calculate_properties_range`. It still works and returns the same results, but
  emits a deprecation warning; it stays exported only for backwards
  compatibility.

### ⚠️ Breaking Changes

- `get_species_data` returns `SpeciesData` instead of `Dict`. `data["name"]`
  keeps working; code relying on other `Dict` operations (`haskey`, `get`,
  iteration) should use fields or `to_dict(data)`.
- `ThermoCalcError` is now an abstract type (still `<: Exception`). The
  historical `ThermoCalcError("msg")` constructor still works and returns a
  `ThermoError`.
- **Species `id` values are not stable across dataset rebuilds.** Because three
  bogus entries were removed and eight species added, 14 species changed ID
  (e.g. `C6H14(L),n-hexa` 2016 → 2018). Look species up by name instead of
  persisting numeric IDs.
- The migration guide (`docs/src/migration.md`) documents every change with
  before/after examples and a post-upgrade check script.

---

## [0.4.1] — 2026-08-22

### ✨ Added

- **Wrapper methods:** Added `get_gas_constant_ref(tdb::ThermoDB)` and `migrate_metadata!(tdb::ThermoDB)` to allow passing the high-level `ThermoDB` struct directly, ensuring API consistency.

### 🐛 Fixed

- Fixed a `MethodError` in the `Calculator` context manager docstring by replacing dictionary access with struct property access (`species[1].id`).
- Corrected misleading "legacy" comments in `01_basic_usage.jl` and `basic_usage.md` regarding substring searches.
- Documented a previously missing breaking change note for v0.2.0 (introduction of `ThermoCalcError`).

### ⚠️ Breaking Changes

- No breaking changes in v0.4.1.

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
