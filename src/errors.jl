# ---------------------------------------------------------------------------
# Erros
# ---------------------------------------------------------------------------

"""
    BCBError(msg [, cause])

Erro levantado pelo pacote quando uma requisição às APIs do BCB falha ou
quando a resposta não tem o formato esperado. O campo `cause` preserva a
exceção original (por exemplo, um `Downloads.RequestError`), quando houver.
"""
struct BCBError <: Exception
    msg::String
    cause::Union{Nothing, Exception}
end

BCBError(msg::AbstractString) = BCBError(String(msg), nothing)

function Base.showerror(io::IO, e::BCBError)
    print(io, "BCBError: ", e.msg)
    if e.cause !== nothing
        print(io, "\n  causado por: ")
        showerror(io, e.cause)
    end
    return nothing
end
