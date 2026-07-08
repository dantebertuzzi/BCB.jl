# ---------------------------------------------------------------------------
# OData / Olinda
#
# A plataforma Olinda do BCB expõe dezenas de serviços via OData. Este
# arquivo implementa um construtor de consultas composicional e imutável:
#
#   olinda("Expectativas", "v1")                    -> ODataService
#   endpoint(svc, "ExpectativaMercadoMensais")      -> ODataEndpoint
#   ep |> Where(...) |> Select(...) |> Top(10)      -> ODataQuery
#   execute(q)                                      -> BCBTable
#
# Filtros usam despacho múltiplo sobre `Base.Fix2`: os operadores parciais
# nativos de Julia (`>=(x)`, `in(xs)`, `contains(s)`, ...) são traduzidos
# para a sintaxe OData correspondente.
# ---------------------------------------------------------------------------

"""
    ODataService(base_url)
    olinda(name, version = "v1") -> ODataService

Um serviço OData. [`olinda`](@ref) constrói a URL-base padrão da plataforma
Olinda do BCB:

```julia
julia> olinda("Expectativas", "v1")
ODataService("https://olinda.bcb.gov.br/olinda/servico/Expectativas/versao/v1/odata")
```
"""
struct ODataService
    base::String
end

olinda(name::AbstractString, version::AbstractString = "v1") =
    ODataService("https://olinda.bcb.gov.br/olinda/servico/$(name)/versao/$(version)/odata")

"""
    ODataEndpoint
    endpoint(service, resource; kwargs...) -> ODataEndpoint

Um recurso (conjunto de entidades ou *função* OData) dentro de um serviço.
Argumentos nomeados viram parâmetros de função OData, renderizados como
literais (strings entre aspas, datas em ISO, etc.):

```julia
ep = endpoint(olinda("PTAX"), "CotacaoMoedaPeriodo";
              moeda = "USD", dataInicial = "01-01-2024", dataFinalCotacao = "06-30-2024")
```
"""
struct ODataEndpoint
    service::ODataService
    resource::String
    args::Vector{Pair{String, String}}   # parâmetros de função OData, já renderizados
end

ODataEndpoint(s::ODataService, resource::AbstractString) =
    ODataEndpoint(s, String(resource), Pair{String, String}[])

endpoint(s::ODataService, resource::AbstractString; kwargs...) =
    ODataEndpoint(s, String(resource),
                  Pair{String, String}[String(k) => literal(v) for (k, v) in kwargs])

"""
    ODataQuery

Uma consulta imutável sobre um [`ODataEndpoint`](@ref). Construída por
composição com [`Where`](@ref), [`Select`](@ref), [`OrderBy`](@ref),
[`Top`](@ref) e [`Skip`](@ref); executada com [`execute`](@ref).
"""
struct ODataQuery
    endpoint::ODataEndpoint
    params::Vector{Pair{String, String}}   # opções de sistema ($filter, $top, ...)
end

ODataQuery(ep::ODataEndpoint) = ODataQuery(ep, Pair{String, String}[])

const QueryLike = Union{ODataEndpoint, ODataQuery}

asquery(q::ODataQuery)     = q
asquery(ep::ODataEndpoint) = ODataQuery(ep)

function getparam(q::ODataQuery, key::AbstractString)
    for (k, v) in q.params
        k == key && return v
    end
    return nothing
end

function setparam(q::ODataQuery, key::String, value::String)
    ps = Pair{String, String}[p for p in q.params if first(p) != key]
    push!(ps, key => value)
    return ODataQuery(q.endpoint, ps)
end

# --------------------------------------------------------------------------
# Literais OData (despacho múltiplo por tipo de valor)
# --------------------------------------------------------------------------

"""
    literal(x) -> String

Renderiza um valor Julia como literal OData. Strings e datas são citadas
(aspas simples internas são duplicadas), números e booleanos vão em forma
crua. Estenda com novos métodos para tipos customizados.
"""
literal(x::AbstractString) = string("'", replace(String(x), "'" => "''"), "'")
literal(x::Symbol)         = literal(String(x))
literal(x::Bool)           = x ? "true" : "false"
literal(x::Integer)        = string(x)
literal(x::Real)           = string(convert(Float64, x))
literal(d::Date)           = string("'", Dates.format(d, dateformat"yyyy-mm-dd"), "'")
literal(d::DateTime)       = string("'", Dates.format(d, dateformat"yyyy-mm-ddTHH:MM:SS"), "'")

# --------------------------------------------------------------------------
# Cláusulas de filtro
#
# `:Data => >=(Date(2024))` usa o fato de `>=(x)` devolver `Base.Fix2(>=, x)`;
# despachamos sobre o tipo da função parcial para escolher o operador OData.
# --------------------------------------------------------------------------

