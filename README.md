# BCB.jl

Cliente Julia para as APIs públicas do **Banco Central do Brasil**: séries
temporais do **SGS**, cotações de moedas **PTAX** e **Expectativas de
Mercado (Focus)** — mais um construtor de consultas **OData genérico** capaz
de acessar qualquer serviço da plataforma Olinda.

Não é um port do `python-bcb` nem do `rbcb`: a interface foi desenhada para
Julia, explorando despacho múltiplo, tipagem paramétrica, composição por
functors e a interface [Tables.jl](https://github.com/JuliaData/Tables.jl).
Dependências mínimas: `JSON3`, `Tables` e as bibliotecas padrão `Dates` e
`Downloads` (sem HTTP.jl — carregamento rápido).

> Este pacote não é afiliado ao Banco Central do Brasil.

## Instalação

```julia
pkg> add https://github.com/dantebertuzzi/BCB.jl
```

## SGS — séries temporais

```julia
using BCB, Dates

ipca = sgs(:ipca => 433; start = Date(2020, 1, 1))
```

```
SGSSeries{Float64} :ipca (SGS 433), 72 observações
  2020-01-01 … 2025-12-01
  ▂▁▃▄▆█▅▃▂▂▁▂▃▂▂▁▁▂▂▃▂▂▁▁▂...
  último valor: 0.52 em 2025-12-01
```

- `start`/`stop` aceitam `Date`, string ISO (`"2020-01-01"`) ou ano (`2020`).
- `sgs(433; last = 12)` devolve as últimas 12 observações.
- Períodos maiores que 10 anos (limite da API para séries diárias) são
  **particionados automaticamente** em janelas contíguas e concatenados.
- O parâmetro de tipo reflete a completude da série: `SGSSeries{Float64}` se
  não há lacunas, `SGSSeries{Union{Missing, Float64}}` caso contrário —
  informação disponível para despacho.

Múltiplas séries são unidas por data (junção externa) num `BCBTable`:

```julia
using DataFrames
df = DataFrame(sgs(:selic => 432, :cdi => 12, :ipca => 433; start = 2015))
```

`SGSSeries` também itera como linhas nomeadas:

```julia
maximum(r.value for r in ipca)
```

## PTAX — cotações de moedas

```julia
currencies()                                       # moedas disponíveis
usd = currency("USD", Date(2024, 1, 1), Date(2024, 6, 30); bulletin = :closing)
eur = currency(:EUR, "2025-01-01")                 # até hoje, todos os boletins
```

`bulletin` filtra o tipo de boletim: `:opening`, `:intermediate`, `:closing`.
Colunas de data/hora chegam como `DateTime` (conversão automática).

## Expectativas de Mercado (Focus)

`expectations` devolve uma consulta OData composável:

```julia
focus = expectations(:monthly, :Indicador => "IPCA", :Data => >=(Date(2025, 1, 1))) |>
        Select(:Data, :DataReferencia, :Mediana, :numeroRespondentes) |>
        OrderBy(:Data => :desc) |>
        Top(100) |>
        execute
```

Recursos disponíveis: `:monthly`, `:quarterly`, `:annual`, `:inflation12m`,
`:inflation24m`, `:monthly_top5`, `:annual_top5`, `:selic`, `:selic_top5`.

Para o histórico completo de um indicador, use paginação automática:

```julia
execute(expectations(:annual, :Indicador => "PIB Total"); paginate = true)
```

## OData genérico — qualquer serviço Olinda

Os blocos acima são construídos sobre uma camada OData reutilizável:

```julia
juros = olinda("taxaJuros", "v2")
q = endpoint(juros, "TaxasJurosDiariaPorInicioPeriodo") |>
    Where(:Modalidade => contains("crédito pessoal")) |>
    OrderBy(:InicioPeriodo => :desc) |>
    Top(50)
execute(q)
```

### Filtros por despacho múltiplo

`Where` aceita pares `campo => condição`, onde a condição é um valor (que
vira igualdade) ou uma **função parcial nativa de Julia** (`Base.Fix2`),
traduzida para OData por despacho:

| Julia                        | OData                                  |
|:-----------------------------|:---------------------------------------|
| `:Indicador => "IPCA"`       | `Indicador eq 'IPCA'`                  |
| `:Data => >=(Date(2024))`    | `Data ge '2024-01-01'`                 |
| `:Mediana => !=(0)`          | `Mediana ne 0`                         |
| `:Indicador => in(["IPCA", "Selic"])` | `(Indicador eq 'IPCA' or Indicador eq 'Selic')` |
| `:Indicador => contains("PCA")` | `contains(Indicador,'PCA')`          |
| `:Indicador => startswith("IP")` | `startswith(Indicador,'IP')`        |
| `Where("expressão crua")`    | passa direto                           |

`Where` encadeado compõe com `and`. As consultas são imutáveis — cada
modificador devolve uma nova `ODataQuery`, então consultas-base podem ser
reutilizadas e especializadas sem efeitos colaterais.

## Resultados são tabelas (Tables.jl)

`BCBTable` e `SGSSeries` implementam a interface Tables.jl — funcionam
diretamente com `DataFrame(...)`, `CSV.write(...)`, consultas de
`DataFramesMeta`/`TidierData`, plotagem via `Makie`/`AlgebraOfGraphics`, etc.
Colunas de texto com datas/timestamps são convertidas para `Date`/`DateTime`
automaticamente (desligável com `execute(q; parsedates = false)`).

## Camada de transporte plugável

Todo o tráfego passa por `BCB.request(transport, url)`. O padrão usa a
stdlib `Downloads` com retry exponencial para erros transitórios (conexão,
timeout, 429, 5xx). Para testes, caching ou instrumentação, defina um
subtipo de `AbstractTransport`:

```julia
struct Gravador <: BCB.AbstractTransport
    inner::BCB.AbstractTransport
    log::Vector{String}
end

function BCB.request(g::Gravador, url::AbstractString)
    push!(g.log, url)
    BCB.request(g.inner, url)
end

with_transport(Gravador(BCB.DownloadsTransport(), String[])) do
    sgs(433; last = 12)
end
```

A suíte de testes do pacote roda 100% offline usando exatamente esse
mecanismo (`test/runtests.jl`).

## Design

- **Despacho múltiplo**: literais e cláusulas OData são funções abertas
  (`BCB.literal`, `BCB.clause`) — novos tipos de valor e novos operadores
  entram com um método, sem tocar no núcleo.
- **Tipagem paramétrica**: `SGSSeries{T}` codifica no tipo a presença de
  `missing`.
- **Composição**: `Where`, `Select`, `OrderBy`, `Top`, `Skip` são functors
  imutáveis encadeáveis com `|>`.
- **Sem dependências pesadas**: transporte via stdlib `Downloads`; nenhum
  DataFrames obrigatório graças a Tables.jl.

## Códigos SGS úteis

| código | série                          |
|-------:|:-------------------------------|
| 1      | Dólar PTAX venda (diária)      |
| 12     | CDI (diária)                   |
| 432    | Meta Selic (diária)            |
| 433    | IPCA variação mensal           |
| 189    | IGP-M variação mensal          |
| 188    | INPC variação mensal           |
| 4389   | CDI anualizado (diária)        |
| 24363  | IBC-Br dessazonalizado         |

Consulte o catálogo completo em <https://www3.bcb.gov.br/sgspub>.

## Roadmap

- [ ] Busca/metadados de séries do SGS
- [ ] Wrappers de conveniência para outros serviços Olinda (taxas de juros,
      IF.data, SPI/Pix, mercado imobiliário)
- [ ] Cache opcional em disco
- [ ] Registro no General

## Licença

MIT.
