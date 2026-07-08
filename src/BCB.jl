"""
    BCB

Cliente Julia para as APIs públicas do Banco Central do Brasil (BCB).

Cobre três famílias de serviços:

  - **SGS** (Sistema Gerenciador de Séries Temporais) — [`sgs`](@ref)
  - **PTAX** (cotações de moedas) — [`currency`](@ref), [`currencies`](@ref)
  - **Expectativas de mercado / Focus** (OData/Olinda) — [`expectations`](@ref)

Além disso, expõe um construtor de consultas **OData genérico** ([`olinda`](@ref),
[`endpoint`](@ref), [`Where`](@ref), [`Select`](@ref), [`OrderBy`](@ref),
[`Top`](@ref), [`Skip`](@ref), [`execute`](@ref)) capaz de acessar qualquer
serviço da plataforma Olinda do BCB.

Todos os resultados tabulares implementam a interface
[Tables.jl](https://github.com/JuliaData/Tables.jl), portanto podem ser
materializados diretamente com `DataFrame(resultado)`, `CSV.write`, etc.

# Exemplo rápido

```julia
using BCB, DataFrames

ipca  = sgs(:ipca => 433; start = Date(2020, 1, 1))
selic = DataFrame(sgs(:selic => 432, :cdi => 12; start = 2024))

usd = currency("USD", Date(2024, 1, 1), Date(2024, 6, 30); bulletin = :closing)

focus = expectations(:monthly, :Indicador => "IPCA", :Data => >=(Date(2025, 1, 1))) |>
        Select(:Data, :DataReferencia, :Mediana) |>
        OrderBy(:Data => :desc) |>
        Top(50) |>
        execute
```

Este pacote não é afiliado ao Banco Central do Brasil.
"""
module BCB

using Dates
using Downloads
using JSON3
using Tables

export
    # transporte
    AbstractTransport, DownloadsTransport, set_transport!, with_transport,
    # erros
    BCBError,
    # OData genérico (Olinda)
    ODataService, ODataEndpoint, ODataQuery,
    olinda, endpoint, execute,
    Where, Select, OrderBy, Top, Skip,
    # resultados tabulares
    BCBTable,
    # SGS
    SGSSeries, sgs,
    # PTAX
    currencies, currency,
    # Focus / Expectativas
    expectations

"Versão do pacote (usada no cabeçalho `User-Agent`)."
const PKG_VERSION = let v = pkgversion(@__MODULE__)
    v === nothing ? v"0.0.0" : v
end

include("errors.jl")
include("transport.jl")
include("tables.jl")
include("odata.jl")
include("sgs.jl")
include("currency.jl")
include("expectations.jl")

end # module BCB