const _CmpOp = Union{typeof(==), typeof(!=), typeof(<), typeof(<=), typeof(>), typeof(>=)}

_odata_op(::typeof(==)) = "eq"
_odata_op(::typeof(!=)) = "ne"
_odata_op(::typeof(<))  = "lt"
_odata_op(::typeof(<=)) = "le"
_odata_op(::typeof(>))  = "gt"
_odata_op(::typeof(>=)) = "ge"

"""
    clause(field, value) -> String

Renderiza uma cláusula de filtro OData. `value` pode ser:

  - um valor simples — igualdade: `clause(:Indicador, "IPCA")` → `"Indicador eq 'IPCA'"`
  - um comparador parcial — `>=(x)`, `<(x)`, `!=(x)`, ... → `ge`, `lt`, `ne`, ...
  - `in(xs)` — disjunção: `(campo eq a or campo eq b ...)`
  - `contains(s)`, `startswith(s)`, `endswith(s)` — funções de string OData v4
"""
clause(field::Symbol, value) = string(field, " eq ", literal(value))

clause(field::Symbol, f::Base.Fix2{<:_CmpOp}) =
    string(field, " ", _odata_op(f.f), " ", literal(f.x))

clause(field::Symbol, f::Base.Fix2{typeof(in)}) =
    string("(", join((string(field, " eq ", literal(v)) for v in f.x), " or "), ")")

clause(field::Symbol, f::Base.Fix2{typeof(contains)}) =
    string("contains(", field, ",", literal(f.x), ")")

clause(field::Symbol, f::Base.Fix2{typeof(startswith)}) =
    string("startswith(", field, ",", literal(f.x), ")")

clause(field::Symbol, f::Base.Fix2{typeof(endswith)}) =
    string("endswith(", field, ",", literal(f.x), ")")

# --------------------------------------------------------------------------
# Modificadores de consulta (functors composáveis via |>)
# --------------------------------------------------------------------------

"""
    Where(pares::Pair...)
    Where(expr::AbstractString)

Filtro (`\$filter`). Pares são combinados com `and`; aplicar `Where`
novamente a uma consulta que já tem filtro também combina com `and`.
A forma com string aceita uma expressão OData crua.

```julia
q |> Where(:Indicador => "IPCA", :Data => >=(Date(2025, 1, 1)))
q |> Where(:Indicador => in(["IPCA", "Selic"]))
q |> Where("baseCalculo eq 0")
```
"""
struct Where
    expr::String
end

Where(p1::Pair, rest::Pair...) =
    Where(join((clause(Symbol(first(p)), last(p)) for p in (p1, rest...)), " and "))

function (w::Where)(x::QueryLike)
    q = asquery(x)
    old = getparam(q, "\$filter")
    expr = old === nothing ? w.expr : "($old) and ($(w.expr))"
    return setparam(q, "\$filter", expr)
end

"""
    Select(cols...)

Projeção de colunas (`\$select`).

```julia
q |> Select(:Data, :Mediana)
```
"""
struct Select
    cols::Vector{Symbol}
end

Select(c1::Union{Symbol, AbstractString}, rest::Union{Symbol, AbstractString}...) =
    Select(Symbol[Symbol(c) for c in (c1, rest...)])

(s::Select)(x::QueryLike) = setparam(asquery(x), "\$select", join(s.cols, ","))

"""
    OrderBy(cols...)
    OrderBy(col => :asc | :desc, ...)

Ordenação (`\$orderby`).

```julia
q |> OrderBy(:Data)
q |> OrderBy(:Data => :desc, :Indicador => :asc)
```
"""
struct OrderBy
    expr::String
end

OrderBy(c1::Symbol, rest::Symbol...) = OrderBy(join(string.((c1, rest...)), ","))

function OrderBy(p1::Pair{Symbol, Symbol}, rest::Pair{Symbol, Symbol}...)
    pairs = (p1, rest...)
    for p in pairs
        last(p) in (:asc, :desc) ||
            throw(ArgumentError("direção deve ser :asc ou :desc, recebi :$(last(p))"))
    end
    return OrderBy(join((string(first(p), " ", last(p)) for p in pairs), ","))
end

(o::OrderBy)(x::QueryLike) = setparam(asquery(x), "\$orderby", o.expr)

"""
    Top(n)

Limita o número de registros (`\$top`).
"""
struct Top
    n::Int
    function Top(n::Integer)
        n > 0 || throw(ArgumentError("Top requer n > 0"))
        return new(Int(n))
    end
end

(t::Top)(x::QueryLike) = setparam(asquery(x), "\$top", string(t.n))

"""
    Skip(n)

Pula os primeiros `n` registros (`\$skip`).
"""
struct Skip
    n::Int
    function Skip(n::Integer)
        n >= 0 || throw(ArgumentError("Skip requer n >= 0"))
        return new(Int(n))
    end
