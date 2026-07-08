# ---------------------------------------------------------------------------
# SGS — Sistema Gerenciador de Séries Temporais
#
# API JSON simples:
#   https://api.bcb.gov.br/dados/serie/bcdata.sgs.{código}/dados?formato=json
#
# A API limita consultas com filtro de datas a janelas de 10 anos (para
# séries diárias); `sgs` particiona automaticamente intervalos maiores em
# janelas contíguas e concatena os resultados.
# ---------------------------------------------------------------------------

const _SGS_BASE = "https://api.bcb.gov.br/dados/serie/bcdata.sgs."
const _SGS_DATEFORMAT = dateformat"dd/mm/yyyy"
const _SGS_MAXSPAN = Year(10)

"""
    SGSSeries{T}

Série temporal do SGS. O parâmetro `T` reflete a presença de valores
faltantes: `Float64` quando a série é completa, `Union{Missing, Float64}`
caso contrário — detectável estaticamente via despacho.

Campos: `code::Int`, `name::Symbol`, `dates::Vector{Date}`, `values::Vector{T}`.

Implementa a interface Tables.jl (colunas `:date` e `name`) e o protocolo de
iteração (elementos `(date = ..., value = ...)`):

```julia
s = sgs(:ipca => 433; start = 2020)
DataFrame(s)
maximum(r.value for r in s if !ismissing(r.value))
```
"""
struct SGSSeries{T}
    code::Int
    name::Symbol
    dates::Vector{Date}
    values::Vector{T}

    function SGSSeries(code::Integer, name::Symbol,
                       dates::Vector{Date}, values::Vector{T}) where {T}
        length(dates) == length(values) ||
            throw(ArgumentError("dates e values devem ter o mesmo comprimento"))
        return new{T}(Int(code), name, dates, values)
    end
end

# -- protocolo de iteração / indexação ---------------------------------------

Base.length(s::SGSSeries) = length(s.dates)
Base.isempty(s::SGSSeries) = isempty(s.dates)
Base.firstindex(s::SGSSeries) = 1
Base.lastindex(s::SGSSeries) = length(s)
Base.eltype(::Type{SGSSeries{T}}) where {T} = @NamedTuple{date::Date, value::T}
Base.getindex(s::SGSSeries, i::Integer) = (date = s.dates[i], value = s.values[i])

function Base.iterate(s::SGSSeries, i::Int = 1)
    i > length(s) && return nothing
    return (s[i], i + 1)
end

# -- interface Tables.jl -------------------------------------------------------

Tables.istable(::Type{<:SGSSeries})      = true
Tables.columnaccess(::Type{<:SGSSeries}) = true
Tables.columns(s::SGSSeries)             = s
Tables.columnnames(s::SGSSeries)         = (:date, s.name)

Tables.getcolumn(s::SGSSeries, i::Int) =
    i == 1 ? s.dates : i == 2 ? s.values : throw(BoundsError(s, i))

function Tables.getcolumn(s::SGSSeries, nm::Symbol)
    nm === :date && return s.dates
    nm === s.name && return s.values
    throw(ArgumentError("coluna $nm não encontrada; disponíveis: :date, :$(s.name)"))
end

Tables.schema(s::SGSSeries{T}) where {T} = Tables.Schema((:date, s.name), (Date, T))

# -- exibição ------------------------------------------------------------------

const _BLOCKS = ('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')

"""
    _sparkline(values; width = 48) -> String

Sparkline Unicode dos valores (média por bin); bins sem valores viram espaço.
"""
function _sparkline(values::AbstractVector; width::Int = 48)
    n = length(values)
    n == 0 && return ""
    nb = min(width, n)
    means = Vector{Union{Missing, Float64}}(missing, nb)
    for b in 1:nb
        lo = fld((b - 1) * n, nb) + 1
        hi = fld(b * n, nb)
        xs = collect(skipmissing(view(values, lo:hi)))
        isempty(xs) || (means[b] = sum(xs) / length(xs))
    end
    finite = collect(skipmissing(means))
    isempty(finite) && return " "^nb
    lo, hi = extrema(finite)
    io = IOBuffer()
    for m in means
        if m === missing
            print(io, ' ')
        elseif hi == lo
            print(io, _BLOCKS[4])
        else
            k = clamp(1 + floor(Int, (m - lo) / (hi - lo) * 8), 1, 8)
            print(io, _BLOCKS[k])
        end
    end
    return String(take!(io))
