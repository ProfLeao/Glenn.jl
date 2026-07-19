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

    SQLite.execute(db, """
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
    """)

    SQLite.execute(db, """
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
    """)

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS coefficients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            interval_id INTEGER NOT NULL UNIQUE,
            a1 REAL, a2 REAL, a3 REAL, a4 REAL, a5 REAL,
            a6 REAL, a7 REAL,
            b1 REAL, b2 REAL,
            FOREIGN KEY (interval_id) REFERENCES temperature_intervals(id) ON DELETE CASCADE
        )
    """)

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS file_metadata (
            id INTEGER PRIMARY KEY,
            temp_min_global REAL,
            temp_500_K REAL,
            temp_1500_K REAL,
            temp_max_global REAL,
            reference_date TEXT,
            total_species INTEGER
        )
    """)

    # Insert O2 data (NIST-JANAF): 2 intervals (200-1000K, 1000-6000K)
    SQLite.execute(db, """
        INSERT INTO species (id, name, formula, comments, reference_code, phase,
                             molecular_weight, heat_of_formation_298K, num_intervals)
        VALUES (1, 'O2', 'O2', 'NIST-JANAF', 'j', 'gas', 31.9988, 0.0, 2)
    """)

    SQLite.execute(db, """
        INSERT INTO temperature_intervals (id, species_id, interval_number,
                                           temp_min, temp_max, h_298_to_0)
        VALUES (1, 1, 1, 200.0, 1000.0, 8680.0)
    """)

    # O2 low-temp coefficients (200-1000K)
    SQLite.execute(db, """
        INSERT INTO coefficients (id, interval_id,
            a1, a2, a3, a4, a5, a6, a7, b1, b2)
        VALUES (1, 1,
            -3.42556342e+04, 4.84700097e+02, 1.11901096e+00,
            4.29388924e-03, -6.83630052e-07, -2.02337270e-09,
            1.03904002e-12, -3.39145487e+03, 1.84969947e+01)
    """)

    SQLite.execute(db, """
        INSERT INTO temperature_intervals (id, species_id, interval_number,
                                           temp_min, temp_max, h_298_to_0)
        VALUES (2, 1, 2, 1000.0, 6000.0, 8680.0)
    """)

    # O2 high-temp coefficients (1000-6000K)
    SQLite.execute(db, """
        INSERT INTO coefficients (id, interval_id,
            a1, a2, a3, a4, a5, a6, a7, b1, b2)
        VALUES (2, 2,
            -1.03793902e+06, 2.34483028e+03, 1.81973204e+00,
            1.26784758e-03, -2.18806799e-07, 2.05371957e-11,
            -8.19346705e-16, -1.68901093e+04, 1.73871651e+01)
    """)

    SQLite.execute(db, """
        INSERT INTO file_metadata (id, temp_min_global, temp_500_K,
                                   temp_1500_K, temp_max_global, reference_date,
                                   total_species)
        VALUES (1, 200.0, 500.0, 1500.0, 6000.0, 'test', 1)
    """)

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
        SQLite.execute(disk_db,
            "INSERT INTO species VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", Tuple(row))
    end
    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM temperature_intervals")
        SQLite.execute(disk_db,
            "INSERT INTO temperature_intervals VALUES (?, ?, ?, ?, ?, ?)", Tuple(row))
    end
    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM coefficients")
        SQLite.execute(disk_db,
            "INSERT INTO coefficients VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", Tuple(row))
    end
    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM file_metadata")
        SQLite.execute(disk_db,
            "INSERT INTO file_metadata VALUES (?, ?, ?, ?, ?, ?, ?)", Tuple(row))
    end

    return disk_db
end

