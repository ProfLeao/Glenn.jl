struct ThermoFile
    first_keys = [
        "SPECIE", "COMMENTS", "NT_INTERVALS", "REF_DATE_CODE", 
        "CHEM_FORM", "ST_AGREG", "MOL_W", "HEAT_FORM"
    ]
    template_keys = [
        "INF_T_RANG_", "SUP_T_RANG_", "N_COEFS_CP_", "T_EXPs_", 
        "DELTA_H_", "CP_COEF1_", "CP_COEF2_",  "CP_COEF3_",
        "CP_COEF4_",  "CP_COEF5_", "CP_COEF6_", "CP_COEF7_", 
        "B1_", "B2_"
    ]
    first_datacols = [
        0:16, 18:end, 
    ]
end

struct Register
    n_lines::Int = length(f_lines)
end