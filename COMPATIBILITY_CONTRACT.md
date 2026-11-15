# Compatibility Contract — Glenn.jl

This document states precisely what Glenn.jl promises to keep stable, and what
it may change without a major version bump. It exists so that downstream users
and packages can decide *what to depend on* — and so that a change to that
surface is recognisable as a breaking change during review, rather than being
discovered after a release.

The contract applies from **0.5.0** onwards. It describes observable behaviour,
not implementation.

---

## 1. Versioning scheme

Glenn.jl follows [Semantic Versioning 2.0.0](https://semver.org):

| Bump | Meaning | Guarantee |
|---|---|---|
| `PATCH` (0.5.0 → 0.5.1) | Bug fix, documentation, performance | No public-API change; no behavioural change other than fixing the reported defect |
| `MINOR` (0.5.0 → 0.6.0) | New features, new exports, deprecations | Additive only; all code that ran without deprecation warnings on 0.5.0 keeps working |
| `MAJOR` (0.5.0 → 1.0.0) | Anything else | Breaking changes allowed |

While the project is pre-1.0, **the minor number plays the role of the major
number**: `0.5 → 0.6` is treated as a breaking-change release. `0.5.0` itself is
a breaking release, collected in `CHANGELOG.md` under *Breaking Changes* and
explained step by step in [Migrating to 0.5.0](migration.md).

Additive changes that are cheap to make non-breaking — a new keyword argument
with a default, a new field at the end of a returned struct, a new CLI flag —
are *not* considered breaking and may appear in a `MINOR` release.

---

## 2. What is covered by the contract

### 2.1 Exported names

Everything listed in the `export` statements of `src/Glenn.jl` is public API.
That includes types (`Calculator`, `ThermoDB`, `ThermoDBBuilder`,
`ThermoProperties`, `SpeciesInfo`, `SpeciesData`, `NASACoefficients`,
`IntervalData`, `DatabaseStats`, `ValidationReport`, `Mixture`,
`MixedProperties`), the exception hierarchy, the two gas constants
(`R_UNIVERSAL`, `R_GLENN`), the database helpers, the calculator functions, the
fitting functions and `cli_main`.

Two documented names are intentionally **not** exported, to avoid clobbering
common user bindings. They are nevertheless public API and must be called
qualified:

* `Glenn.R` — alias of `R_UNIVERSAL`; not exported because `R` is a very common
  variable name (see the note in the 0.5.0 changelog).
* `Glenn.gamma` — Cp/Cv; not exported because it clashes with
  `SpecialFunctions.gamma`.

### 2.2 Types and fields

For every exported struct, the **names and documented meanings of the fields**
are stable, as are their declared types. Reading a field will keep working.

Field *declaration order*, memory layout, and `propertynames` ordering are not
guaranteed.

Constructors: only those with a docstring are part of the contract. Structs may
gain inner constructors, validation, or additional outer constructors.

### 2.3 Function signatures

For every documented function, the contract covers:

* the positional argument order and types,
* the keyword arguments listed in the docstring, their names and defaults,
* the meaning and units of the return value.

Functions may gain **new trailing keyword arguments with defaults** at any time.
Existing keywords will not be removed without a deprecation cycle (§4).

### 2.4 Units

All thermodynamic quantities are returned in SI-derived molar units, and this
will not change:

| Quantity | Unit |
|---|---|
| `cp` | J/(mol·K) |
| `s` | J/(mol·K) |
| `h_relative`, `h_sensible_to`, `calculate_formation_enthalpy`, `calculate_enthalpy_change` | J/mol |
| `dcp_dt` | J/(mol·K²) |
| `molecular_weight` | kg/mol |
| mass-specific variants (`cp_mass`, `h_mass`, `s_mass`) | J/(kg·K), J/kg, J/(kg·K) |
| `gamma` | dimensionless |

### 2.5 Exceptions

The exception hierarchy is part of the contract:

```
ThermoCalcError  (abstract)
├── ThermoError
├── DatabaseNotConnectedError
├── SpeciesNotFoundError
├── TemperatureOutOfRangeError
└── CompositionError
```

Code may rely on `e isa ThermoCalcError` and on the concrete type. New leaf
types may be added under `ThermoCalcError` in a minor release — so an exhaustive
`if/elseif` over the concrete types should have a fallback branch.

`SpeciesNotFoundError` and `TemperatureOutOfRangeError` carry structured
accessors (`species_id`, `temperature`, `species_name`, `temp_bounds`); these are
stable. **The human-readable message is not**: wording, number formatting and
language may change.

### 2.6 Temperature and interval semantics

* The valid range of a species is `temp_min .. temp_max`, **both endpoints
  inclusive**: evaluating exactly at `temp_min` or `temp_max` succeeds.
* Requesting a temperature outside the range raises
  `TemperatureOutOfRangeError` when a single value is requested, and is skipped
  when a vector is passed with `strict = false`.
* If two intervals of the same species share a boundary temperature, the
  **lower** interval is used (lowest `interval_number`). Since 0.5.0 this
  selection is deterministic; it is now part of the contract.
* A point with `T <= breakpoint` belongs to the lower interval in
  `fit_nasa7_multi`, consistent with the rule above.

### 2.7 Numerical behaviour

* `calculate_properties(calc, id, T).h_relative` follows the NASA-7 convention:
  `H°(298.15 K)` equals the species' standard enthalpy of formation. This is an
  identity users may rely on:
  `ΔH°f + h_sensible_to(calc, id, T) == h_relative(T)`.
* The reference gas constant used by the bundled dataset is reported by
  `get_gas_constant_ref` and stored in the database (`metadata.gas_constant_ref`).
  It is `8.314510 J/(mol·K)`; `R_UNIVERSAL = 8.31446261815324` is provided for
  work that needs the current CODATA value. This distinction will not change
  silently.
* Reproducibility: for identical inputs on the same platform, results are stable
  to within **1e-12 relative**. Bit-identical results across platforms, across
  Julia versions, or after a refactor of the evaluation order are **not**
  guaranteed — floating-point summation order is not part of the contract.
  Documented tolerances in the test suite are the authoritative statement of
  accuracy.

### 2.8 Dataset contents

The bundled database is a versioned artefact with these guarantees:

* Species, intervals and coefficient sets present in both the previous release
  and the new one have **identical coefficients**. A release never silently
  "improves" a polynomial.
* The dataset gates asserted by `scripts/rebuild_database.jl` (currently
  **2035 species / 3795 intervals / 3795 coefficient sets**) must hold for the
  shipped file; changing them is a reviewed, documented event.
* New species may be added in a `MINOR` release. Removal of a species requires
  a `MAJOR` (or pre-1.0 `MINOR`) bump and a changelog entry.

### 2.9 Species identifiers

**Species IDs are not stable across dataset rebuilds.** They are SQLite
`AUTOINCREMENT` values assigned in file order; inserting or reordering records
renumbers everything after the insertion point. In the 0.5.0 rebuild, 14 of the
2027 species shared with 0.4.x changed ID.

The contract is the opposite of what users usually assume, so it is stated
explicitly: **persist species names, never numeric IDs.** Names are unique and
covered by the contract; IDs are a row-level detail.

### 2.10 Database schema

A database file is accepted by Glenn.jl if it contains the tables and columns
listed below. Anything else in the file is ignored.

| Table | Required columns |
|---|---|
| `species` | `id`, `name`, `phase`, `molecular_weight`, `heat_of_formation_298K`, `num_intervals` |
| `temperature_intervals` | `id`, `species_id`, `interval_number`, `temp_min`, `temp_max` |
| `coefficients` | `interval_id`, `a1`…`a7`, `b1`, `b2` |
| `metadata` | `key`, `value` (at least `gas_constant_ref`) |

Additional tables and additional columns are allowed and ignored. Missing
`file_metadata` (or an unset `total_species`) only produces a **warning** from
`validate_database`, never an error. Databases written by 0.3.x/0.4.x remain
readable; `migrate_metadata!` / `glenn migrate-metadata` adds the `metadata` row
that older files lack.

The physical layout of the file (page size, indices, timestamps) is not part of
the contract.

### 2.11 Command-line interface

The CLI is public API:

* Subcommands: `build`, `query`, `validate`, `migrate-metadata`, plus the
  general `--version` and `--help` / `-h`.
* Options: `-i/--input`, `-o/--output`, `-d/--database`, `-s/--species`,
  `-v/--verbose`.
* Exit codes: `0` on success, `1` on failure. This includes unknown commands and
  unknown options, which exit `1` — a typo in a script must not be mistaken for
  success.

Subcommands, options and exit codes are stable. The **exact text written to
stdout/stderr is not**; scripts should rely on exit codes, and on `--version`
printing the version string, nothing more.

---

## 3. What is *not* covered

The following may change in any release, including a `PATCH`:

* Unexported names, and every name beginning with an underscore
  (`_parse_intervals`, `_basis_matrix`, …).
* `Glenn.ThermoDatabase` internals and the SQLite statements issued internally.
  Only the behaviour observable through exported functions is guaranteed.
* Error messages, log messages, `@warn`/`@info` texts, and the exact rendering of
  `show` (both the plain and `text/plain` MIME variants).
* Performance characteristics. A `MINOR` release may make something faster or
  slower; a `PATCH` may improve performance but not regress it by more than a
  small factor for documented use cases.
* The contents of `docs/`, `examples/` and `test/`, which are illustrative.
* The Python-compatibility details of pyglenn that Julia cannot express the same
  way (e.g. `to_dict` returns a Julia `Dict`, not a Python dict).

---

## 4. Deprecation policy

A public API element is removed only after:

1. it is marked with `Base.@deprecate` (which rewrites the call to the
   replacement, so user code keeps working),
2. its docstring or a comment names the replacement,
3. `CHANGELOG.md` lists it under **Deprecated** with the version that will remove
   it,
4. at least **one minor release** has shipped with the deprecation in place.

Removal happens in the next breaking release. Note that `Base.@deprecate`
warnings are silent by default; run julia with `--depwarn=yes` to see them.

Currently deprecated:

| Deprecated | Replacement | Since |
|---|---|---|
| `get_properties_range(calc, id, T_range)` | `calculate_properties_range(calc, id, T_range)` | 0.5.0 |

---

## 5. Supported environments

| Item | Supported |
|---|---|
| Julia | 1.6 and later (`julia = "1.6"` in `Project.toml`) |
| CI matrix | Julia 1.6, current stable, and nightly × Linux, macOS, Windows (nightly only on Linux) |
| SQLite.jl | `"1"` |
| Runtime dependencies | `Logging`, `Printf`, `LinearAlgebra` (stdlib) and `SQLite` only |

Dropping an old Julia version is treated as a breaking change and follows §4:
the supported range is announced one release before it is raised. Adding support
for a newer Julia release is a `PATCH`-level change.

The package is pure Julia plus the SQLite C library shipped by SQLite.jl; no
additional system libraries or compiler toolchain are required.

---

## 6. How this contract is enforced

Not by intention alone — each clause is backed by a check:

| Clause | Enforced by |
|---|---|
| Exports, types, signatures | Testsets `Exports` and `Version and metadata`; Aqua.jl `ambiguities`, `unbound_args`, `piracies` |
| Field names and types | `SpeciesData`, `Mixture`, `MixedProperties` testsets |
| Exception hierarchy | `Exceptions` / `Exception hierarchy` testsets |
| Units and numerical identities | `NASA-7 polynomials`, `Numerical identities` testsets |
| Temperature semantics | `Edge cases - interval boundaries` testset |
| Dataset gates | `Bundled database gates` testset and `scripts/rebuild_database.jl` |
| Schema compatibility | `ThermoDB` and `validate_database` testsets; CLI `migrate-metadata` test |
| CLI contract | `CLI smoke` and `CLI - Phase 5 commands` testsets |

A change that breaks one of these checks is a signal that this document is
being changed, which is exactly when it needs to be reviewed.

Style is *not* part of the contract and is not gated in CI. `.JuliaFormatter.toml`
fixes the house style (4-space indent, 92-column margin) and is applied by the
maintainer before committing:

```bash
julia --project -e 'using JuliaFormatter; format(".")'
```

Formatting-only changes are never mixed into a behaviour-changing commit.

---

## 7. Proposing a change to the contract

1. Open an issue describing which clause changes and why.
2. If the change is breaking, it is batched with other breaking changes and
   released under a new minor (pre-1.0) or major version.
3. The pull request must update, in the same commit: the implementation, the
   tests that enforce the clause, `CHANGELOG.md`, this document, and — when
   relevant — `docs/src/migration.md`.
