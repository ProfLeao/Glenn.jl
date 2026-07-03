module Glenn

using Test
using Printf
using Logging

export Register, TempInterval, parse_thermo_file, find_specie, cp, enthalpy, entropy

# --- Constants ---
"""
Universal Gas Constant R in J/(mol·K).
Source: CODATA 2018.
"""
const R_UNIVERSAL = 8.314462618

# --- Data Structures ---

"""
    TempInterval(t_low, t_high, coeffs)

Represents a temperature range and its associated 7 NASA coefficients.
- `t_low`, `t_high`: Temperature bounds [K].
- `coeffs`: NTuple of 7 coefficients (a1 to a7).
"""
struct TempInterval
    t_low::Float64
    t_high::Float64
    coeffs::NTuple{7, Float64}
end

"""
    Register

Stores thermodynamic data for a chemical species across multiple temperature intervals.
Follows the NASA Glenn (McBride/Gordon) 7-coefficient format logic.
"""
struct Register
    specie::String
    data_source::String
    num_temp_intervals::Int8
    ref_date_code::String
    chem_form::String
    agreg_state::String
    mol_weight::Float64
    heat_form::Float64
    intervals::Vector{TempInterval}
end

# --- Parser Implementation ---

"""
    parse_thermo_file(filepath::String) -> Vector{Register}

Parses a NASA thermo.inp file (7-coefficient fixed-width format).
Handles the standard 4-line per species record used in NASA CEA and Chemkin-II.
"""
function parse_thermo_file(filepath::String)
    if !isfile(filepath)
        error("File not found: $filepath")
    end
    
    lines = readlines(filepath)
    registers = Register[]
    
    i = 1
    while i <= length(lines)
        line = lines[i]
        
        # Skip comments and headers
        if isempty(strip(line)) || startswith(strip(line), "!") || 
           startswith(uppercase(line), "THERMO") || startswith(uppercase(line), "END")
            i += 1
            continue
        end

        try
            # --- Line 1: Metadata and Temperature Ranges ---
            # Format: Name(1-18), Date(19-24), Formula(25-44), Phase(45), T_low(46-55), T_high(56-65), T_mid(66-73)
            specie_name = strip(line[1:18])
            date_code   = strip(line[19:24])
            formula     = strip(line[25:44])
            phase       = strip(line[45:45])
            
            t_low_global  = parse(Float64, strip(line[46:55]))
            t_high_global = parse(Float64, strip(line[56:65]))
            t_mid_global  = parse(Float64, strip(line[66:73]))

            # --- Line 2: Coeffs 1-5 (High T) ---
            l2 = lines[i+1]
            a1_h = parse(Float64, l2[1:15])
            a2_h = parse(Float64, l2[16:30])
            a3_h = parse(Float64, l2[31:45])
            a4_h = parse(Float64, l2[46:60])
            a5_h = parse(Float64, l2[61:75])

            # --- Line 3: Coeffs 6-7 (High T) and 1-3 (Low T) ---
            l3 = lines[i+2]
            a6_h = parse(Float64, l3[1:15])
            a7_h = parse(Float64, l3[16:30])
            a1_l = parse(Float64, l3[31:45])
            a2_l = parse(Float64, l3[46:60])
            a3_l = parse(Float64, l3[61:75])

            # --- Line 4: Coeffs 4-7 (Low T) ---
            l4 = lines[i+3]
            a4_l = parse(Float64, l4[1:15])
            a5_l = parse(Float64, l4[16:30])
            a6_l = parse(Float64, l4[31:45])
            a7_l = parse(Float64, l4[46:60])

            # Construct Intervals (Standard NASA 7-coeff has 2 intervals: Low and High)
            # High T Interval: [t_mid, t_high]
            high_interval = TempInterval(t_mid_global, t_high_global, (a1_h, a2_h, a3_h, a4_h, a5_h, a6_h, a7_h))
            # Low T Interval: [t_low, t_mid]
            low_interval  = TempInterval(t_low_global, t_mid_global, (a1_l, a2_l, a3_l, a4_l, a5_l, a6_l, a7_l))

            reg = Register(
                specie_name, "NASA Glenn", 2, date_code, formula, phase, 0.0, 0.0, 
                [low_interval, high_interval]
            )
            push!(registers, reg)
            
            i += 4 # Move to next block
        catch e
            @warn "Failed to parse block starting at line $i: $specie_name. Skipping."
            i += 1
        end
    end
    return registers
end

# --- Thermodynamic Functions ---

