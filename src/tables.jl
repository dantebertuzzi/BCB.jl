# ---------------------------------------------------------------------------
# BCBTable — resultado tabular genérico
#
# Um contêiner colunar leve que implementa a interface Tables.jl, de modo que
# qualquer resultado do pacote possa ser materializado com DataFrame(t),
# CSV.write("f.csv", t), etc., sem que BCB.jl dependa de DataFrames.
# ---------------------------------------------------------------------------

"""
    BCBTable

Tabela colunar imutável devolvida pelas consultas OData (e pelo `join` de
múltiplas séries do SGS). Implementa a interface Tables.jl:

```julia
using DataFrames
df = DataFrame(execute(q))
```

Colunas podem ser acessadas por propriedade (`t.Mediana`), por
`Tables.getcolumn(t, :Mediana)` ou por índice.
"""
struct BCBTable
    names::Vector{Symbol}
    columns::Vector{AbstractVector}

    function BCBTable(names, columns)
        nms  = collect(Symbol, names)
        cols = collect(AbstractVector, columns)
        length(nms) == length(cols) ||
            throw(ArgumentError("número de nomes ($(length(nms))) difere do número de colunas ($(length(cols)))"))
        if !isempty(cols)
            n = length(first(cols))
            all(c -> length(c) == n, cols) ||
                throw(ArgumentError("todas as colunas devem ter o mesmo comprimento"))
        end
        allunique(nms) || throw(ArgumentError("nomes de colunas duplicados"))
        return new(nms, cols)
    end
end

# -- dimensões --------------------------------------------------------------

function Base.size(t::BCBTable)
    cols = getfield(t, :columns)
    nr = isempty(cols) ? 0 : length(first(cols))
    return (nr, length(cols))
end
Base.size(t::BCBTable, d::Integer) = size(t)[d]
Base.isempty(t::BCBTable) = size(t, 1) == 0

# -- acesso por propriedade --------------------------------------------------

function Base.getproperty(t::BCBTable, s::Symbol)
    (s === :names || s === :columns) && return getfield(t, s)
    return Tables.getcolumn(t, s)
end
Base.propertynames(t::BCBTable, private::Bool = false) = copy(getfield(t, :names))

# -- interface Tables.jl ------------------------------------------------------

Tables.istable(::Type{BCBTable})      = true
Tables.columnaccess(::Type{BCBTable}) = true
Tables.columns(t::BCBTable)           = t
Tables.columnnames(t::BCBTable)       = getfield(t, :names)
Tables.getcolumn(t::BCBTable, i::Int) = getfield(t, :columns)[i]

function Tables.getcolumn(t::BCBTable, nm::Symbol)
    i = findfirst(==(nm), getfield(t, :names))
    i === nothing && throw(ArgumentError("coluna $nm não encontrada; disponíveis: $(join(getfield(t, :names), ", "))"))
    return getfield(t, :columns)[i]
end

Tables.schema(t::BCBTable) =
    Tables.Schema(getfield(t, :names), map(eltype, getfield(t, :columns)))

# -- exibição -----------------------------------------------------------------

function _compacttype(::Type{T}) where {T}
    if T isa Union && Missing <: T
        return string(_compacttype(Base.nonmissingtype(T)), "?")
    end
    return string(T)
end

function _showcell(x)
    x === missing && return "missing"
    s = sprint(print, x)
    return textwidth(s) > 32 ? string(first(s, 31), "…") : s
end

Base.show(io::IO, t::BCBTable) = print(io, "BCBTable(", size(t, 1), "×", size(t, 2), ")")

function Base.show(io::IO, ::MIME"text/plain", t::BCBTable)
    nr, nc = size(t)
    print(io, nr, "×", nc, " BCBTable")
    (nc == 0 || nr == 0) && return nothing

    names = getfield(t, :names)
    cols  = getfield(t, :columns)
    nshow = min(nr, 8)

    header = string.(names)
    types  = [_compacttype(eltype(c)) for c in cols]
    cells  = [_showcell(cols[j][i]) for i in 1:nshow, j in 1:nc]
    widths = [max(textwidth(header[j]), textwidth(types[j]),
                  maximum(textwidth(cells[i, j]) for i in 1:nshow; init = 0))
              for j in 1:nc]

    println(io)
    println(io, " ", join((rpad(header[j], widths[j]) for j in 1:nc), "  "))
    println(io, " ", join((rpad(types[j], widths[j]) for j in 1:nc), "  "))
    for i in 1:nshow
        print(io, " ", join((rpad(cells[i, j], widths[j]) for j in 1:nc), "  "))
        i < nshow && println(io)
    end
    nr > nshow && print(io, "\n ⋮ (", nr - nshow, " linhas omitidas)")
    return nothing
end
