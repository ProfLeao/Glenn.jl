# Test suite for Glenn.jl
# Tests the thermochemical database queries, NASA-7 polynomial calculations,
# builder parsing, CLI, exceptions, and context manager.
# Uses an in-memory SQLite database with a small set of known species data.

using Glenn
using Test
using SQLite

# ------------------------------------------------------------------
# Helper: create an in-memory test database with known data
# ------------------------------------------------------------------
function setup_test_db()
    db = SQLite.DB()  # in-memory database
    SQLite.execute(db, "PRAGMA foreign_keys = ON")

    SQLite.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS species (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        formula TEXT,
        comments TEXT,
        reference_code TEXT,
        phase TEXT CHECK(phase IN ('gas', 'condensed')),
        molecular_weight REAL,
        heat_of_formation_298K REAL,
        num_intervals INTEGER,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
""",
    )

    SQLite.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS temperature_intervals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        species_id INTEGER NOT NULL,
        interval_number INTEGER NOT NULL,
        temp_min REAL NOT NULL,
        temp_max REAL NOT NULL,
        h_298_to_0 REAL,
        FOREIGN KEY (species_id) REFERENCES species(id) ON DELETE CASCADE,
        UNIQUE(species_id, interval_number)
    )
""",
    )

    SQLite.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS coefficients (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        interval_id INTEGER NOT NULL UNIQUE,
        a1 REAL, a2 REAL, a3 REAL, a4 REAL, a5 REAL,
        a6 REAL, a7 REAL,
        b1 REAL, b2 REAL,
        FOREIGN KEY (interval_id) REFERENCES temperature_intervals(id) ON DELETE CASCADE
    )
""",
    )

    SQLite.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS file_metadata (
        id INTEGER PRIMARY KEY,
        temp_min_global REAL,
        temp_500_K REAL,
        temp_1500_K REAL,
        temp_max_global REAL,
        reference_date TEXT,
        total_species INTEGER
    )
""",
    )

    # Insert O2 data (NIST-JANAF): 2 intervals (200-1000K, 1000-6000K)
    SQLite.execute(
        db,
        """
    INSERT INTO species (id, name, formula, comments, reference_code, phase,
                         molecular_weight, heat_of_formation_298K, num_intervals)
    VALUES (1, 'O2', 'O2', 'NIST-JANAF', 'j', 'gas', 31.9988, 0.0, 2)
""",
    )

    SQLite.execute(
        db,
        """
    INSERT INTO temperature_intervals (id, species_id, interval_number,
                                       temp_min, temp_max, h_298_to_0)
    VALUES (1, 1, 1, 200.0, 1000.0, 8680.0)
""",
    )

    # O2 low-temp coefficients (200-1000K)
    SQLite.execute(
        db,
        """
    INSERT INTO coefficients (id, interval_id,
        a1, a2, a3, a4, a5, a6, a7, b1, b2)
    VALUES (1, 1,
        -3.42556342e+04, 4.84700097e+02, 1.11901096e+00,
        4.29388924e-03, -6.83630052e-07, -2.02337270e-09,
        1.03904002e-12, -3.39145487e+03, 1.84969947e+01)
""",
    )

    SQLite.execute(
        db,
        """
    INSERT INTO temperature_intervals (id, species_id, interval_number,
                                       temp_min, temp_max, h_298_to_0)
    VALUES (2, 1, 2, 1000.0, 6000.0, 8680.0)
""",
    )

    # O2 high-temp coefficients (1000-6000K)
    SQLite.execute(
        db,
        """
    INSERT INTO coefficients (id, interval_id,
        a1, a2, a3, a4, a5, a6, a7, b1, b2)
    VALUES (2, 2,
        -1.03793902e+06, 2.34483028e+03, 1.81973204e+00,
        1.26784758e-03, -2.18806799e-07, 2.05371957e-11,
        -8.19346705e-16, -1.68901093e+04, 1.73871651e+01)
""",
    )

    SQLite.execute(
        db,
        """
    INSERT INTO file_metadata (id, temp_min_global, temp_500_K,
                               temp_1500_K, temp_max_global, reference_date,
                               total_species)
    VALUES (1, 200.0, 500.0, 1500.0, 6000.0, 'test', 1)
""",
    )

    return db
end

function copy_to_disk(mem_db::SQLite.DB, disk_path::String)
    disk_db = SQLite.DB(disk_path)
    SQLite.execute(disk_db, "PRAGMA foreign_keys = ON")

    for table_sql in [
        """CREATE TABLE IF NOT EXISTS species (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE, formula TEXT, comments TEXT,
            reference_code TEXT, phase TEXT CHECK(phase IN ('gas', 'condensed')),
            molecular_weight REAL, heat_of_formation_298K REAL, num_intervals INTEGER,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""",
        """CREATE TABLE IF NOT EXISTS temperature_intervals (
            id INTEGER PRIMARY KEY AUTOINCREMENT, species_id INTEGER NOT NULL,
            interval_number INTEGER NOT NULL, temp_min REAL NOT NULL,
            temp_max REAL NOT NULL, h_298_to_0 REAL,
            FOREIGN KEY (species_id) REFERENCES species(id) ON DELETE CASCADE,
            UNIQUE(species_id, interval_number))""",
        """CREATE TABLE IF NOT EXISTS coefficients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            interval_id INTEGER NOT NULL UNIQUE,
            a1 REAL, a2 REAL, a3 REAL, a4 REAL, a5 REAL, a6 REAL, a7 REAL,
            b1 REAL, b2 REAL,
            FOREIGN KEY (interval_id) REFERENCES temperature_intervals(id) ON DELETE CASCADE)""",
        """CREATE TABLE IF NOT EXISTS file_metadata (
            id INTEGER PRIMARY KEY, temp_min_global REAL, temp_500_K REAL,
            temp_1500_K REAL, temp_max_global REAL, reference_date TEXT,
            total_species INTEGER)""",
    ]
        SQLite.execute(disk_db, table_sql)
    end

    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM species")
        SQLite.execute(
            disk_db,
            "INSERT INTO species VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            Tuple(row),
        )
    end
    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM temperature_intervals")
        SQLite.execute(
            disk_db,
            "INSERT INTO temperature_intervals VALUES (?, ?, ?, ?, ?, ?)",
            Tuple(row),
        )
    end
    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM coefficients")
        SQLite.execute(
            disk_db,
            "INSERT INTO coefficients VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            Tuple(row),
        )
    end
    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM file_metadata")
        SQLite.execute(
            disk_db,
            "INSERT INTO file_metadata VALUES (?, ?, ?, ?, ?, ?, ?)",
            Tuple(row),
        )
    end

    return disk_db