end

(s::Skip)(x::QueryLike) = setparam(asquery(x), "\$skip", string(s.n))

# --------------------------------------------------------------------------
# URL e execução
# --------------------------------------------------------------------------

"""
    url(q) -> String

URL completa da consulta (útil para depuração).
"""
function url(x::QueryLike)
    q  = asquery(x)
    ep = q.endpoint
    io = IOBuffer()
    print(io, ep.service.base, "/", ep.resource)
    if !isempty(ep.args)
        print(io, "(", join((string(k, "=@", k) for (k, _) in ep.args), ","), ")")
    end
    params = Pair{String, String}[]
    for (k, v) in ep.args
        push!(params, string("@", k) => v)
    end
    append!(params, q.params)
    push!(params, "\$format" => "json")
    print(io, "?", querystring(params))
    return String(take!(io))
end

function _odata_values(q::ODataQuery)
    body = request(url(q))
    obj = try
        JSON3.read(body)
    catch e
        throw(BCBError("resposta OData inválida (JSON malformado)", e isa Exception ? e : nothing))
    end
    (obj isa JSON3.Object && haskey(obj, :value)) ||
        throw(BCBError("resposta OData inesperada: campo 'value' ausente"))
    return obj[:value]
end

"""
    execute(q; paginate = false, pagesize = 10_000, parsedates = true) -> BCBTable

Executa a consulta e devolve um [`BCBTable`](@ref).

  - `paginate = true` percorre o recurso inteiro em páginas de `pagesize`
    registros (usando `\$top`/`\$skip`), útil para conjuntos grandes como o
    histórico completo do Focus. Sobrescreve `Top`/`Skip` já presentes.
  - `parsedates = true` converte colunas de texto em `Date`/`DateTime` quando
    **todos** os valores não-faltantes casam com um formato temporal conhecido.
"""
function execute(x::QueryLike; paginate::Bool = false, pagesize::Integer = 10_000,
                 parsedates::Bool = true)
    q = asquery(x)
    rows = if paginate
        acc = Any[]
        offset = 0
        while true
            page = _odata_values(q |> Top(Int(pagesize)) |> Skip(offset))
            append!(acc, page)
            length(page) < pagesize && break
            offset += pagesize
        end
        acc
    else
        _odata_values(q)
    end
    t = _table(rows)
    return parsedates ? _parsetemporal(t) : t
end

# --------------------------------------------------------------------------
# Materialização em colunas
# --------------------------------------------------------------------------

_cell(x)          = x
_cell(::Nothing)  = missing
_cell(::Missing)  = missing

# Estreita Vector{Any} para o menor eltype concreto; colunas numéricas mistas
# (Int + Float) são promovidas a Float64.
function _finalizecol(raw::Vector{Any})
    col = map(identity, raw)
    T = Base.nonmissingtype(eltype(col))
    if T !== Union{} && T <: Real && T !== Bool && !isconcretetype(T)
        col = map(x -> x === missing ? missing : Float64(x), col)
    end
    return col
end

function _table(rows)
    isempty(rows) && return BCBTable(Symbol[], AbstractVector[])
    names = collect(Symbol, keys(first(rows)))
    cols = Vector{AbstractVector}(undef, length(names))
    for (j, nm) in enumerate(names)
        raw = Vector{Any}(undef, length(rows))
        for (i, row) in enumerate(rows)
            raw[i] = _cell(get(row, nm, missing))
        end
        cols[j] = _finalizecol(raw)
    end
    return BCBTable(names, cols)
end

# --------------------------------------------------------------------------
# Conversão automática de colunas temporais
# --------------------------------------------------------------------------

const _DATE_RE = r"^\d{4}-\d{2}-\d{2}$"

const _DATETIME_FORMATS = (
    dateformat"yyyy-mm-dd HH:MM:SS.s",
    dateformat"yyyy-mm-dd HH:MM:SS",
    dateformat"yyyy-mm-ddTHH:MM:SS.s",
    dateformat"yyyy-mm-ddTHH:MM:SS",
)

_maybetemporal(col::AbstractVector) = col

function _maybetemporal(col::AbstractVector{<:Union{Missing, String}})
    vals = collect(skipmissing(col))
    isempty(vals) && return col
    if all(v -> occursin(_DATE_RE, v), vals)
        return map(x -> x === missing ? missing : Date(x), col)
    end
    for fmt in _DATETIME_FORMATS
        if all(v -> tryparse(DateTime, v, fmt) !== nothing, vals)
            return map(x -> x === missing ? missing : DateTime(x, fmt), col)
        end
    end
    return col
end

function _parsetemporal(t::BCBTable)
    names = getfield(t, :names)
    cols  = getfield(t, :columns)
    return BCBTable(names, AbstractVector[_maybetemporal(c) for c in cols])
end
