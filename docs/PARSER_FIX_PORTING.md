# Dataset parser fixes — porting guide (Glenn.jl → pyglenn)

This document describes the parser and dataset fixes implemented in Glenn.jl
v0.5.0, so they can be ported to the reference implementation
([`pyglenn`](https://github.com/ProfLeao/pyglenn)).

Everything below was verified against the bundled `thermo.inp`
(NASA Glenn/CEA, reference date 9/09/04, 15 638 raw lines).

---

## 1. Symptom

Three separate problems, all caused by the same parser design:

| # | Symptom | Evidence |
|---|---------|----------|
| S1 | Three "species" whose name is a FORTRAN number | `-1.302004763D+06`, `-7.310769440D+05`, `4.461077310D+04` |
| S2 | Eight genuine species missing from the database | `C2H5OH(L)`, `C6H6(L)`, `CH3OH(L)`, `CLO3F`, `H2O2(L)`, `JP-10(g)`, `N2H4(L)`, `NH4CLO4(I)` |
| S3 | Condensed substances reporting only part of their temperature range | `Cr(cr)` stored only `200–311.5 K`, so 500 K raised `TemperatureOutOfRangeError` |
| S4 | Species with **corrupted** intervals | The pre-0.5.0 `Cr(cr)` had `[200, 311.5]` **and** `[1000, 2130]` — the `311.5–1000 K` range was missing |

---

## 2. Root causes

### B1 — Species-header detection is too permissive

RECORD 1 (species identification) is a fixed-width 80-column record whose name
field is columns 1–16. **A coefficient line also fits in columns 1–16**, e.g.:

```
-1.302004763D+06 5.407120940D+02-1.596697810D+00 ...
```

The apparent "name" is the single token `-1.302004763D+06`, which the old check
accepted because it only rejected:

* empty names,
* names containing whitespace,
* lines that look like temperature records.

It did **not** reject coefficient lines (D-notation exponentials).

### B2 — Inserts are not atomic per species

The species row was inserted **before** its interval records were parsed and
validated. When a block was malformed, the species remained in the database with
zero or partial intervals. Because the schema has `UNIQUE(name)`, later attempts
to insert the same species then failed, so the data could never be repaired by a
subsequent rebuild.

### B3 — No resynchronisation after a malformed block

After a failure the parser simply advanced one line. Since a coefficient line can
be mistaken for a species header (B1), the parser then consumed the *following*
lines as that bogus species' records — cascading the misalignment into real
species (S2) and silently mis-assigning intervals (S4).

### B4 — Repeated species names are dropped

`thermo.inp` encodes phase transitions by repeating the species name in several
records:

| Species | Records |
|---|---|
| `Cr(cr)` | 2 — *Below* / *Above lambda trans.* |
| `Cr2O3(I)` | 3 |
| `Co(b)`, `Fe(a)`, `Fe2O3(cr)`, `Fe3O4(cr)`, `K2S(cr)`, `Na2S(cr)`, `Ni(cr)`, `SnS(cr)` | 2 each |

Because of `UNIQUE(name)`, only the first record was kept, so the
high-temperature range of 10 substances was unavailable (S3). Worse, in the old
implementation the interval loop kept running after the `UNIQUE(name)` violation
and re-used the existing `species_id`, so intervals from later records were
inserted with colliding `interval_number` values: some were rejected by
`UNIQUE(species_id, interval_number)` and some were stored under the wrong
numbering (S4).

---

## 3. Fix 1 — Strict species-header detection

A candidate is a species header only if **all** of the following hold:

1. the name field (cols 1–16, or the whole stripped line if shorter) is non-empty;
2. it contains exactly one whitespace-separated token;
3. it is **not** a temperature record;
4. it is **not** a coefficient line (must not contain a FORTRAN D-notation
   number such as `1.234567890D+05`).

Pseudocode:

```
is_species_header(line):
    name = strip(line[0:16]) if len(line) > 16 else strip(line)
    return  name != ""
        and len(name.split()) == 1
        and not is_temperature_line(line)
        and not is_coefficient_line(line)
```

Julia (current Glenn.jl implementation, `src/builder.jl`):

```julia
function is_species_header(line::AbstractString)
    name, _ = parse_species_record(line)
    return !isempty(name) &&
           length(split(name)) == 1 &&
           !is_temperature_line(line) &&
           !is_coefficient_line(line)
end
```

The coefficient test is a regex for FORTRAN double precision:

```
r"\d\.\d{0,9}D[+\-]\d{1,2}"   (case-insensitive)
```

---

## 4. Fix 2 — Atomic, validated block parsing

Parse a species' complete set of interval triplets **before touching the
database**. If anything is invalid, return "no result" and let the caller
resynchronise — no partial rows are ever written.

Validation performed per interval:

* the line is a temperature record;
* the next two lines are coefficient records;
* `temp_min` and `temp_max` are present, finite and `temp_min < temp_max`;
* all nine coefficients (`a1`…`a7`, `b1`, `b2`) are present and finite.

```
parse_intervals(lines, start, n) -> (intervals, next_index) | None
```

Julia signature:

```julia
function _parse_intervals(lines::Vector{String}, start::Int, num_intervals::Int)
    # returns Tuple{Vector, Int} on success, or nothing
end
```

---

## 5. Fix 3 — Resynchronise at the next verified header

Main loop:

```
i = 2                                  # 0-based, after THERMO + global line
while i < len(lines):
    if not is_species_header(lines[i]) or i + 1 >= len(lines):
        i += 1
        continue                       # skip forward, do not guess

    name, comments = parse_species_record(lines[i])
    info           = parse_general_info(lines[i + 1])
    n              = info["num_intervals"]

    if n <= 0:
        i += 1
        continue

    parsed = parse_intervals(lines, i + 2, n)
    if parsed is None:
        log.warning("Skipping malformed species block at line %d: %s", i + 1, name)
        skipped += 1
        i += 1                         # resync: scan for the next real header
        continue

    intervals, next_index = parsed
    insert_species_with_intervals(name, comments, info, intervals)
    i = next_index                     # jump past the consumed block
```

Key points:

* **the species row is inserted only after the whole block validated**;
* on failure advance by **one** line (not to `next_index`), so the resync scan
  can find a header that starts earlier than the failed attempt;
* on success jump to `next_index`, never re-scan inside the block.

---

## 6. Fix 4 — Merge repeated species records (optional, improves data)

Behaviour when the species name already exists:

1. read the existing intervals (`interval_number`, `temp_min`, `temp_max`);
2. `next_number = max(interval_number) + 1`;
3. for each new interval:
   * **skip** (debug log) if an existing range has the same bounds;
   * **skip** (warning) if it *overlaps* an existing range
     (`tmin < existing_max and tmax > existing_min`) — touching endpoints are
     allowed and expected;
   * otherwise insert with `next_number` and increment it;
4. if anything was added, set `species.num_intervals` to the total row count.

This turns the `Cr(cr)` pair into three contiguous intervals:

```
200 – 311.5   (Below lambda)
311.5 – 1000  (Above lambda, first)
1000 – 2130   (Above lambda, second)
```

### Trade-off — this diverges from pyglenn's counts

| Dataset | Species | Intervals | Coefficients |
|---|---|---|---|
| pyglenn 0.3.0 (first record only) | 2 035 | 3 779 | 3 779 |
| Glenn.jl v0.5.0 (merged) | 2 035 | **3 795** | **3 795** |

The difference is exactly the 16 intervals recovered from the 11 repeated
records (one record contributes 2 intervals). Both datasets are internally
consistent; the merged one simply covers more of each substance's range.

Glenn.jl keeps the strict-reference behaviour available:
`parse_and_load(builder; merge_duplicates=false)`.

**Recommendation:** port Fixes 1–3 unconditionally (they fix real data
corruption). Port Fix 4 as an opt-in flag first, then decide the default after
comparing against NIST-JANAF for the recovered ranges.

---

## 7. Porting checklist for pyglenn

`src/pyglenn/builder.py`:

1. **Add** `is_species_header(line)` (section 3). It already exists in pyglenn —
   verify it rejects coefficient lines; this was the missing piece.
2. **Verify** `_parse_intervals` returns `None` on any invalid record and does
   not write to the cursor (it already does — keep it that way).
3. **Verify** the main loop uses `index += 1` on a malformed block and
   `index = next_index` on success (already correct).
4. **Add** the duplicate-name merge of section 6 behind a keyword argument, e.g.
   `parse_and_load(self, *, merge_duplicates: bool = True)`.
5. **Update** `scripts/rebuild_database.py` gates:
   * `EXPECTED_SPECIES = 2035` (unchanged)
   * `EXPECTED_INTERVALS = 3795` and `EXPECTED_COEFFS = 3795` **if** merging is
     enabled; keep `3779` if it stays opt-in/off.
6. **Add** regression tests (section 8).

`src/pyglenn/database.py`:

7. **Extend** `validate_database()` with the semantic guard that rejects species
   names looking like FORTRAN numbers:
   `name LIKE '%.%D%' OR name LIKE '%.%E%'`.

---

## 8. Regression tests to add

Minimal `thermo.inp` fixtures (one temperature interval per record):

| Fixture | Expectation |
|---|---|
| valid species preceded by a stray coefficient line | exactly **1** species; no name matching `\dD[+-]\d` |
| same name, ranges `200–1000` and `1000–2000` | 1 species, **2** intervals, contiguous |
| same name, identical range twice | 1 species, **1** interval |
| same name, merging disabled | 1 species, **1** interval |

Plus, against the bundled database:

```
total_species       == 2035
total_intervals     == 3795   (3779 with merging disabled)
total_coeff_sets    == 3795
no species name matches \dD[+-]\d
"C2H5OH(L)", "C6H6(L)", "CLO3F", "H2O2(L)", "JP-10(g)" are all found
Cr(cr) has 3 intervals, spanning 200.0 – 2130.0 K
```

Total counts are checked by `scripts/rebuild_database.jl` as release gates, so a
rebuild that changes the dataset fails loudly instead of silently shipping.

---

## 9. Non-regression evidence (Glenn.jl)

Before replacing the bundled database, all 2 027 species present in both the old
and new databases were compared field by field:

* `temp_min`, `temp_max` and all nine coefficients of every interval — identical;
* `molecular_weight` and `heat_of_formation_298K` — identical.

The only intentional differences are the 3 removed bogus species, the 8 recovered
species and the merged phase-transition ranges. Spot values after the fix:

| Species | T (K) | Cp (J/(mol·K)) | S° (J/(mol·K)) |
|---|---|---|---|
| `Cr(cr)` | 500 | 26.64 | 36.554 |
| `Cr(cr)` | 1000 | 31.86 | 56.524 |
| `Cr(cr)` | 2000 | 52.21 | 84.445 |
| `Fe(a)` | 1100 | 46.31 | 72.654 |
| `Ni(cr)` | 1500 | 36.26 | 80.671 |

`O2` at 1000 K is unchanged (`Cp = 34.8825450091414`, `H = 22707.210697094983`,
`S = 243.58731387789788`), which confirms the fixes did not perturb existing
data.

---

## 10. Reproducing the rebuild

```bash
julia --project=. scripts/rebuild_database.jl
```

The script builds into a temporary file next to the target, runs the integrity
checks and the release gates, and only then replaces `data/thermo.db`. A failed
rebuild leaves the previous database untouched.