end

"""
    make_thermo_inp(records) -> String

Build a minimal FORTRAN `thermo.inp` from `(name, tmin, tmax[, mw[, phase]])`
records, one temperature interval each. Allows several records to reuse the same
species name, which is how `thermo.inp` encodes phase transitions.

Fixed-width columns follow NASA FORTRAN Appendix C:

* RECORD 1 — name (1–16), comments (19–80)
* RECORD 2 — intervals (1–2), ref code (4–9), phase (51–52), MW (53–65), ΔH°f (66–80)
* RECORD 3 — T_min (1–11), T_max (12–22), h_298→0 (66–80)
* RECORDS 4–5 — coefficients in 16-character fields
"""
function make_thermo_inp(records)
    coeffs_a = ["1.0D+00", "0.0D+00", "3.5D+00", "0.0D+00", "0.0D+00"]
    coeffs_b = ["0.0D+00", "0.0D+00", "0.00000000D+00", "1.0D+02", "2.0D+01"]

    lines = String[
        "THERMO",
        "   300.000   1000.000   5000.000   6000.000 9/09/04",
    ]
    for rec in records
        name, tmin, tmax = rec[1], rec[2], rec[3]
        mw = length(rec) >= 4 ? rec[4] : "31.9988"
        phase_code = length(rec) >= 5 ? rec[5] : " 0"

        # RECORD 1 — name (1-16) and comments (19-80)
        push!(lines, rpad(name, 16) * "  " * rpad("Test species", 62))

        # RECORD 2 — ref code (4-9), phase (51-52), MW (53-65), ΔH°f (66-80)
        rec2 =
            " 1" * " " * rpad("g 2/99", 6) * rpad("", 41) *
            phase_code * rpad(mw, 13) * rpad("0.0", 15)
        push!(lines, rpad(rec2, 80))

        # RECORD 3 — T_min (1-11), T_max (12-22), h_298→0 (66-80)
        rec3 = rpad(tmin, 11) * rpad(tmax, 11) * rpad("", 43) * rpad("8680.0", 15)
        push!(lines, rpad(rec3, 80))

        # RECORDS 4-5 — a1..a5 and a6, a7, -, b1, b2
        push!(lines, join(lpad.(coeffs_a, 16)))
        push!(lines, join(lpad.(coeffs_b, 16)))
    end

    return join(lines, "\n") * "\n"
end

