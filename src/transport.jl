# ---------------------------------------------------------------------------
# Camada de transporte
#
# Toda a comunicação com as APIs do BCB passa por `request(transport, url)`.
# Isso permite trocar a implementação — para testes (mock), caching, proxies,
# ou um cliente baseado em HTTP.jl — sem tocar no restante do pacote.
# ---------------------------------------------------------------------------

"""
    AbstractTransport

Supertipo da camada de transporte. Para criar um transporte customizado,
defina um subtipo e estenda [`BCB.request`](@ref):

```julia
struct MeuTransporte <: BCB.AbstractTransport end

function BCB.request(t::MeuTransporte, url::AbstractString)
    # ... devolve o corpo da resposta como String
end
```

Ative-o globalmente com [`set_transport!`](@ref) ou por escopo com
[`with_transport`](@ref).
"""
abstract type AbstractTransport end

"""
    DownloadsTransport(; retries = 3, timeout = 60.0, headers = ...)

Transporte padrão, baseado na biblioteca padrão `Downloads` (libcurl) —
nenhuma dependência externa. Refaz automaticamente requisições que falharem
por erros transitórios (conexão, timeout, HTTP 429/5xx) com *backoff*
exponencial; erros 4xx são propagados imediatamente.
"""
Base.@kwdef struct DownloadsTransport <: AbstractTransport
    retries::Int = 3
    timeout::Float64 = 60.0
    headers::Dict{String, String} = Dict(
        "User-Agent" => "BCB.jl/$(PKG_VERSION) (https://github.com/dantebertuzzi/BCB.jl)",
        "Accept"     => "application/json",
    )
end

# Um erro é transitório se for de conexão/timeout (status 0) ou se o servidor
# sinalizar sobrecarga (429) ou falha interna (5xx).
_istransient(::Any) = false
function _istransient(e::Downloads.RequestError)
    status = e.response.status
    return status == 0 || status == 429 || status >= 500
end

"""
    request(transport, url) -> String
    request(url) -> String

Executa um GET em `url` e devolve o corpo da resposta como `String`.
A forma de um argumento usa o transporte global corrente
(veja [`set_transport!`](@ref) e [`with_transport`](@ref)).
"""
function request(t::DownloadsTransport, url::AbstractString)
    local err = nothing
    attempts = max(t.retries, 1)
    for attempt in 1:attempts
        buf = IOBuffer()
        try
            Downloads.download(url, buf; timeout = t.timeout, headers = t.headers)
            return String(take!(buf))
        catch e
            err = e
            # 4xx: erro do cliente, não adianta repetir.
            if e isa Downloads.RequestError && !_istransient(e)
                break
            end
            attempt < attempts && sleep(min(0.5 * 2.0^(attempt - 1), 8.0))
        end
    end
    throw(BCBError("requisição a $url falhou", err isa Exception ? err : nothing))
end

# --------------------------------------------------------------------------
# Transporte global (padrão) e escopo temporário
# --------------------------------------------------------------------------

const _TRANSPORT = Ref{AbstractTransport}(DownloadsTransport())

"Devolve o transporte global corrente."
current_transport() = _TRANSPORT[]

"""
    set_transport!(t::AbstractTransport)

Define o transporte global usado por todas as chamadas do pacote.
"""
set_transport!(t::AbstractTransport) = (_TRANSPORT[] = t)

"""
    with_transport(f, t::AbstractTransport)

Executa `f()` com `t` como transporte corrente, restaurando o anterior ao
final (mesmo em caso de erro). Útil em testes:

```julia
with_transport(MockTransport(...)) do
    sgs(433)
end
```
"""
function with_transport(f::Function, t::AbstractTransport)
    old = _TRANSPORT[]
    _TRANSPORT[] = t
    try
        return f()
    finally
        _TRANSPORT[] = old
    end
end

request(url::AbstractString) = request(current_transport(), url)

# --------------------------------------------------------------------------
# Utilitários de URL
# --------------------------------------------------------------------------

const _UNRESERVED = Set{Char}(vcat('A':'Z', 'a':'z', '0':'9', ['-', '_', '.', '~']))

"""
    escapeuri(s) -> String

Codificação percentual (RFC 3986) de um componente de URL. Bytes UTF-8 fora
do conjunto não-reservado são escapados individualmente.
"""
function escapeuri(s::AbstractString)
    io = IOBuffer()
    for b in codeunits(String(s))
        c = Char(b)
        if c in _UNRESERVED
            write(io, b)
        else
            print(io, '%', uppercase(string(b, base = 16, pad = 2)))
        end
    end
    return String(take!(io))
end

"""
    querystring(params) -> String

Monta a *query string* a partir de pares `chave => valor` (ambos `String`),
preservando a ordem e escapando chaves e valores.
"""
querystring(params) =
    join(("$(escapeuri(k))=$(escapeuri(v))" for (k, v) in params), "&")