end

Base.show(io::IO, s::SGSSeries{T}) where {T} =
    print(io, "SGSSeries{", T, "}(:", s.name, ", ", length(s), " obs)")

function Base.show(io::IO, ::MIME"text/plain", s::SGSSeries{T}) where {T}
    n = length(s)
    print(io, "SGSSeries{", T, "} :", s.name, " (SGS ", s.code, "), ", n,
          n == 1 ? " observação" : " observações")
    n == 0 && return nothing
    print(io, "\n  ", first(s.dates), " … ", last(s.dates))
    spark = _sparkline(s.values)
    isempty(strip(spark)) || print(io, "\n  ", spark)
    i = findlast(!ismissing, s.values)
    i === nothing || print(io, "\n  último valor: ", s.values[i], " em ", s.dates[i])
    return nothing
end

# -- URLs e parsing ------------------------------------------------------------

function _sgs_url(code::Integer; start::Union{Nothing, Date} = nothing,
                  stop::Union{Nothing, Date} = nothing,
                  last::Union{Nothing, Int} = nothing)
    base = string(_SGS_BASE, Int(code))
    last !== nothing && return string(base, "/dados/ultimos/", last, "?formato=json")
    u = string(base, "/dados?formato=json")
    start !== nothing &&
        (u = string(u, "&dataInicial=", escapeuri(Dates.format(start, _SGS_DATEFORMAT))))
    stop !== nothing &&
        (u = string(u, "&dataFinal=", escapeuri(Dates.format(stop, _SGS_DATEFORMAT))))
    return u
end

_sgs_value(::Nothing) = missing
_sgs_value(::Missing) = missing
_sgs_value(x::Real)   = Float64(x)

function _sgs_value(x::AbstractString)
    s = strip(x)
    isempty(s) && return missing
    v = tryparse(Float64, s)
    v === nothing && throw(BCBError("valor SGS não numérico: $(repr(String(x)))"))
    return v
end

function _parse_sgs(arr)
    n = length(arr)
    dates = Vector{Date}(undef, n)
    vals  = Vector{Union{Missing, Float64}}(undef, n)
    for (i, row) in enumerate(arr)
        haskey(row, :data) || throw(BCBError("registro SGS sem o campo 'data'"))
        dates[i] = Date(String(row[:data]), _SGS_DATEFORMAT)
        vals[i]  = _sgs_value(get(row, :valor, missing))
    end
    values = any(ismissing, vals) ? vals : convert(Vector{Float64}, vals)
    return dates, values
end

function _request_sgs(u::AbstractString)
    body = request(u)
    arr = try
        JSON3.read(body)
    catch e
        throw(BCBError("resposta inesperada da API SGS (não é JSON); a série existe?",
                       e isa Exception ? e : nothing))
    end
    arr isa JSON3.Array ||
        throw(BCBError("resposta inesperada da API SGS (esperava um array JSON)"))
    return _parse_sgs(arr)
end

# Janelas contíguas de no máximo `maxspan`, cobrindo [a, b].
function _sgs_windows(a::Date, b::Date; maxspan::Period = _SGS_MAXSPAN)
    a > b && throw(ArgumentError("start ($a) posterior a stop ($b)"))
    ws = Tuple{Date, Date}[]
    s = a
    while s <= b
        e = min(s + maxspan - Day(1), b)
        push!(ws, (s, e))
        s = e + Day(1)
    end
    return ws
end

# -- API pública ----------------------------------------------------------------