function get_interval(reg::Register, T::Real)
    for interval in reg.intervals
        # Use a small epsilon for boundary inclusion
        if T >= interval.t_low - 1e-3 && T <= interval.t_high + 1e-3
            return interval
        end
    end
    error("Temperature $T K is out of range for species $(reg.specie) [$(reg.intervals[1].t_low) - $(reg.intervals[end].t_high)]")
end

"""
    cp(reg::Register, T::Real) -> Float64

Calculates the specific heat at constant pressure Cp [J/(mol·K)].
Equation: Cp/R = a1 + a2*T + a3*T^2 + a4*T^3 + a5*T^4
Reference: NASA RP-1311.
"""
function cp(reg::Register, T::Real)
    inter = get_interval(reg, T)
    a = inter.coeffs
    cp_r = a[1] + a[2]*T + a[3]*T^2 + a[4]*T^3 + a[5]*T^4
    return cp_r * R_UNIVERSAL
end

"""
    enthalpy(reg::Register, T::Real) -> Float64

Calculates the molar enthalpy H [J/mol].
Equation: H/RT = a1 + a2*T/2 + a3*T^2/3 + a4*T^3/4 + a5*T^4/5 + a6/T
Reference: NASA RP-1311.
"""
function enthalpy(reg::Register, T::Real)
    inter = get_interval(reg, T)
    a = inter.coeffs
    h_rt = a[1] + a[2]*T/2 + a[3]*T^2/3 + a[4]*T^3/4 + a[5]*T^4/5 + a[6]/T
    return h_rt * R_UNIVERSAL * T
end

"""
    entropy(reg::Register, T::Real) -> Float64

Calculates the molar entropy S [J/(mol·K)].
Equation: S/R = a1*ln(T) + a2*T + a3*T^2/2 + a4*T^3/3 + a5*T^4/4 + a7
Reference: NASA RP-1311.
"""
function entropy(reg::Register, T::Real)
    inter = get_interval(reg, T)
    a = inter.coeffs
    s_r = a[1]*log(T) + a[2]*T + a[3]*T^2/2 + a[4]*T^3/3 + a[5]*T^4/4 + a[7]
    return s_r * R_UNIVERSAL
end

"""
    find_specie(registers::Vector{Register}, name::String) -> Register

Finds a species by name (case-insensitive).
"""
function find_specie(registers::Vector{Register}, name::String)
    target = uppercase(strip(name))
    idx = findfirst(r -> uppercase(r.specie) == target, registers)
    if idx === nothing
        error("Species '$name' not found in database.")
    end
    return registers[idx]
end

# --- Unit Tests ---

function run_tests()
    @testset "Glenn.jl Tests" begin
        # Mock NASA 7-coefficient data for N2
        mock_data = """
THERMO
   300.000  1000.000  5000.000
N2                121286N  2               G   300.000   5000.000  1000.000      1
 0.02920242E+02 0.01487977E-01-0.00568476E-04 0.01009704E-07-0.00675335E-12    2
-0.09227977E+04 0.05980528E+02 0.03298677E+02 0.01408240E-01-0.03963222E-04    3
 0.05641515E-07-0.02444854E-10-0.10208999E+04 0.03950372E+02                   4
END
"""
        path = "test_thermo.inp"
        write(path, mock_data)
        
        regs = parse_thermo_file(path)
        @test length(regs) == 1
        n2 = find_specie(regs, "N2")
        @test n2.specie == "N2"
        
        # Test Cp at 300K (Low T interval)
        # Cp/R ~ 3.5 for diatomic at low T
        val_cp = cp(n2, 300.0)
        @test val_cp ≈ 3.5 * R_UNIVERSAL atol=1.0
        
        # Test Enthalpy and Entropy
        @test enthalpy(n2, 1000.0) isa Float64
        @test entropy(n2, 500.0) > 0
        
        # Test Out of Range
        @test_throws ErrorException cp(n2, 100.0)
        @test_throws ErrorException cp(n2, 6000.0)
        
        rm(path)
    end
end

# --- Example Usage ---

# if abspath(PROGRAM_FILE) == @__FILE__
#     # Example workflow:
#     # db = parse_thermo_file("thermo.inp")
#     # n2 = find_specie(db, "N2")
#     # println("Cp at 298.15K: ", cp(n2, 298.15), " J/mol-K")
#     # println("H at 1000K: ", enthalpy(n2, 1000.0), " J/mol")
#     run_tests()
# end

end # module Glenn
