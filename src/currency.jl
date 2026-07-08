# ---------------------------------------------------------------------------
# PTAX — cotações de moedas
#
# Serviço Olinda "PTAX" (OData). As funções de período recebem datas no
# formato MM-DD-YYYY (peculiaridade da API).
# ---------------------------------------------------------------------------

"Serviço Olinda das cotações PTAX."
const PTAX = olinda("PTAX", "v1")

const _PTAX_DATEFORMAT = dateformat"mm-dd-yyyy"

const _BULLETINS = Dict{Symbol, String}(
    :opening      => "Abertura",
    :intermediate => "Intermediário",
    :closing      => "Fechamento",
)

"""
    currencies() -> BCBTable

Lista as moedas disponíveis no serviço PTAX (símbolo, nome, tipo A/B).

```julia
julia> currencies()
```
"""
currencies(; kwargs...) = execute(endpoint(PTAX, "Moedas"); kwargs...)

"""
    currency_endpoint(symbol, start, stop) -> ODataEndpoint

Endpoint OData `CotacaoMoedaPeriodo` já parametrizado. Ponto de extensão
para consultas customizadas:

```julia
q = BCB.currency_endpoint("EUR", Date(2024, 1, 1), Date(2024, 6, 30)) |>
    Select(:cotacaoVenda, :dataHoraCotacao) |>
    Where(:tipoBoletim => "Fechamento")
execute(q)
```
"""
function currency_endpoint(symbol::Union{AbstractString, Symbol}, start, stop)
    return endpoint(PTAX, "CotacaoMoedaPeriodo";
                    moeda = uppercase(String(symbol)),
                    dataInicial = Dates.format(Date(start), _PTAX_DATEFORMAT),
                    dataFinalCotacao = Dates.format(Date(stop), _PTAX_DATEFORMAT))
end

"""
    currency(symbol, start, stop = today(); bulletin = nothing, kwargs...) -> BCBTable

Cotações PTAX da moeda `symbol` (ex.: `"USD"`, `"EUR"`, `:GBP`) no período
`[start, stop]`, ordenadas por data/hora. Colunas típicas: `paridadeCompra`,
`paridadeVenda`, `cotacaoCompra`, `cotacaoVenda`, `dataHoraCotacao`,
`tipoBoletim`.

  - `bulletin`: filtra o tipo de boletim — `:opening` (abertura),
    `:intermediate` (intermediário) ou `:closing` (fechamento). `nothing`
    (padrão) devolve todos.
  - demais `kwargs` são repassados a [`execute`](@ref) (`parsedates`, ...).

```julia
usd = currency("USD", Date(2024, 1, 1), Date(2024, 6, 30); bulletin = :closing)
eur = currency(:EUR, "2025-01-01")   # até hoje, todos os boletins
```
"""
function currency(symbol::Union{AbstractString, Symbol}, start, stop = Dates.today();
                  bulletin::Union{Nothing, Symbol} = nothing, kwargs...)
    q = ODataQuery(currency_endpoint(symbol, start, stop)) |> OrderBy(:dataHoraCotacao)
    if bulletin !== nothing
        haskey(_BULLETINS, bulletin) ||
            throw(ArgumentError("bulletin deve ser :opening, :intermediate ou :closing"))
        q = q |> Where(:tipoBoletim => ==(_BULLETINS[bulletin]))
    end
    return execute(q; kwargs...)
end