# ------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------
@testset "Glenn.jl" begin
    # ==================================================================
    # Code quality (Aqua.jl)
    # ==================================================================
    @testset "Aqua (code quality)" begin
        using Aqua
        # Method ambiguities, unbound type parameters, and type piracies.
        # stale_deps disabled: JuliaFormatter is a dev-only tool, not a runtime dep.
        # deps_compat disabled: Logging/Printf are stdlib packages that
        #   track the Julia version — they don't need explicit compat entries.
        Aqua.test_all(
            Glenn;
            ambiguities = true,
            unbound_args = true,
            piracies = true,
            stale_deps = false,
            deps_compat = false,
        )
    end

    # ==================================================================
    # Version and package metadata
    # ==================================================================
    @testset "Version and metadata" begin
        @test Glenn.__version__ isa String
        @test length(Glenn.__version__) > 0
        @test Glenn.__author__ isa String
        @test length(Glenn.__author__) > 0
    end

    # ==================================================================
    # Module exports
    # ==================================================================
    @testset "Module exports" begin
        @test isdefined(Glenn, :Calculator)
        @test isdefined(Glenn, :ThermoDB)
        @test isdefined(Glenn, :ThermoDBBuilder)
        @test isdefined(Glenn, :ThermoProperties)
        @test isdefined(Glenn, :SpeciesInfo)
        @test isdefined(Glenn, :NASACoefficients)
        @test isdefined(Glenn, :IntervalData)
        @test isdefined(Glenn, :DatabaseStats)
        @test isdefined(Glenn, :R_UNIVERSAL)
        @test isdefined(Glenn, :R_GLENN)
        @test isdefined(Glenn, :get_gas_constant_ref)
        @test isdefined(Glenn, :migrate_metadata!)
        @test isdefined(Glenn, :calculate_properties)
        @test isdefined(Glenn, :calculate_cp)
        @test isdefined(Glenn, :calculate_h)
        @test isdefined(Glenn, :calculate_s)
        @test isdefined(Glenn, :find_species)
        @test isdefined(Glenn, :get_statistics)
        @test isdefined(Glenn, :cli_main)
        @test isdefined(Glenn, :default_inp_path)
    end

    # ==================================================================
    # Exception types
    # ==================================================================
    @testset "Exception types" begin
        @test ThermoCalcError <: Exception
        @test DatabaseNotConnectedError <: Exception
        @test SpeciesNotFoundError <: Exception
        @test TemperatureOutOfRangeError <: Exception

        e = ThermoCalcError("test")
        @test e.msg == "test"
        @test sprint(showerror, e) == "ThermoCalcError: test"

        e2 = DatabaseNotConnectedError()
        @test occursin("Calculation attempted", e2.msg)

        e3 = SpeciesNotFoundError(42)
        @test e3.species_id == 42
        @test occursin("42", e3.msg)

        e4 = TemperatureOutOfRangeError(500.0, "CH4")
        @test e4.temperature == 500.0
        @test e4.species_name == "CH4"
    end

    # ==================================================================
    # Constants
    # ==================================================================
    @testset "Physical constants" begin
        @test Glenn.R_UNIVERSAL ≈ 8.31446261815324
        @test Glenn.R_GLENN == 8.314510
        @test 8.0 < Glenn.R_UNIVERSAL < 9.0
        @test 8.0 < Glenn.R_GLENN < 9.0
        @test isapprox(Glenn.R_UNIVERSAL, 8.31446261815324, rtol = 1e-15)
    end

    # ==================================================================
    # v0.5.0 Phase 1 — exception hierarchy and models
    # ==================================================================
    @testset "Exception hierarchy" begin
        # Every package error must be catchable through the abstract base.
        @test Glenn.ThermoCalcError isa Type
        @test Glenn.DatabaseNotConnectedError <: Glenn.ThermoCalcError
        @test Glenn.SpeciesNotFoundError <: Glenn.ThermoCalcError
        @test Glenn.TemperatureOutOfRangeError <: Glenn.ThermoCalcError
        @test Glenn.CompositionError <: Glenn.ThermoCalcError
        @test Glenn.ThermoError <: Glenn.ThermoCalcError
        @test Glenn.ThermoCalcError <: Exception

        # The concrete errors are themselves Exception subtypes.
        for E in (
            Glenn.DatabaseNotConnectedError,
            Glenn.SpeciesNotFoundError,
            Glenn.TemperatureOutOfRangeError,
            Glenn.CompositionError,
        )
            @test E <: Exception
        end

        # Legacy constructor still works and yields a generic ThermoError.
        generic = Glenn.ThermoCalcError("boom")
        @test generic isa Glenn.ThermoError
        @test generic.msg == "boom"
        @test sprint(showerror, generic) == "ThermoCalcError: boom"

        # Cold trap by the abstract type.
        @test_throws Glenn.ThermoCalcError throw(Glenn.CompositionError("bad"))

        # Bounds are carried when known and surfaced in the message.
        no_bounds = Glenn.TemperatureOutOfRangeError(7000.0, "N2")
        @test no_bounds.temp_bounds === nothing
        @test occursin("7000.0", no_bounds.msg)
        @test occursin("N2", no_bounds.msg)

        with_bounds = Glenn.TemperatureOutOfRangeError(7000.0, "N2", (200.0, 6000.0))
        @test with_bounds.temp_bounds == (200.0, 6000.0)
        @test occursin("valid range", with_bounds.msg)

        @test sprint(showerror, Glenn.CompositionError("oops")) == "CompositionError: oops"
    end

    @testset "Mixture validation" begin
        # Accepted input shapes.
        @test Glenn.Mixture(((1, 0.79), (2, 0.21))).species ==
              [(1, 0.79), (2, 0.21)]
        @test Glenn.Mixture([(1, 0.5), (2, 0.5)]).species == [(1, 0.5), (2, 0.5)]

        valid = Glenn.Mixture(((1, 0.79), (2, 0.21)))
        @test Glenn.validate(valid) === nothing

        # Single species at x = 1.0 is valid.
        @test Glenn.validate(Glenn.Mixture(((1, 1.0),))) === nothing

        # Invalid compositions.
        @test_throws Glenn.CompositionError Glenn.validate(Glenn.Mixture(()))
        @test_throws Glenn.CompositionError Glenn.validate(
            Glenn.Mixture(((1, 0.5), (1, 0.5))),
        )
        @test_throws Glenn.CompositionError Glenn.validate(
            Glenn.Mixture(((1, 1.5), (2, -0.5))),
        )
        @test_throws Glenn.CompositionError Glenn.validate(
            Glenn.Mixture(((1, 0.5), (2, 0.49))),
        )

        # Tolerance is configurable.
        @test Glenn.validate(Glenn.Mixture(((1, 0.5), (2, 0.4999))); tol = 1e-3) === nothing
    end

    @testset "MixedProperties struct" begin
        mix = Glenn.MixedProperties(
            1000.0,
            1100.0,
            30000.0,
            200.0,
            0.0288,
            38194.4,
            1041666.7,
            6944.4,
        )
        @test mix.temperature == 1000.0
        @test mix.cp_molar == 1100.0
        @test mix.molar_mass == 0.0288
        @test mix.cp_mass == 38194.4
    end

    @testset "R compatibility alias" begin
        @test Glenn.R == Glenn.R_UNIVERSAL
        # Deliberately not exported: `R` is a very common local variable name.
        @test !(:R in names(Glenn))
        @test :R in names(Glenn; all = true)
    end

    # ==================================================================
    # Database queries (disk-based)
    # ==================================================================
    mem_db = setup_test_db()
    db_file = "test_thermo.db"
    disk_db = copy_to_disk(mem_db, db_file)
    SQLite.close(mem_db)
    SQLite.close(disk_db)

    tdb = Glenn.ThermoDatabase.ThermoDB(db_file)

    @testset "Reference gas constant" begin
        # Legacy DB (no metadata table) → fallback to R_UNIVERSAL
        @test Glenn.get_gas_constant_ref(tdb.db) == Glenn.R_UNIVERSAL

        # Migrate: add metadata table + gas_constant_ref = R_GLENN
        Glenn.migrate_metadata!(tdb.db)
        @test Glenn.get_gas_constant_ref(tdb.db) ≈ 8.314510 atol = 1e-12

        # Full-precision constants
        @test Glenn.R_GLENN == 8.314510
        @test Glenn.R_UNIVERSAL == 8.31446261815324
    end

    @testset "ThermoDB - Statistics" begin
        stats = Glenn.get_statistics(tdb)
        @test stats isa Glenn.DatabaseStats
        @test stats.total_species == 1
        @test stats.total_intervals == 2
        @test stats.total_coeff_sets == 2
        @test stats.species_by_phase["gas"] == 1
        @test stats.avg_molecular_weight ≈ 31.9988
    end

    @testset "ThermoDB - Find species" begin
        results = Glenn.find_species(tdb, "O2")
        @test length(results) == 1
        @test results[1].name == "O2"
        @test results[1].phase == "gas"
        @test results[1].molecular_weight ≈ 31.9988

        # Nonexistent species
        results = Glenn.find_species(tdb, "XYZ123")
        @test length(results) == 0
    end

    @testset "ThermoDB - Get species data" begin
        data = Glenn.get_species_data(tdb, 1)
        @test data !== nothing
        @test data["name"] == "O2"
        @test length(data["intervals"]) == 2
        @test data["intervals"][1].temp_min == 200.0
        @test data["intervals"][1].temp_max == 1000.0

        # v0.5.0: get_species_data returns a typed SpeciesData
        @test data isa Glenn.SpeciesData
        @test data.name == "O2"
        @test data.phase == "gas"
        @test data.molecular_weight ≈ 31.9988
        @test data.num_intervals == 2
        @test length(data.intervals) == 2
        @test data.intervals[1] isa Glenn.IntervalData
        @test data.intervals[1].coefficients isa Glenn.NASACoefficients

        # Legacy dict-style access is preserved for backwards compatibility.
        @test data["phase"] == data.phase
        @test data["intervals"] === data.intervals
        @test Set(keys(data)) == Set((
            "id",
            "name",
            "formula",
            "comments",
            "reference_code",
            "phase",
            "molecular_weight",
            "heat_of_formation_298K",
            "num_intervals",
            "intervals",
        ))
        @test_throws KeyError data["nope"]

        # to_dict reproduces the pre-0.5.0 return shape.
        as_dict = Glenn.to_dict(data)
        @test as_dict isa Dict{String, Any}
        @test as_dict["name"] == "O2"
        @test as_dict["intervals"] === data.intervals

        # Nonexistent species
        @test Glenn.get_species_data(tdb, 99999) === nothing
    end

    @testset "ThermoDB - Species for temperature" begin
        interval = Glenn.get_species_for_temperature(tdb, 1, 300.0)
        @test interval !== nothing
        @test interval.temp_min <= 300.0 <= interval.temp_max

        interval = Glenn.get_species_for_temperature(tdb, 1, 100.0)
        @test interval === nothing

        interval = Glenn.get_species_for_temperature(tdb, 1, 5000.0)
        @test interval !== nothing
        @test interval.temp_min <= 5000.0 <= interval.temp_max
    end

    @testset "ThermoDB - Pagination" begin
        species, total_pages = Glenn.list_species_page(tdb, page = 1, page_size = 10)
        @test length(species) == 1
        @test total_pages == 1
        @test species[1].name == "O2"

        # Page beyond available data
        species, total_pages = Glenn.list_species_page(tdb, page = 2, page_size = 10)
        @test length(species) == 0
        @test total_pages == 1
    end

    @testset "ThermoDB - List all species" begin
        all_species = Glenn.list_all_species(tdb)
        @test length(all_species) == 1
        @test all_species[1].name == "O2"
    end

    @testset "ThermoDB - Get species info (lightweight)" begin
        info = Glenn.get_species_info(tdb, 1)
        @test info !== nothing
        @test info.name == "O2"
        @test info.phase == "gas"
        @test info.molecular_weight ≈ 31.9988

        @test Glenn.get_species_info(tdb, 99999) === nothing
    end

    Glenn.ThermoDatabase.close(tdb)

    # ==================================================================
    # NASA-7 polynomial calculations
    # ==================================================================
    @testset "NASA-7 polynomials" begin
        coeffs = Dict(
            "a1" => -3.42556342e+04,
            "a2" => 4.84700097e+02,
            "a3" => 1.11901096e+00,
            "a4" => 4.29388924e-03,
            "a5" => -6.83630052e-07,
            "a6" => -2.02337270e-09,
            "a7" => 1.03904002e-12,
            "b1" => -3.39145487e+03,
            "b2" => 1.84969947e+01,
        )
        ncoeffs = Glenn.NASACoefficients(coeffs)  # typed version

        @testset "Cp/R at 298.15K" begin
            cp_r = Glenn.calculate_cp(ncoeffs, 298.15)
            @test cp_r ≈ 3.53 atol = 0.1
            @test isfinite(cp_r)
            @test cp_r > 0
        end

        @testset "Cp/R at 1000K" begin
            cp_r = Glenn.calculate_cp(ncoeffs, 1000.0)
            @test 3.5 < cp_r < 5.0
        end

        @testset "H/RT and S/R are finite and positive entropy" begin
            for T in [300.0, 500.0, 800.0, 1000.0]
                h_rt = Glenn.calculate_h(ncoeffs, T)
                s_r = Glenn.calculate_s(ncoeffs, T)
                @test isfinite(h_rt)
                @test isfinite(s_r)
                @test s_r > 0
            end
        end

        @testset "Standalone H/RT calculation" begin
            h_rt = Glenn.calculate_h(ncoeffs, 298.15)
            @test isfinite(h_rt)
        end

        @testset "Standalone S/R calculation" begin
            s_r = Glenn.calculate_s(ncoeffs, 298.15)
            @test isfinite(s_r)
            @test s_r > 0
        end

        @testset "Partial coefficients" begin
            partial = Dict("a1" => 0.0, "a3" => 3.5)
            ncoeffs_partial = Glenn.NASACoefficients(partial)
            cp_r = Glenn.calculate_cp(ncoeffs_partial, 300.0)
            @test cp_r ≈ 3.5
        end

        @testset "Deprecated Dict methods still work" begin
            coeffs_dict = Dict("a1" => 0.0, "a3" => 3.5)
            # Deprecated path — emits a warning but still returns the correct value
            cp_r = Glenn.calculate_cp(coeffs_dict, 300.0)
            @test cp_r ≈ 3.5
            h_rt = Glenn.calculate_h(coeffs_dict, 300.0)
            @test isfinite(h_rt)
            s_r = Glenn.calculate_s(coeffs_dict, 300.0)
            @test isfinite(s_r)
        end

        @testset "Polynomial thermodynamic consistency" begin
            # Verify: d(H/RT)/dT = (Cp/R - H/RT) / T
            T = 500.0
            eps = 1e-4
            cp_r = Glenn.calculate_cp(ncoeffs, T)
            h_rt = Glenn.calculate_h(ncoeffs, T)
            h_rt_plus = Glenn.calculate_h(ncoeffs, T + eps)
            h_rt_minus = Glenn.calculate_h(ncoeffs, T - eps)
            dhrt_dt = (h_rt_plus - h_rt_minus) / (2 * eps)
            expected = (cp_r - h_rt) / T
            @test isapprox(dhrt_dt, expected, rtol = 1e-5)
        end
    end

    # ==================================================================
    # Calculator (high-level API)
    # ==================================================================
    @testset "Calculator - High-level API" begin
        calc = Glenn.Calculator(db_file)

        @testset "Available species" begin
            species = Glenn.get_available_species(calc, "O2")
            @test length(species) == 1
            @test species[1].name == "O2"

            # All species (no filter)
            all_species = Glenn.get_available_species(calc)
            @test length(all_species) == 1
        end

        @testset "Properties at 298.15K" begin
            props = Glenn.calculate_properties(calc, 1, 298.15)
            @test props.species_name == "O2"
            @test props.phase == "gas"
            @test props.cp ≈ 29.4 atol = 1.0
            @test 150.0 < props.s < 250.0
            @test props.temp_min == 200.0
            @test props.temp_max == 1000.0
            @test isfinite(props.cp)
            @test isfinite(props.h_relative)
            @test isfinite(props.s)
        end

        @testset "Properties at 500K" begin
            props = Glenn.calculate_properties(calc, 1, 500.0)
            @test props.cp > 0
            @test isfinite(props.cp)

            # H should increase with T
            props_298 = Glenn.calculate_properties(calc, 1, 298.15)
            @test props.h_relative > props_298.h_relative
        end

        @testset "Properties at 1000K" begin
            props = Glenn.calculate_properties(calc, 1, 1000.0)
            @test props.cp > 20.0
            @test props.h_relative > 0.0
            @test props.s > 0.0
        end

        @testset "Properties out of range" begin
            # Below valid range
            @test_throws Glenn.ThermoCalcError Glenn.calculate_properties(calc, 1, 100.0)

            # Above valid range
            @test_throws Glenn.ThermoCalcError Glenn.calculate_properties(calc, 1, 10000.0)
        end

        @testset "Invalid species ID" begin
            @test_throws Glenn.ThermoCalcError Glenn.calculate_properties(
                calc,
                99999,
                300.0,
            )
        end

        @testset "Formation enthalpy" begin
            h_f = Glenn.calculate_formation_enthalpy(calc, 1)
            @test h_f ≈ 0.0 atol = 1.0

            # Nonexistent species
            @test_throws Glenn.ThermoCalcError Glenn.calculate_formation_enthalpy(
                calc,
                99999,
            )
        end

        @testset "Enthalpy change" begin
            delta_h = Glenn.calculate_enthalpy_change(calc, 1, 298.15, 500.0)
            @test delta_h > 0.0
            @test delta_h < 1e6  # Reasonable for ~200K ΔT

            # Zero delta (same temperature)
            delta_h_zero = Glenn.calculate_enthalpy_change(calc, 1, 400.0, 400.0)
            @test isapprox(delta_h_zero, 0.0, atol = 1e-6)
        end

        @testset "Properties range (vectorized)" begin
            results = Glenn.get_properties_range(calc, 1, [298.15, 500.0, 800.0])
            @test length(results) == 3
            @test all(r -> r.cp > 0, results)

            # Cp should increase with temperature
            @test results[2].cp > results[1].cp
        end

        Glenn.close(calc)
    end

    # ==================================================================
    # Context manager (do-block)
    # ==================================================================
    @testset "Context manager" begin
        connected_in_block = false

        Calculator(db_file) do calc
            connected_in_block = true
            species = Glenn.get_available_species(calc, "O2")
            @test length(species) == 1
            @test species[1].name == "O2"
        end

        @test connected_in_block
    end

    # ==================================================================
    # Calculator - Phase 2 API (derivatives, mixtures, range, bounds)
    # ==================================================================
    @testset "Calculator - Phase 2 API" begin
        calc = Glenn.Calculator(db_file)

        @testset "Temperature bounds" begin
            # O2 fixture: intervals 200-1000 and 1000-6000
            @test Glenn.get_temperature_bounds(calc.db, 1) == (200.0, 6000.0)
            @test Glenn.get_temperature_bounds(calc.db, 99999) === nothing

            err = try
                Glenn.calculate_properties(calc, 1, 7000.0)
                nothing
            catch e
                e
            end
            @test err isa Glenn.TemperatureOutOfRangeError
            @test err.temp_bounds == (200.0, 6000.0)
            @test occursin("valid range", err.msg)
        end

        @testset "calculate_properties_range" begin
            # Input order is preserved and valid points are kept.
            props = Glenn.calculate_properties_range(calc, 1, [500.0, 298.15, 1500.0])
            @test [p.temperature for p in props] == [500.0, 298.15, 1500.0]

            # Non-strict skips out-of-range temperatures.
            props = Glenn.calculate_properties_range(calc, 1, [100.0, 500.0, 9000.0])
            @test [p.temperature for p in props] == [500.0]

            # Strict raises on the first out-of-range temperature.
            @test_throws Glenn.TemperatureOutOfRangeError Glenn.calculate_properties_range(
                calc,
                1,
                [500.0, 9000.0];
                strict = true,
            )

            # Typed results match the scalar path exactly.
            scalar = Glenn.calculate_properties(calc, 1, 500.0)
            @test props[1] == scalar

            # Deprecated 0.4.x alias still returns the same results.
            @test Glenn.get_properties_range(calc, 1, [500.0, 1500.0]) ==
                  Glenn.calculate_properties_range(calc, 1, [500.0, 1500.0])
        end

        @testset "h_sensible_to" begin
            @test Glenn.h_sensible_to(calc, 1, 1000.0) ≈
                  Glenn.calculate_enthalpy_change(calc, 1, 298.15, 1000.0)
            # Default reference is 298.15 K.
            @test Glenn.h_sensible_to(calc, 1, 1000.0) ≈
                  Glenn.h_sensible_to(calc, 1, 1000.0, 298.15)
            # Custom reference temperature.
            @test Glenn.h_sensible_to(calc, 1, 1000.0, 300.0) ≈
                  Glenn.calculate_enthalpy_change(calc, 1, 300.0, 1000.0)
            @test Glenn.h_sensible_to(calc, 1, 500.0, 500.0) ≈ 0.0 atol = 1e-9
        end

        @testset "dcp_dt" begin
            T = 500.0
            analytic = Glenn.dcp_dt(calc, 1, T)
            eps = 1.0e-3
            cp_plus = Glenn.calculate_properties(calc, 1, T + eps).cp
            cp_minus = Glenn.calculate_properties(calc, 1, T - eps).cp
            @test analytic ≈ (cp_plus - cp_minus) / (2 * eps) rtol = 1e-3
            @test isfinite(analytic)

            @test_throws Glenn.SpeciesNotFoundError Glenn.dcp_dt(calc, 99999, T)
            @test_throws Glenn.TemperatureOutOfRangeError Glenn.dcp_dt(calc, 1, 9000.0)
        end

        @testset "gamma" begin
            # Not exported, to avoid clashing with SpecialFunctions.gamma, but
            # reachable as Glenn.gamma.
            @test !(:gamma in names(Glenn))
            @test isdefined(Glenn, :gamma)
            @test Glenn.gamma isa Function

            T = 500.0
            cp = Glenn.calculate_properties(calc, 1, T).cp
            @test Glenn.gamma(calc, 1, T) ≈ cp / (cp - calc.R_ref)
            # Diatomic ideal gas: Cp/Cv slightly above 7/5 at moderate T.
            @test 1.2 < Glenn.gamma(calc, 1, T) < 1.5

            @test_throws Glenn.SpeciesNotFoundError Glenn.gamma(calc, 99999, T)
        end

        Glenn.close(calc)

        @testset "mixture_properties" begin
            inp_mix = "test_mixture_thermo.inp"
            db_mix = "test_mixture_thermo.db"
            try
                write(
                    inp_mix,
                    make_thermo_inp([
                        ("AA", "200.0", "3000.0", "28.0000"),
                        ("BB", "200.0", "6000.0", "32.0000"),
                    ]),
                )
                Glenn.build_database(inp_mix, db_mix)

                calc2 = Glenn.Calculator(db_mix)
                aa = only(Glenn.get_available_species(calc2, "AA", exact_match = true))
                bb = only(Glenn.get_available_species(calc2, "BB", exact_match = true))

                mix = Glenn.mixture_properties(
                    calc2,
                    Glenn.Mixture(((aa.id, 0.5), (bb.id, 0.5))),
                    1000.0,
                )

                # Mole-fraction-weighted mean molar mass, in kg/mol.
                @test mix.molar_mass ≈ (0.5 * 28.0 + 0.5 * 32.0) / 1000.0
                @test mix.temperature == 1000.0

                # Mass basis is consistent with the molar basis.
                @test mix.cp_mass ≈ mix.cp_molar / mix.molar_mass
                @test mix.h_mass ≈ mix.h_molar / mix.molar_mass
                @test mix.s_mass ≈ mix.s_molar / mix.molar_mass

                # A single-species mixture reproduces the pure-species values.
                pure_aa = Glenn.calculate_properties(calc2, aa.id, 1000.0)
                single =
                    Glenn.mixture_properties(calc2, Glenn.Mixture(((aa.id, 1.0),)), 1000.0)
                @test single.cp_molar ≈ pure_aa.cp
                @test single.h_molar ≈ pure_aa.h_relative
                @test single.s_molar ≈ pure_aa.s
                @test single.molar_mass ≈ 0.028

                # Invalid compositions are rejected.
                @test_throws Glenn.CompositionError Glenn.mixture_properties(
                    calc2,
                    Glenn.Mixture(((aa.id, 0.5), (aa.id, 0.5))),
                    1000.0,
                )
                @test_throws Glenn.CompositionError Glenn.mixture_properties(
                    calc2,
                    Glenn.Mixture(((aa.id, 0.5), (bb.id, 0.4))),
                    1000.0,
                )
                @test_throws Glenn.SpeciesNotFoundError Glenn.mixture_properties(
                    calc2,
                    Glenn.Mixture(((99999, 1.0),)),
                    1000.0,
                )

                # BB is valid up to 6000 K, AA only up to 3000 K.
                @test_throws Glenn.TemperatureOutOfRangeError Glenn.mixture_properties(
                    calc2,
                    Glenn.Mixture(((aa.id, 0.5), (bb.id, 0.5))),
                    5000.0;
                    strict = true,
                )

                # Non-strict skips AA and renormalises BB to x = 1.
                partial = Glenn.mixture_properties(
                    calc2,
                    Glenn.Mixture(((aa.id, 0.5), (bb.id, 0.5))),
                    5000.0;
                    strict = false,
                )
                pure_bb = Glenn.calculate_properties(calc2, bb.id, 5000.0)
                @test partial.cp_molar ≈ pure_bb.cp
                @test partial.molar_mass ≈ 0.032

                Glenn.close(calc2)
            finally
                rm(inp_mix, force = true)
                rm(db_mix, force = true)
            end
        end
    end

    # ==================================================================
    # Builder - Parsing utilities
    # ==================================================================
    @testset "Builder - Parse utilities" begin
        @testset "parse_float - normal" begin
            @test Glenn.ThermoBuilder.parse_float("3.14159") ≈ 3.14159
        end

        @testset "parse_float - FORTRAN D notation" begin
            @test Glenn.ThermoBuilder.parse_float("1.234D+02") ≈ 123.4
            @test Glenn.ThermoBuilder.parse_float("5.678D-01") ≈ 0.5678
            @test Glenn.ThermoBuilder.parse_float("1.0d+00") ≈ 1.0
        end

        @testset "parse_float - empty/invalid" begin
            @test Glenn.ThermoBuilder.parse_float("") === nothing
            @test Glenn.ThermoBuilder.parse_float("   ") === nothing
        end

        @testset "is_coefficient_line" begin
            @test Glenn.ThermoBuilder.is_coefficient_line(" 1.234D+05 5.678D-02")
            @test Glenn.ThermoBuilder.is_coefficient_line(" 1.0D0 2.0D+01")
            @test !Glenn.ThermoBuilder.is_coefficient_line("O2")
            @test !Glenn.ThermoBuilder.is_coefficient_line("200.000  1000.000")
        end

        @testset "is_temperature_line" begin
            @test Glenn.ThermoBuilder.is_temperature_line(" 2.0000E+02 1.0000E+03")
            @test !Glenn.ThermoBuilder.is_temperature_line(" 1.0000E+03 2.0000E+02")  # T1 > T2
            @test !Glenn.ThermoBuilder.is_temperature_line("short")
            @test !Glenn.ThermoBuilder.is_temperature_line(" 5.0000E+02 5.0000E+02")  # equal
        end

        @testset "parse_species_record" begin
            name, comments = Glenn.ThermoBuilder.parse_species_record(
                "O2              Ref-1 O2 gas           ",
            )
            @test name == "O2"
            @test occursin("O2", comments)
        end

        @testset "parse_general_info_record" begin
            info = Glenn.ThermoBuilder.parse_general_info_record(
                " 1  g 2/99O   2   1   2    0    00G200.000 3500.000 1000.000    1",
            )
            @test info["num_intervals"] == 1
            @test info["phase"] == "gas"
        end

        @testset "parse_temp_interval_record" begin
            data = Glenn.ThermoBuilder.parse_temp_interval_record(
                " 2.0000E+02 1.0000E+03 0.0000E+00 0.0000E+00 0.0000E+00 0" *
                "               0.0000E+00 0.0000E+00 8.6800E+03",
            )
            @test data["temp_min"] ≈ 200.0
            @test data["temp_max"] ≈ 1000.0
        end

        @testset "parse_coefficients_record" begin
            # Use fixed-width FORTRAN 16-character fields via lpad
            fields4 = lpad.(
                [
                    "3.21225000E+00",
                    "1.12749000E-03",
                    "-5.75615000E-07",
                    "1.31388000E-09",
                    "-8.76854000E-13",
                ],
                16,
            )
            line4 = join(fields4)
            fields5 = lpad.(
                [
                    "-1.00524900E+03",
                    "6.03473800E+00",
                    "0.00000000E+00",
                    "3.69757819E+00",
                    "6.13519689E-01",
                ],
                16,
            )
            line5 = join(fields5)
            coeffs = Glenn.ThermoBuilder.parse_coefficients_record([line4, line5])
            @test coeffs["a1"] ≈ 3.21225000 rtol = 1e-6
            @test coeffs["a2"] ≈ 1.12749000e-03 rtol = 1e-6
            @test coeffs["a3"] ≈ -5.75615000e-07 rtol = 1e-6
            @test coeffs["a6"] ≈ -1.00524900e03 rtol = 1e-6
            @test coeffs["b1"] ≈ 3.69757819 rtol = 1e-6
            @test coeffs["b2"] ≈ 6.13519689e-01 rtol = 1e-6
        end
    end

    # ==================================================================
    # Builder - Database build (smoke test)
    # ==================================================================
    @testset "Builder - Build from thermo.inp" begin
        # Create a minimal thermo.inp with properly formatted fixed-width fields
        # RECORD 1: species name (cols 1-16), comments (cols 19-80)
        rec1 = rpad("O2", 16) * "  " * rpad("Ref-1 O2 gas", 62)
        # RECORD 2: num_intervals(1:2), ref_code(4:9), phase(51:52), MW(53:65), Hf(66:80)
        rec2 =
            " 1" * " " * rpad("g 2/99", 43) * " 0" * rpad("31.9988", 14) * rpad("0.0", 15)
        rec2 = rec2[1:min(end, 80)]
        rec2 = rpad(rec2, 80)
        # RECORD 3: temp_min(1:11), temp_max(12:22), h_298(66:80)
        rec3 = rpad("200.0", 11) * rpad("1000.0", 11) * rpad("", 44) * rpad("8680.0", 15)
        rec3 = rec3[1:min(end, 80)]
        rec3 = rpad(rec3, 80)
        # RECORD 4-5: 16-char FORTRAN D-format fields
        vals4 = [
            "3.21225000D+00",
            "1.12749000D-03",
            "-5.75615000D-07",
            "1.31388000D-09",
            "-8.76854000D-13",
        ]
        rec4 = join(lpad.(vals4, 16))
        vals5 = [
            "-1.00524900D+03",
            "6.03473800D+00",
            "0.00000000D+00",
            "3.69757819D+00",
            "6.13519689D-01",
        ]
        rec5 = join(lpad.(vals5, 16))

        inp_content =
            join(
                [
                    "THERMO",
                    "   300.000   1000.000   5000.000",
                    # Stray coefficient line before any species header: the
                    # state machine must skip it instead of creating a bogus
                    # species named after a FORTRAN number.
                    "-1.302004763D+06 5.407120940D+02-1.596697810D+00 1.635207120D-03",
                    rec1,
                    rec2,
                    rec3,
                    rec4,
                    rec5,
                ],
                "\n",
            ) * "\n"

        inp_path = "test_minimal_thermo.inp"
        db_path = "test_minimal_thermo.db"

        try
            write(inp_path, inp_content)

            Glenn.build_database(inp_path, db_path)

            @test isfile(db_path)
            @test filesize(db_path) > 0

            # Verify data
            tdb = Glenn.ThermoDB(db_path)
            stats = Glenn.get_statistics(tdb)
            @test stats.total_species == 1
            @test stats.total_intervals >= 1

            # No species name may look like a FORTRAN coefficient token.
            @test all(
                s -> !occursin(r"\dD[+-]\d", s.name),
                Glenn.list_all_species(tdb),
            )

            # The dataset reference constant is written inside the transaction.
            @test Glenn.get_gas_constant_ref(tdb) ≈ Glenn.R_GLENN
            Glenn.ThermoDatabase.close(tdb)
        finally
            rm(inp_path, force = true)
            rm(db_path, force = true)
        end
    end

    # ==================================================================
    # Builder - Species header detection (v0.5.0 phase 0)
    # ==================================================================
    @testset "Builder - Species header detection" begin
        # Genuine species records
        @test Glenn.ThermoBuilder.is_species_header(
            "O2              Ref-1 O2 gas           ",
        )
        @test Glenn.ThermoBuilder.is_species_header(
            "Cr(cr)            Below lambda trans. Ref-Elm.",
        )
        @test Glenn.ThermoBuilder.is_species_header(
            "C2H5OH(L)         Gurvich,1989 pt1 p210 pt2 p201.",
        )

        # Coefficient lines fit inside the species-name field and were
        # historically misparsed as species headers.
        stray = "-1.302004763D+06 5.407120940D+02-1.596697810D+00"
        @test Glenn.ThermoBuilder.is_coefficient_line(stray)
        @test !Glenn.ThermoBuilder.is_species_header(stray)
        @test !Glenn.ThermoBuilder.is_species_header(" 3.21225000D+00 1.12749000D-03")

        # Temperature records are not species headers.
        @test !Glenn.ThermoBuilder.is_species_header(" 2.0000E+02 1.0000E+03")

        # Blank / multi-token names are rejected.
        @test !Glenn.ThermoBuilder.is_species_header("")
        @test !Glenn.ThermoBuilder.is_species_header("TOO  MANY TOKENS HERE")
    end

    # ==================================================================
    # CLI - Smoke tests
    # ==================================================================
    @testset "CLI - Smoke tests" begin
        @testset "CLI help" begin
            # Just verify it doesn't crash
            Glenn.cli_main(String[])  # should print help
            Glenn.cli_main(["-h"])
            Glenn.cli_main(["--help"])
            @test true  # No crash = pass
        end

        @testset "CLI query with test DB" begin
            # Redirect stdout to avoid cluttering test output
            original_stdout = stdout
            (rd, wr) = redirect_stdout()
            try
                Glenn.cli_main(["query", "-d", db_file, "-s", "O2"])
            finally
                redirect_stdout(original_stdout)
                close(wr)
                close(rd)
            end
            @test true  # No crash = pass
        end
    end

    # ==================================================================
    # Builder - Merged duplicate records (v0.5.0 phase 0)
    # ==================================================================
    @testset "Builder - Merged duplicate records" begin
        inp_m = "test_merge_thermo.inp"
        db_m = "test_merge_thermo.db"

        try
            # Same species name, two adjacent ranges (the Cr(cr) pattern).
            write(
                inp_m,
                make_thermo_inp([("XX", "200.0", "1000.0"), ("XX", "1000.0", "2000.0")]),
            )
            Glenn.build_database(inp_m, db_m)

            tdb = Glenn.ThermoDB(db_m)
            stats = Glenn.get_statistics(tdb)
            @test stats.total_species == 1
            @test stats.total_intervals == 2

            info = only(Glenn.list_all_species(tdb))
            @test info.num_intervals == 2

            data = Glenn.get_species_data(tdb, info.id)
            @test [(iv.temp_min, iv.temp_max) for iv in data.intervals] ==
                  [(200.0, 1000.0), (1000.0, 2000.0)]
            Glenn.ThermoDatabase.close(tdb)

            # merge_duplicates=false keeps the reference (first-only) behaviour.
            rm(db_m; force = true)
            Glenn.build_database(inp_m, db_m; merge_duplicates = false)
            tdb = Glenn.ThermoDB(db_m)
            @test Glenn.get_statistics(tdb).total_intervals == 1
            Glenn.ThermoDatabase.close(tdb)

            # An exact duplicate range is skipped, never stored twice.
            rm(db_m; force = true)
            write(
                inp_m,
                make_thermo_inp([("YY", "200.0", "1000.0"), ("YY", "200.0", "1000.0")]),
            )
            Glenn.build_database(inp_m, db_m)
            tdb = Glenn.ThermoDB(db_m)
            @test Glenn.get_statistics(tdb).total_intervals == 1
            Glenn.ThermoDatabase.close(tdb)
        finally
            rm(inp_m, force = true)
            rm(db_m, force = true)
        end
    end

    # ==================================================================
    # Bundled database (dataset release gates)
    # ==================================================================
    @testset "Bundled database" begin
        db = Glenn.default_db_path()
        @test isfile(db)

        tdb = Glenn.ThermoDB(db)
        stats = Glenn.get_statistics(tdb)

        # Release gates for the canonical NASA Glenn/CEA dataset — keep in sync
        # with scripts/rebuild_database.jl.
        @test stats.total_species == 2035
        @test stats.total_intervals == 3795
        @test stats.total_coeff_sets == 3795

        # The parser must never store FORTRAN tokens as species names.
        names = [s.name for s in Glenn.list_all_species(tdb)]
        @test isempty(filter(n -> occursin(r"\dD[+-]\d", n), names))

        # Species recovered once the parser resynchronised correctly.
        for name in ("C2H5OH(L)", "C6H6(L)", "CLO3F", "H2O2(L)", "JP-10(g)")
            @test !isempty(Glenn.find_species(tdb, name; exact_match = true))
        end

        # Phase-transition records are merged, so condensed substances keep
        # their complete temperature range (Cr(cr) below/above lambda).
        cr = only(Glenn.find_species(tdb, "Cr(cr)"; exact_match = true))
        cr_data = Glenn.get_species_data(tdb, cr.id)
        @test length(cr_data.intervals) == 3
        @test cr_data.num_intervals == 3
        @test cr_data.intervals[1].temp_min == 200.0
        @test cr_data.intervals[end].temp_max == 2130.0

        # Dataset reference constant survives a rebuild.
        @test Glenn.get_gas_constant_ref(tdb) ≈ Glenn.R_GLENN

        # The shipped dataset passes every integrity check.
        vreport = Glenn.validate_database(tdb)
        @test vreport.valid
        @test isempty(vreport.errors)
        @test isempty(vreport.warnings)
        @test vreport.counts["total_species"] == 2035

        Glenn.ThermoDatabase.close(tdb)
    end

    # ==================================================================
    # Database validation (v0.5.0 phase 3)
    # ==================================================================
    @testset "validate_database" begin
        inp_v = "test_validate_thermo.inp"
        db_v = "test_validate_thermo.db"

        function mutate(sql)
            db = SQLite.DB(db_v)
            try
                SQLite.execute(db, sql)
            finally
                SQLite.close(db)
            end
            return nothing
        end

        function rebuild_and_validate(; sql = nothing)
            rm(db_v, force = true)
            Glenn.build_database(inp_v, db_v)
            sql === nothing || mutate(sql)
            tdb = Glenn.ThermoDB(db_v)
            try
                return Glenn.validate_database(tdb)
            finally
                close(tdb)
            end
        end

        try
            write(inp_v, make_thermo_inp([("AA", "200.0", "3000.0", "28.0000")]))

            report = rebuild_and_validate()
            @test report isa Glenn.ValidationReport
            @test report.valid
            @test isempty(report.errors)
            @test isempty(report.warnings)
            @test report.counts["total_species"] == 1
            @test report.counts["total_intervals"] == 1
            @test report.counts["total_coeff_sets"] == 1
            @test sprint(show, report) ==
                  "ValidationReport(valid=true, errors=0, warnings=0)"

            # num_intervals disagreeing with the stored rows
            r = rebuild_and_validate(; sql = "UPDATE species SET num_intervals = 5")
            @test !r.valid
            @test any(e -> occursin("num_intervals", e), r.errors)

            # Unordered bounds
            r = rebuild_and_validate(
                ;
                sql = "UPDATE temperature_intervals SET temp_min = 5000.0",
            )
            @test !r.valid
            @test any(e -> occursin("bounds", e), r.errors)

            # Incomplete coefficient set
            r = rebuild_and_validate(; sql = "UPDATE coefficients SET a1 = NULL")
            @test !r.valid
            @test any(e -> occursin("NULL", e), r.errors)

            # A FORTRAN token must never be accepted as a species name
            r = rebuild_and_validate(
                ;
                sql = "UPDATE species SET name = '-1.302004763D+06'",
            )
            @test !r.valid
            @test any(e -> occursin("FORTRAN", e), r.errors)

            # Orphan coefficient rows
            r = rebuild_and_validate(; sql = "DELETE FROM temperature_intervals")
            @test !r.valid
            @test any(e -> occursin("missing interval", e), r.errors)

            # Missing metadata is a warning, not an error
            r = rebuild_and_validate(; sql = "DELETE FROM metadata")
            @test r.valid
            @test any(w -> occursin("gas_constant_ref", w), r.warnings)

            # Missing required table is fatal and reports empty counts
            rm(db_v, force = true)
            raw = SQLite.DB(db_v)
            try
                SQLite.execute(
                    raw,
                    "CREATE TABLE species (id INTEGER PRIMARY KEY, name TEXT)",
                )
            finally
                SQLite.close(raw)
            end
            tdb = Glenn.ThermoDB(db_v)
            r = try
                Glenn.validate_database(tdb)
            finally
                close(tdb)
            end
            @test !r.valid
            @test any(e -> occursin("missing required table", e), r.errors)
            @test isempty(r.counts)
        finally
            rm(inp_v, force = true)
            rm(db_v, force = true)
        end
    end

    # ==================================================================
    # Edge cases
    # ==================================================================
    @testset "Edge cases" begin
        @testset "Database not found" begin
            @test_throws ErrorException Glenn.ThermoDatabase.ThermoDB("nonexistent.db")
        end

        @testset "_or_zero helper" begin
            @test Glenn.ThermoDatabase._or_zero(nothing) == 0.0
            @test Glenn.ThermoDatabase._or_zero(42.0) == 42.0
        end

        @testset "default_db_path and default_inp_path" begin
            p = Glenn.default_db_path()
            @test endswith(p, "thermo.db")
            p2 = Glenn.default_inp_path()
            @test endswith(p2, "thermo.inp")
            @test isfile(p2)  # bundled thermo.inp must exist
        end
    end

    # Cleanup
    rm(db_file, force = true)
end
