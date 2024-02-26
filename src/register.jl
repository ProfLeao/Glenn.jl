struct ThermoFileTemplate
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
    first_datacols = [1:16, 17:end, 1:2, 4:9, 11:49, 51:52, 53:65, 65:end]
    template_datacols = [
        1:11, 12:22, 23, 24:63, 66:end, 1:16, 17:32, 33:48, 49:64,
        65:80, 1:16, 17:32, 49:64, 65:80
    ] 
end

struct Register
    # Specie data
    specie::String
    data_source::String
    num_temp_intervals::Int8
    ref_date_code::String
    chem_form::String
    agreg_state::String
    mol_weight::Float16
    heat_form::Float16


end