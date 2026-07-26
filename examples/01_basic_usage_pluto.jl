### A Pluto.jl notebook ###
# v0.19.46

using Markdown
using InteractiveUtils

# ╔═╡ 9a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d
md"""
# Getting started with Glenn.jl

Esta é a versão **Pluto.jl** interativa do tutorial básico. As células são
reativas — altere um valor e veja todos os resultados se atualizarem!

Este notebook percorre o fluxo de trabalho essencial da biblioteca **Glenn.jl**:

1. Conectar ao banco de dados termoquímico (integrado, sem configuração manual);
2. Procurar uma espécie química;
3. Calcular $C_p(T)$, $H^\circ(T)$ e $S^\circ(T)$ em uma dada temperatura.

O banco `thermo.db` é fornecido dentro do pacote — basta instanciar
`Calculator()` sem argumentos.
"""

# ╔═╡ b1c2d3e4-f5a6-b7c8-d9e0-f1a2b3c4d5e6
begin
    using Glenn
    using Printf
end

# ╔═╡ c2d3e4f5-a6b7-c8d9-e0f1-a2b3c4d5e6f7
md"""
## 🔍 Buscando uma espécie

Use `get_available_species` com `exact_match=true` para busca exata
case-insensitive — `"N2"` retorna apenas N₂, não Be₃N₂.
"""

# ╔═╡ d3e4f5a6-b7c8-d9e0-f1a2-b3c4d5e6f7a8
calc = Calculator()

# ╔═╡ e4f5a6b7-c8d9-e0f1-a2b3-c4d5e6f7a8b9
md"""
### Busca por substring (legado)

Mostra todas as espécies que contêm `"CH4"` no nome.
"""

# ╔═╡ f5a6b7c8-d9e0-f1a2-b3c4-d5e6f7a8b9c0
let
    species = get_available_species(calc, "CH4")
    for s in species[1:min(5, end)]
        @printf("  id=%5d  %-12s phase=%s\n", s.id, s.name, s.phase)
    end
end

# ╔═╡ a6b7c8d9-e0f1-a2b3-c4d5-e6f7a8b9c0d1
md"""
### Busca exata (recomendada)

`exact_match=true` — busca case-insensitive exata. `"O2"` retorna apenas O₂.
"""

# ╔═╡ b7c8d9e0-f1a2-b3c4-d5e6-f7a8b9c0d1e2
let
    o2_list = get_available_species(calc, "O2", exact_match = true)
    for s in o2_list
        @printf("  id=%5d  %-12s phase=%s  MW=%.4f\n",
            s.id, s.name, s.phase, something(s.molecular_weight, 0.0))
    end
end

# ╔═╡ c8d9e0f1-a2b3-c4d5-e6f7-a8b9c0d1e2f3
md"""
## 🔥 Calculando propriedades termoquímicas

Com o `id` em mãos, `calculate_properties(species_id, temperature)` retorna
uma struct `ThermoProperties` com $C_p$, $H^\circ$ (relativo a 0 K) e $S^\circ$.
"""

# ╔═╡ d9e0f1a2-b3c4-d5e6-f7a8-b9c0d1e2f3a4
species_ch4 = only(get_available_species(calc, "CH4", exact_match = true))

# ╔═╡ e0f1a2b3-c4d5-e6f7-a8b9-c0d1e2f3a4b5
result = calculate_properties(calc, species_ch4.id, 298.15)

# ╔═╡ f1a2b3c4-d5e6-f7a8-b9c0-d1e2f3a4b5c6
md"""
**Resultados para $(result.species_name) ($(result.phase)):**
- Temperatura: **$(round(result.temperature, digits=2)) K**
- Cp: **$(round(result.cp, digits=3)) J/(mol·K)**
- H°: **$(round(result.h_relative, digits=3)) J/mol**
- S°: **$(round(result.s, digits=3)) J/(mol·K)**
"""

# ╔═╡ a2b3c4d5-e6f7-a8b9-c0d1-e2f3a4b5c6d7
md"""
## 📈 Varredura de temperatura

Calcule $C_p$ para várias temperaturas de uma vez.
"""

# ╔═╡ b3c4d5e6-f7a8-b9c0-d1e2-f3a4b5c6d7e8
temperatures = [300.0, 500.0, 800.0, 1000.0, 1500.0]

# ╔═╡ c4d5e6f7-a8b9-c0d1-e2f3-a4b5c6d7e8f9
let
    species_id = species_ch4.id
    println("  $(rpad("T (K)", 8)) | $(rpad("Cp (J/mol·K)", 14))")
    println("  " * "-"^27)
    for T in temperatures
        r = calculate_properties(calc, species_id, T)
        @printf("  %8.1f | %14.3f\n", T, r.cp)
    end
end

# ╔═╡ d5e6f7a8-b9c0-d1e2-f3a4-b5c6d7e8f9a0
md"""
## 🧪 Entalpia de formação

Entalpia de formação padrão a 298.15 K.
"""

# ╔═╡ e6f7a8b9-c0d1-e2f3-a4b5-c6d7e8f9a0b1
hf = calculate_formation_enthalpy(calc, species_ch4.id)

# ╔═╡ f7a8b9c0-d1e2-f3a4-b5c6-d7e8f9a0b1c2
if hf !== nothing
    md"""
    **H°_f(298.15 K) = $(round(hf, digits=1)) J/mol**
    """
else
    md"**H°_f não disponível para $(species_ch4.name)**"
end

# ╔═╡ Cell order
# ╠═9a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d
# ╠═b1c2d3e4-f5a6-b7c8-d9e0-f1a2b3c4d5e6
# ╠═c2d3e4f5-a6b7-c8d9-e0f1-a2b3c4d5e6f7
# ╠═d3e4f5a6-b7c8-d9e0-f1a2-b3c4d5e6f7a8
# ╠═e4f5a6b7-c8d9-e0f1-a2b3-c4d5e6f7a8b9
# ╠═f5a6b7c8-d9e0-f1a2-b3c4-d5e6f7a8b9c0
# ╠═a6b7c8d9-e0f1-a2b3-c4d5-e6f7a8b9c0d1
# ╠═b7c8d9e0-f1a2-b3c4-d5e6-f7a8b9c0d1e2
# ╠═c8d9e0f1-a2b3-c4d5-e6f7-a8b9c0d1e2f3
# ╠═d9e0f1a2-b3c4-d5e6-f7a8-b9c0d1e2f3a4
# ╠═e0f1a2b3-c4d5-e6f7-a8b9-c0d1e2f3a4b5
# ╠═f1a2b3c4-d5e6-f7a8-b9c0-d1e2f3a4b5c6
# ╠═a2b3c4d5-e6f7-a8b9-c0d1-e2f3a4b5c6d7
# ╠═b3c4d5e6-f7a8-b9c0-d1e2-f3a4b5c6d7e8
# ╠═c4d5e6f7-a8b9-c0d1-e2f3-a4b5c6d7e8f9
# ╠═d5e6f7a8-b9c0-d1e2-f3a4-b5c6d7e8f9a0
# ╠═e6f7a8b9-c0d1-e2f3-a4b5-c6d7e8f9a0b1
# ╠═f7a8b9c0-d1e2-f3a4-b5c6-d7e8f9a0b1c2
