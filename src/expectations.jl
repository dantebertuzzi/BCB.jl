# ---------------------------------------------------------------------------
# Expectativas de Mercado (boletim Focus)
#
# Serviço Olinda "Expectativas" (OData). `expectations` devolve uma
# ODataQuery pronta para composição — o usuário refina com Where/Select/...
# e materializa com `execute`.
# ---------------------------------------------------------------------------

"Serviço Olinda das Expectativas de Mercado (Focus)."
const EXPECTATIONS = olinda("Expectativas", "v1")

const _EXPECTATION_RESOURCES = Dict{Symbol, String}(
    :monthly      => "ExpectativaMercadoMensais",
    :quarterly    => "ExpectativasMercadoTrimestrais",
    :annual       => "ExpectativasMercadoAnuais",
    :inflation12m => "ExpectativasMercadoInflacao12Meses",
    :inflation24m => "ExpectativasMercadoInflacao24Meses",
    :monthly_top5 => "ExpectativasMercadoTop5Mensais",
    :annual_top5  => "ExpectativasMercadoTop5Anuais",
    :selic        => "ExpectativasMercadoSelic",
    :selic_top5   => "ExpectativasMercadoTop5Selic",
)

"""
    expectations(kind = :monthly, filters::Pair...) -> ODataQuery

Consulta às Expectativas de Mercado (boletim Focus). Devolve uma
[`ODataQuery`](@ref) composável — refine com [`Where`](@ref),
[`Select`](@ref), [`OrderBy`](@ref), [`Top`](@ref) e materialize com
[`execute`](@ref).

`kind` seleciona o recurso:

| `kind`          | recurso Olinda                        |
|:----------------|:--------------------------------------|
| `:monthly`      | ExpectativaMercadoMensais             |
| `:quarterly`    | ExpectativasMercadoTrimestrais        |
| `:annual`       | ExpectativasMercadoAnuais             |
| `:inflation12m` | ExpectativasMercadoInflacao12Meses    |
| `:inflation24m` | ExpectativasMercadoInflacao24Meses    |
| `:monthly_top5` | ExpectativasMercadoTop5Mensais        |
| `:annual_top5`  | ExpectativasMercadoTop5Anuais         |
| `:selic`        | ExpectativasMercadoSelic              |
| `:selic_top5`   | ExpectativasMercadoTop5Selic          |

Pares extras são açúcar sintático para `Where`:

```julia
q = expectations(:monthly, :Indicador => "IPCA", :Data => >=(Date(2025, 1, 1)))
df = q |> OrderBy(:Data => :desc) |> Top(100) |> execute |> DataFrame

# histórico completo de um indicador, paginado:
execute(expectations(:annual, :Indicador => "PIB Total"); paginate = true)
```
"""
function expectations(kind::Symbol = :monthly, filters::Pair...)
    haskey(_EXPECTATION_RESOURCES, kind) ||
        throw(ArgumentError("kind desconhecido: :$kind. Válidos: " *
                            join(sort!(collect(keys(_EXPECTATION_RESOURCES))), ", ")))
    q = ODataQuery(endpoint(EXPECTATIONS, _EXPECTATION_RESOURCES[kind]))
    return isempty(filters) ? q : q |> Where(filters...)
end