"""
    sgs(code; start = nothing, stop = nothing, last = nothing, name = Symbol("sgs", code))
    sgs(name => code; ...)
    sgs(spec1, spec2, specs...; ...) -> BCBTable

Baixa séries do SGS (Sistema Gerenciador de Séries Temporais).

  - `code`: código numérico da série (ex.: 433 = IPCA, 432 = meta Selic,
    12 = CDI, 1 = dólar PTAX venda).
  - `start` / `stop`: limites do período. Aceitam `Date`, string ISO
    (`"2020-01-01"`) ou ano inteiro (`2020` ≡ `Date(2020, 1, 1)`).
  - `last`: em vez de um período, devolve as últimas `n` observações
    (exclusivo com `start`/`stop`).
  - `name`: nome da coluna de valores (padrão `:sgsCODE`); a forma
    `sgs(:ipca => 433)` é um atalho para nomear.

Uma única série devolve [`SGSSeries`](@ref); duas ou mais devolvem um
[`BCBTable`](@ref) com junção externa pela coluna `:date` (datas ausentes em
alguma série viram `missing`).

Períodos maiores que 10 anos são particionados automaticamente em janelas
contíguas (limite da API para séries diárias) e concatenados.

```julia
sgs(433)                                     # IPCA, histórico completo
sgs(:selic => 432; start = 2010, stop = 2020)
sgs(433; last = 12)                          # últimas 12 observações
sgs(:ipca => 433, :inpc => 188; start = 2015) |> DataFrame
```
"""
function sgs(code::Integer; start = nothing, stop = nothing, last = nothing,
             name::Symbol = Symbol("sgs", Int(code)))
    if last !== nothing
        (start === nothing && stop === nothing) ||
            throw(ArgumentError("`last` é exclusivo com `start`/`stop`"))
        last isa Integer && last > 0 ||
            throw(ArgumentError("`last` deve ser um inteiro positivo"))
        dates, values = _request_sgs(_sgs_url(code; last = Int(last)))
        return SGSSeries(code, name, dates, values)
    end

    a = start === nothing ? nothing : Date(start)
    b = stop === nothing ? nothing : Date(stop)

    if a === nothing
        dates, values = _request_sgs(_sgs_url(code; stop = b))
        return SGSSeries(code, name, dates, values)
    end

    windows = _sgs_windows(a, something(b, Dates.today()))
    if length(windows) == 1
        dates, values = _request_sgs(_sgs_url(code; start = a, stop = b))
        return SGSSeries(code, name, dates, values)
    end

    dates = Date[]
    vals  = Union{Missing, Float64}[]
    for (s, e) in windows
        d, v = _request_sgs(_sgs_url(code; start = s, stop = e))
        append!(dates, d)
        append!(vals, v)
    end
    return SGSSeries(code, name, dates, map(identity, vals))
end

const _SGSNameLike = Union{Symbol, AbstractString}

sgs(p::Pair{<:_SGSNameLike, <:Integer}; kwargs...) =
    sgs(last(p); name = Symbol(first(p)), kwargs...)

const _SGSSpec = Union{Integer, Pair{<:_SGSNameLike, <:Integer}}

function sgs(s1::_SGSSpec, s2::_SGSSpec, rest::_SGSSpec...; kwargs...)
    series = SGSSeries[sgs(s; kwargs...) for s in (s1, s2, rest...)]
    return _joinseries(series)
end

# Junção externa por data de múltiplas séries.
function _joinseries(series::AbstractVector{<:SGSSeries})
    alldates = sort!(unique(vcat((s.dates for s in series)...)))
    names = Symbol[:date]
    cols = AbstractVector[alldates]
    for s in series
        idx = Dict{Date, Int}(d => i for (i, d) in enumerate(s.dates))
        col = Vector{Union{Missing, Float64}}(missing, length(alldates))
        for (j, d) in enumerate(alldates)
            i = get(idx, d, 0)
            i == 0 || (col[j] = s.values[i])
        end
        push!(names, s.name)
        push!(cols, map(identity, col))
    end
    return BCBTable(names, cols)
end
