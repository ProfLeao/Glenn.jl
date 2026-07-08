```@meta
CurrentModule = Glenn
```

# Database API

Low-level SQLite query interface and NASA-7 polynomial calculations.

All thermodynamic functions return **dimensionless** values (divided by R).

```@docs
Glenn.ThermoDatabase.ThermoDB
Glenn.get_statistics
Glenn.find_species
Glenn.list_species_page
Glenn.list_all_species
Glenn.get_species_data
Glenn.get_species_info
Glenn.get_species_for_temperature
Glenn.calculate_cp
Glenn.calculate_h
Glenn.calculate_s
```