# ------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------
@testset "Glenn.jl" begin

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
        @test isdefined(Glenn, :R_UNIVERSAL)
        @test isdefined(Glenn, :calculate_properties)
        @test isdefined(Glenn, :calculate_cp)
        @test isdefined(Glenn, :calculate_h)
        @test isdefined(Glenn, :calculate_s)
        @test isdefined(Glenn, :find_species)
        @test isdefined(Glenn, :get_statistics)
        @test isdefined(Glenn, :parse_float)
        @test isdefined(Glenn, :is_coefficient_line)
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
        @test Glenn.R_UNIVERSAL ≈ 8.314462618
        @test 8.0 < Glenn.R_UNIVERSAL < 9.0
        @test isapprox(Glenn.R_UNIVERSAL, 8.314462618, rtol=1e-9)
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

    @testset "ThermoDB - Statistics" begin
        stats = Glenn.get_statistics(tdb)
        @test stats["total_species"] == 1
        @test stats["total_intervals"] == 2
        @test stats["total_coeff_sets"] == 2
        @test stats["species_by_phase"]["gas"] == 1
        @test stats["avg_molecular_weight"] ≈ 31.9988
    end

    @testset "ThermoDB - Find species" begin
        results = Glenn.find_species(tdb, "O2")
        @test length(results) == 1
        @test results[1]["name"] == "O2"
        @test results[1]["phase"] == "gas"
        @test results[1]["molecular_weight"] ≈ 31.9988

        # Nonexistent species
        results = Glenn.find_species(tdb, "XYZ123")
        @test length(results) == 0
    end

    @testset "ThermoDB - Get species data" begin
        data = Glenn.get_species_data(tdb, 1)
        @test data !== nothing
        @test data["name"] == "O2"
        @test length(data["intervals"]) == 2
        @test data["intervals"][1]["temp_min"] == 200.0
        @test data["intervals"][1]["temp_max"] == 1000.0

        # Nonexistent species
        @test Glenn.get_species_data(tdb, 99999) === nothing
    end

    @testset "ThermoDB - Species for temperature" begin
        interval = Glenn.get_species_for_temperature(tdb, 1, 300.0)
        @test interval !== nothing
        @test interval["temp_min"] <= 300.0 <= interval["temp_max"]

        interval = Glenn.get_species_for_temperature(tdb, 1, 100.0)
        @test interval === nothing

        interval = Glenn.get_species_for_temperature(tdb, 1, 5000.0)
        @test interval !== nothing
        @test interval["temp_min"] <= 5000.0 <= interval["temp_max"]
    end

    @testset "ThermoDB - Pagination" begin
        species, total_pages = Glenn.list_species_page(tdb, page=1, page_size=10)
        @test length(species) == 1
        @test total_pages == 1
        @test species[1]["name"] == "O2"

        # Page beyond available data
        species, total_pages = Glenn.list_species_page(tdb, page=2, page_size=10)
        @test length(species) == 0
        @test total_pages == 1
    end

    @testset "ThermoDB - List all species" begin
        all_species = Glenn.list_all_species(tdb)
        @test length(all_species) == 1
        @test all_species[1]["name"] == "O2"
    end

    @testset "ThermoDB - Get species info (lightweight)" begin
        info = Glenn.get_species_info(tdb, 1)
        @test info !== nothing
        @test info["name"] == "O2"
        @test info["phase"] == "gas"
        @test info["molecular_weight"] ≈ 31.9988

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

        @testset "Cp/R at 298.15K" begin
            cp_r = Glenn.calculate_cp(coeffs, 298.15)
            @test cp_r ≈ 3.53 atol=0.1
            @test isfinite(cp_r)
            @test cp_r > 0
        end

        @testset "Cp/R at 1000K" begin
            cp_r = Glenn.calculate_cp(coeffs, 1000.0)
            @test 3.5 < cp_r < 5.0
        end

        @testset "H/RT and S/R are finite and positive entropy" begin
            for T in [300.0, 500.0, 800.0, 1000.0]
                h_rt = Glenn.calculate_h(coeffs, T)
                s_r  = Glenn.calculate_s(coeffs, T)
                @test isfinite(h_rt)
                @test isfinite(s_r)
                @test s_r > 0
            end
        end

        @testset "Standalone H/RT calculation" begin
            h_rt = Glenn.calculate_h(coeffs, 298.15)
            @test isfinite(h_rt)
        end

        @testset "Standalone S/R calculation" begin
            s_r = Glenn.calculate_s(coeffs, 298.15)
            @test isfinite(s_r)
            @test s_r > 0
        end

        @testset "Partial coefficients" begin
            partial = Dict("a1" => 0.0, "a3" => 3.5)
            cp_r = Glenn.calculate_cp(partial, 300.0)
            @test cp_r ≈ 3.5
        end

        @testset "Polynomial thermodynamic consistency" begin
            # Verify: d(H/RT)/dT = (Cp/R - H/RT) / T
            T = 500.0
            eps = 1e-4
            cp_r = Glenn.calculate_cp(coeffs, T)
            h_rt = Glenn.calculate_h(coeffs, T)
            h_rt_plus = Glenn.calculate_h(coeffs, T + eps)
            h_rt_minus = Glenn.calculate_h(coeffs, T - eps)
            dhrt_dt = (h_rt_plus - h_rt_minus) / (2 * eps)
            expected = (cp_r - h_rt) / T
            @test isapprox(dhrt_dt, expected, rtol=1e-5)
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
            @test species[1]["name"] == "O2"

            # All species (no filter)
            all_species = Glenn.get_available_species(calc)
            @test length(all_species) == 1
        end

        @testset "Properties at 298.15K" begin
            props = Glenn.calculate_properties(calc, 1, 298.15)
            @test props !== nothing
            @test props["species_name"] == "O2"
            @test props["phase"] == "gas"
            @test props["cp"] ≈ 29.4 atol=1.0
            @test 150.0 < props["s"] < 250.0
            @test props["temp_min"] == 200.0
            @test props["temp_max"] == 1000.0
            @test isfinite(props["cp"])
            @test isfinite(props["h_relative"])
            @test isfinite(props["s"])
        end

        @testset "Properties at 500K" begin
            props = Glenn.calculate_properties(calc, 1, 500.0)
            @test props !== nothing
            @test props["cp"] > 0
            @test isfinite(props["cp"])

            # H should increase with T
            props_298 = Glenn.calculate_properties(calc, 1, 298.15)
            @test props_298 !== nothing
            @test props["h_relative"] > props_298["h_relative"]
        end

        @testset "Properties at 1000K" begin
            props = Glenn.calculate_properties(calc, 1, 1000.0)
            @test props !== nothing
            @test props["cp"] > 20.0
            @test props["h_relative"] > 0.0
            @test props["s"] > 0.0
        end

        @testset "Properties out of range" begin
            # Below valid range
            props = Glenn.calculate_properties(calc, 1, 100.0)
            @test props === nothing

            # Above valid range
            props = Glenn.calculate_properties(calc, 1, 10000.0)
            @test props === nothing
        end

        @testset "Invalid species ID" begin
            props = Glenn.calculate_properties(calc, 99999, 300.0)
            @test props === nothing
        end

        @testset "Formation enthalpy" begin
            h_f = Glenn.calculate_formation_enthalpy(calc, 1)
            @test h_f ≈ 0.0 atol=1.0

            # Nonexistent species
            @test Glenn.calculate_formation_enthalpy(calc, 99999) === nothing
        end

        @testset "Enthalpy change" begin
            delta_h = Glenn.calculate_enthalpy_change(calc, 1, 298.15, 500.0)
            @test delta_h !== nothing
            @test delta_h > 0.0
            @test delta_h < 1e6  # Reasonable for ~200K ΔT

            # Zero delta (same temperature)
            delta_h_zero = Glenn.calculate_enthalpy_change(calc, 1, 400.0, 400.0)
            @test delta_h_zero !== nothing
            @test isapprox(delta_h_zero, 0.0, atol=1e-6)
        end

        @testset "Properties range" begin
            results = Glenn.get_properties_range(calc, 1, [298.15, 500.0, 800.0])
            @test length(results) == 3
            @test all(r -> r["cp"] > 0, results)

            # Cp should increase with temperature
            @test results[2]["cp"] > results[1]["cp"]
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
            @test species[1]["name"] == "O2"
        end

        @test connected_in_block
    end

    # ==================================================================
    # Builder - Parsing utilities
    # ==================================================================
    @testset "Builder - Parse utilities" begin
        @testset "parse_float - normal" begin
            @test Glenn.parse_float("3.14159") ≈ 3.14159
        end

        @testset "parse_float - FORTRAN D notation" begin
            @test Glenn.parse_float("1.234D+02") ≈ 123.4
            @test Glenn.parse_float("5.678D-01") ≈ 0.5678
            @test Glenn.parse_float("1.0d+00") ≈ 1.0
        end

        @testset "parse_float - empty/invalid" begin
            @test Glenn.parse_float("") === nothing
            @test Glenn.parse_float("   ") === nothing
        end

        @testset "is_coefficient_line" begin
            @test Glenn.is_coefficient_line(" 1.234D+05 5.678D-02")
            @test Glenn.is_coefficient_line(" 1.0D0 2.0D+01")
            @test !Glenn.is_coefficient_line("O2")
            @test !Glenn.is_coefficient_line("200.000  1000.000")
        end

        @testset "is_temperature_line" begin
            @test Glenn.is_temperature_line(" 2.0000E+02 1.0000E+03")
            @test !Glenn.is_temperature_line(" 1.0000E+03 2.0000E+02")  # T1 > T2
            @test !Glenn.is_temperature_line("short")
            @test !Glenn.is_temperature_line(" 5.0000E+02 5.0000E+02")  # equal
        end

        @testset "parse_species_record" begin
            name, comments = Glenn.parse_species_record("O2              Ref-1 O2 gas           ")
            @test name == "O2"
            @test occursin("O2", comments)
        end

        @testset "parse_general_info_record" begin
            info = Glenn.parse_general_info_record(
                " 1  g 2/99O   2   1   2    0    00G200.000 3500.000 1000.000    1")
            @test info["num_intervals"] == 1
            @test info["phase"] == "gas"
        end

        @testset "parse_temp_interval_record" begin
            data = Glenn.parse_temp_interval_record(
                " 2.0000E+02 1.0000E+03 0.0000E+00 0.0000E+00 0.0000E+00 0" *
                "               0.0000E+00 0.0000E+00 8.6800E+03")
            @test data["temp_min"] ≈ 200.0
            @test data["temp_max"] ≈ 1000.0
        end

        @testset "parse_coefficients_record" begin
            # Use fixed-width FORTRAN 16-character fields via lpad
            fields4 = lpad.(["3.21225000E+00", "1.12749000E-03", "-5.75615000E-07",
                             "1.31388000E-09", "-8.76854000E-13"], 16)
            line4 = join(fields4)
            fields5 = lpad.(["-1.00524900E+03", "6.03473800E+00", "0.00000000E+00",
                             "3.69757819E+00", "6.13519689E-01"], 16)
            line5 = join(fields5)
            coeffs = Glenn.parse_coefficients_record([line4, line5])
            @test coeffs["a1"] ≈ 3.21225000 rtol=1e-6
            @test coeffs["a2"] ≈ 1.12749000e-03 rtol=1e-6
            @test coeffs["a3"] ≈ -5.75615000e-07 rtol=1e-6
            @test coeffs["a6"] ≈ -1.00524900e03 rtol=1e-6
            @test coeffs["b1"] ≈ 3.69757819 rtol=1e-6
            @test coeffs["b2"] ≈ 6.13519689e-01 rtol=1e-6
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
        rec2 = " 1" * " " * rpad("g 2/99", 43) * " 0" * rpad("31.9988", 14) * rpad("0.0", 15)
        rec2 = rec2[1:min(end, 80)]
        rec2 = rpad(rec2, 80)
        # RECORD 3: temp_min(1:11), temp_max(12:22), h_298(66:80)
        rec3 = rpad("200.0", 11) * rpad("1000.0", 11) * rpad("", 44) * rpad("8680.0", 15)
        rec3 = rec3[1:min(end, 80)]
        rec3 = rpad(rec3, 80)
        # RECORD 4-5: 16-char FORTRAN D-format fields
        vals4 = ["3.21225000D+00", "1.12749000D-03", "-5.75615000D-07", "1.31388000D-09", "-8.76854000D-13"]
        rec4 = join(lpad.(vals4, 16))
        vals5 = ["-1.00524900D+03", "6.03473800D+00", "0.00000000D+00", "3.69757819D+00", "6.13519689D-01"]
        rec5 = join(lpad.(vals5, 16))

        inp_content = join([
            "THERMO",
            "   300.000   1000.000   5000.000",
            rec1,
            rec2,
            rec3,
            rec4,
            rec5,
        ], "\n") * "\n"

        inp_path = "test_minimal_thermo.inp"
        db_path = "test_minimal_thermo.db"

        try
            write(inp_path, inp_content)

            builder = Glenn.ThermoDBBuilder(inp_path, db_path)
            Glenn.connect(builder)
            Glenn.create_tables(builder)
            Glenn.parse_and_load(builder)
            Glenn.close(builder)

            @test isfile(db_path)
            @test filesize(db_path) > 0

            # Verify data
            tdb = Glenn.ThermoDB(db_path)
            stats = Glenn.get_statistics(tdb)
            @test stats["total_species"] == 1
            @test stats["total_intervals"] >= 1
            Glenn.ThermoDatabase.close(tdb)
        finally
            rm(inp_path, force=true)
            rm(db_path, force=true)
        end
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
    rm(db_file, force=true)

end

