```@meta
CurrentModule = Glenn
```

# Database API

Low-level SQLite query interface and NASA-7 polynomial calculations.

All thermodynamic functions return **dimensionless** values (divided by R).

## Exception Types

```@docs
Glenn.ThermoDatabase.ThermoCalcError
Glenn.ThermoDatabase.ThermoError
Glenn.ThermoDatabase.DatabaseNotConnectedError
Glenn.ThermoDatabase.SpeciesNotFoundError
Glenn.ThermoDatabase.TemperatureOutOfRangeError
Glenn.ThermoDatabase.CompositionError
```

## Types

```@docs
NASACoefficients
SpeciesInfo
Glenn.ThermoDatabase.SpeciesData
IntervalData
DatabaseStats
Glenn.ThermoDatabase.Mixture
Glenn.ThermoDatabase.MixedProperties
Glenn.ThermoDatabase.ThermoDB
```

## Mixtures and species data helpers

```@docs
Glenn.to_dict
Glenn.validate
```

## Statistics

```@docs
Glenn.get_statistics
```

## Reference Gas Constant

```@docs
Glenn.get_gas_constant_ref
```

## Species Lookup

```@docs
Glenn.find_species
Glenn.list_species_page
Glenn.list_all_species
Glenn.get_species_data
Glenn.get_species_info
Glenn.get_species_for_temperature
```

## NASA-7 Polynomials

```@docs
Glenn.calculate_cp
Glenn.calculate_h
Glenn.calculate_s
```
