# Test suite for Glenn.jl
# Tests the thermochemical database queries and NASA-7 polynomial calculations.
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

    # Insert O2 data (NIST-JANAF): 2 intervals (200-1000K, 1000K-6000K)
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

    # Create the same schema on disk
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

    # Copy species (10 columns)
    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM species")
        SQLite.execute(disk_db,
            "INSERT INTO species VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", Tuple(row))
    end
    # Copy temperature_intervals (6 columns)
    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM temperature_intervals")
        SQLite.execute(disk_db,
            "INSERT INTO temperature_intervals VALUES (?, ?, ?, ?, ?, ?)", Tuple(row))
    end
    # Copy coefficients (11 columns)
    for row in SQLite.DBInterface.execute(mem_db, "SELECT * FROM coefficients")
        SQLite.execute(disk_db,
            "INSERT INTO coefficients VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", Tuple(row))
    end
    # Copy file_metadata (7 columns)
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

    # ---- Module exports ----
    @testset "Module exports" begin
        @test isdefined(Glenn, :Calculator)
        @test isdefined(Glenn, :R_UNIVERSAL)
        @test isdefined(Glenn, :calculate_properties)
        @test isdefined(Glenn, :calculate_cp)
        @test isdefined(Glenn, :calculate_h)
        @test isdefined(Glenn, :calculate_s)
        @test isdefined(Glenn, :find_species)
        @test isdefined(Glenn, :get_statistics)
    end

    # ---- Constants ----
    @testset "Physical constants" begin
        @test Glenn.R_UNIVERSAL ≈ 8.314462618
        @test 8.0 < Glenn.R_UNIVERSAL < 9.0
    end

    # ---- Database queries (disk-based) ----
    mem_db = setup_test_db()
    db_file = "test_thermo.db"
    disk_db = copy_to_disk(mem_db, db_file)
    SQLite.close(mem_db)
    SQLite.close(disk_db)

    tdb = Glenn.ThermoDatabase.ThermoDB(db_file)

    @testset "Statistics" begin
        stats = Glenn.get_statistics(tdb)
        @test stats["total_species"] == 1
        @test stats["total_intervals"] == 2
        @test stats["total_coeff_sets"] == 2
        @test stats["species_by_phase"]["gas"] == 1
    end

    @testset "Find species" begin
        results = Glenn.find_species(tdb, "O2")
        @test length(results) == 1
        @test results[1]["name"] == "O2"
        @test results[1]["phase"] == "gas"
        @test results[1]["molecular_weight"] ≈ 31.9988
    end

    @testset "Get species data" begin
        data = Glenn.get_species_data(tdb, 1)
        @test data !== nothing
        @test data["name"] == "O2"
        @test length(data["intervals"]) == 2
    end

    @testset "Species for temperature" begin
        interval = Glenn.get_species_for_temperature(tdb, 1, 300.0)
        @test interval !== nothing
        @test interval["temp_min"] <= 300.0 <= interval["temp_max"]

        interval = Glenn.get_species_for_temperature(tdb, 1, 100.0)
        @test interval === nothing
    end

    Glenn.ThermoDatabase.close(tdb)

    # ---- NASA-7 polynomial calculations ----
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

        @testset "Partial coefficients" begin
            partial = Dict("a1" => 0.0, "a3" => 3.5)
            cp_r = Glenn.calculate_cp(partial, 300.0)
            @test cp_r ≈ 3.5
        end
    end

    # ---- Calculator (high-level API) ----
    @testset "Calculator" begin
        calc = Glenn.Calculator(db_file)

        @testset "Available species" begin
            species = Glenn.get_available_species(calc, "O2")
            @test length(species) == 1
        end

        @testset "Properties at 298.15K" begin
            props = Glenn.calculate_properties(calc, 1, 298.15)
            @test props !== nothing
            @test props["species_name"] == "O2"
            @test props["phase"] == "gas"
            @test props["cp"] ≈ 29.4 atol=1.0
            @test 150.0 < props["s"] < 250.0
        end

        @testset "Properties at 1000K" begin
            props = Glenn.calculate_properties(calc, 1, 1000.0)
            @test props !== nothing
            @test props["cp"] > 20.0
            @test props["h_relative"] > 0.0
            @test props["s"] > 0.0
        end

        @testset "Out of range" begin
            props = Glenn.calculate_properties(calc, 1, 50.0)
            @test props === nothing
        end

        @testset "Formation enthalpy" begin
            h_f = Glenn.calculate_formation_enthalpy(calc, 1)
            @test h_f ≈ 0.0
        end

        @testset "Enthalpy change" begin
            delta_h = Glenn.calculate_enthalpy_change(calc, 1, 300.0, 1000.0)
            @test delta_h !== nothing
            @test delta_h > 0.0
        end

        @testset "Properties range" begin
            results = Glenn.get_properties_range(calc, 1, [300.0, 500.0, 800.0])
            @test length(results) == 3
            @test all(r -> r["cp"] > 0, results)
        end

        Glenn.close(calc)
    end

    # ---- Edge cases ----
    @testset "Edge cases" begin
        @testset "Database not found" begin
            @test_throws ErrorException Glenn.ThermoDatabase.ThermoDB("nonexistent.db")
        end

        @testset "_or_zero helper" begin
            @test Glenn.ThermoDatabase._or_zero(nothing) == 0.0
            @test Glenn.ThermoDatabase._or_zero(42.0) == 42.0
        end
    end

    # Cleanup
    rm(db_file, force=true)

end

