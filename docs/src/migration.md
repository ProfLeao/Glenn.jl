```@meta
CurrentModule = Glenn
```

# Migrating to 0.5.0

Glenn.jl 0.5.0 completes the API surface of the reference implementation
(`pyglenn`). Most of it is **additive** — new functions, new types, and a
corrected dataset. Two changes require edits to existing code, and one of them
is silent, so please read this page before upgrading.

---

## Summary

| Change | Severity | What to do |
|---|---|---|
| `get_species_data` returns `SpeciesData`, not `Dict` | **Breaking** (silent) | Use fields, or `to_dict(data)` |
| `ThermoCalcError` is now an abstract type | **Breaking** | Construct `ThermoError` |
| Species `id` values shifted in the bundled dataset | **Breaking** (silent) | Look species up by name |
| Dataset rebuilt: 2035 species, 3795 intervals | Behaviour | Re-run any cached analysis |
| Specific exception types | Compatible | Nothing (they are `<: ThermoCalcError`) |
| New exported names | Compatible | Watch for the generic `validate` |

---

## 1. `get_species_data` returns `SpeciesData`

`get_species_data` used to return a `Dict{String, Any}`. It now returns the
typed [`SpeciesData`](@ref Glenn.ThermoDatabase.SpeciesData).

```julia
# 0.4.x
data = get_species_data(tdb, id)
name = data["name"]
first_range = data["intervals"][1]

# 0.5.0
data = get_species_data(tdb, id)
name = data.name
first_range = data.intervals[1]
```

### What keeps working

Dictionary-style indexing was kept on purpose, so the most common pattern needs
no change at all:

```julia
data["name"]       # still works
data["intervals"]  # still works
```

### What breaks

Anything that treats the result as an actual `Dict`:

| Old code | Replacement |
|---|---|
| `haskey(data, "name")` | `hasfield(SpeciesData, :name)` |
| `get(data, "name", "n/a")` | `data.name` (may be `nothing`) |
| `for (k, v) in data` | `for k in keys(data); v = data[k]; end` |
| `merge(data, other)` | `merge(to_dict(data), other)` |
| `f(d::Dict)` | Accept `SpeciesData`, or pass `to_dict(data)` |

To recover the exact previous shape:

```julia
as_dict = to_dict(data)   # Dict{String, Any}
```

---

## 2. `ThermoCalcError` is now an abstract type

`ThermoCalcError` became the abstract root of the error hierarchy so that a
single `catch` covers the whole package:

```
ThermoCalcError (abstract)
├── ThermoError                  generic error, carries `msg`
├── DatabaseNotConnectedError
├── SpeciesNotFoundError         carries `species_id`
├── TemperatureOutOfRangeError   carries `temperature`, `species_name`, `temp_bounds`
└── CompositionError
```

### What keeps working

```julia
try
    calculate_properties(calc, id, T)
catch e
    e isa ThermoCalcError || rethrow()   # catches every package error
end

err = ThermoCalcError("something failed")   # still valid → returns a ThermoError
err.msg                                      # "something failed"
```

### What breaks

```julia
isconcretetype(ThermoCalcError)   # was true, now false
fieldnames(ThermoCalcError)       # was (:msg,), now errors
ThermoCalcError[]                 # still valid, but elements must be concrete subtypes
```

If you were constructing the type directly, use the concrete `ThermoError`:

```julia
throw(ThermoError("something failed"))
```

---

## 3. Species IDs are not stable across dataset rebuilds

This is the riskiest change in 0.5.0. The bundled database was rebuilt with a
corrected parser, and `species.id` is an `AUTOINCREMENT` key assigned in file
order. Because three bogus "species" disappeared and eight real species were
added, **some IDs moved**:

| Species | 0.4.x `id` | 0.5.0 `id` |
|---|---|---|
| `C6H5NH2(L)` | 2015 | 2017 |
| `C6H14(L),n-hexa` | 2016 | 2018 |
| `C7H16(L),n-hept` | 2018 | 2020 |

In total 14 of the 2027 shared species changed ID. `CH4` (296), `CO2` (316),
`H2O` (672), `N2` (861) and `O2` (931) happened to keep theirs — do not rely on
that.

### Do this instead

Persist the **name**, never the numeric ID:

```julia
# Fragile — the ID is an internal detail
const CH4_ID = 296

# Robust
ch4 = only(get_available_species(calc, "CH4", exact_match = true))
props = calculate_properties(calc, ch4.id, 1000.0)
```

If you stored IDs in a file or database, re-resolve them on upgrade:

```julia
sid = only(get_available_species(calc, name, exact_match = true)).id
```

---

## 4. Dataset changes

| Change | Detail |
|---|---|
| Bogus species removed | Three entries that were actually FORTRAN coefficient lines: `-1.302004763D+06`, `-7.310769440D+05`, `4.461077310D+04` |
| Species recovered | `C2H5OH(L)`, `C6H6(L)`, `CH3OH(L)`, `CLO3F`, `H2O2(L)`, `JP-10(g)`, `N2H4(L)`, `NH4CLO4(I)` |
| Temperature ranges completed | 16 intervals recovered for 10 condensed substances with phase transitions (`Cr(cr)`, `Cr2O3(I)`, `Fe(a)`, `Ni(cr)`, `SnS(cr)`, …) |
| Totals | 2035 species / 3795 intervals (previously 2030 / 3772) |

**No previously available value changed.** All 2027 species present in both
datasets were compared interval by interval — coefficients, `temp_min`,
`temp_max`, molecular weights and formation enthalpies are identical.

### What this means for you

* Queries that used to raise `TemperatureOutOfRangeError` for substances such as
  `Cr(cr)` above 311.5 K now return valid data. If you had a workaround for the
  old gap, remove it.
* If you cached aggregates (for example "total number of intervals"), recompute
  them.
* The three bogus names never produced meaningful results, but if you filtered
  species by name patterns you may see one fewer match.

---

## 5. New exported names

`build_database`, `SpeciesData`, `Mixture`, `MixedProperties`,
`CompositionError`, `ThermoError`, `to_dict`, `validate`.

`validate` is a generic name. If your code (or another package you load) also
defines `validate`, qualify the call:

```julia
Glenn.validate(mixture)
```

`R` is deliberately **not** exported — use `Glenn.R`. Exporting a single-letter
constant would make `R = 8` fail in any module that does `using Glenn`.

---

## 6. What did not change

* `Calculator`, `calculate_properties`, `calculate_formation_enthalpy`,
  `calculate_enthalpy_change`, `get_properties_range`, `get_available_species`,
  `find_species`, `get_statistics`, `list_all_species`, `list_species_page`.
* The fields of `ThermoProperties` (`temperature`, `cp`, `h_relative`, `s`,
  `temp_min`, `temp_max`, `species_name`, `phase`).
* `R_UNIVERSAL = 8.31446261815324` and `R_GLENN = 8.314510`.
* Thermodynamic results for every species that already existed.

---

## 7. Post-upgrade check

```julia
using Glenn

Calculator() do calc
    @assert length(get_available_species(calc, "CLO3F", exact_match = true)) == 1

    cr = only(get_available_species(calc, "Cr(cr)", exact_match = true))
    props = calculate_properties(calc, cr.id, 1000.0)   # 0.4.x raised here
    println("Cr(cr) @1000 K: Cp = ", round(props.cp, digits = 2), " J/(mol·K)")

    data = get_species_data(calc.db, cr.id)
    println("intervals = ", length(data.intervals))     # 3
    println("dict keys = ", length(to_dict(data)))      # 10
end
```

If that runs, the upgrade is complete.
