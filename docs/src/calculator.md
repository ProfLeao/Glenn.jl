```@meta
CurrentModule = Glenn
```

# Calculator API

High-level interface for calculating thermochemical properties.

## Types

```@docs
ThermoProperties
Calculator
```

## Functions

```@docs
default_db_path
default_inp_path
get_available_species
calculate_properties
calculate_properties_range
calculate_formation_enthalpy
calculate_enthalpy_change
h_sensible_to
dcp_dt
Glenn.gamma
mixture_properties
```

`get_properties_range` is deprecated in favour of `calculate_properties_range`
and no longer carries its own docstring.

## Constants

```@docs
Glenn.ThermoDatabase.R_UNIVERSAL
Glenn.ThermoDatabase.R_GLENN
```
