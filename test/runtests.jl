using BCB
using Dates
using Tables
using Test

# ---------------------------------------------------------------------------
# Transporte mockado: demonstra o ponto de extensão da camada de transporte
# e permite rodar toda a suíte sem acesso à rede.
# ---------------------------------------------------------------------------

struct MockTransport <: BCB.AbstractTransport
    routes::Vector{Pair{String, String}}   # fragmento de URL => corpo
    calls::Vector{String}
end

MockTransport(routes::Pair{String, String}...) =
    MockTransport(Pair{String, String}[routes...], String[])

function BCB.request(m::MockTransport, url::AbstractString)
    push!(m.calls, String(url))
    for (frag, body) in m.routes
        occursin(frag, url) && return body
    end
    error("MockTransport: nenhuma rota para $url")
end

# -- corpos de resposta -------------------------------------------------------

const SGS_BODY = """
[{"data":"01/01/2024","valor":"1.5"},
 {"data":"01/02/2024","valor":""},
 {"data":"01/03/2024","valor":"2.25"}]"""

const SGS_BODY_FULL = """
[{"data":"01/01/2024","valor":"1.0"},
 {"data":"01/02/2024","valor":"2.0"}]"""

const ODATA_BODY = """
{"@odata.context":"ctx",
 "value":[
   {"Indicador":"IPCA","Data":"2024-01-05","Mediana":3.9,"numeroRespondentes":85},
   {"Indicador":"IPCA","Data":"2024-01-12","Mediana":3.85,"numeroRespondentes":90}]}"""

const PTAX_BODY = """
{"@odata.context":"ctx",
 "value":[
   {"cotacaoCompra":4.85,"cotacaoVenda":4.86,
    "dataHoraCotacao":"2024-01-02 13:09:02.871","tipoBoletim":"Fechamento"}]}"""

@testset "BCB.jl" begin

    @testset "escapeuri e querystring" begin
        @test BCB.escapeuri("abc-_.~") == "abc-_.~"
        @test BCB.escapeuri("a b") == "a%20b"
        @test BCB.escapeuri("ç") == "%C3%A7"
        @test BCB.escapeuri("'IPCA'") == "%27IPCA%27"
        @test BCB.querystring(["\$top" => "5", "a" => "b c"]) == "%24top=5&a=b%20c"
    end

    @testset "literais OData" begin
        @test BCB.literal("IPCA") == "'IPCA'"
        @test BCB.literal("d'or") == "'d''or'"
        @test BCB.literal(:USD) == "'USD'"
        @test BCB.literal(5) == "5"
        @test BCB.literal(2.5) == "2.5"
        @test BCB.literal(true) == "true"
        @test BCB.literal(false) == "false"
        @test BCB.literal(Date(2024, 1, 2)) == "'2024-01-02'"
        @test BCB.literal(DateTime(2024, 1, 2, 13, 9, 2)) == "'2024-01-02T13:09:02'"
    end

    @testset "cláusulas de filtro (despacho sobre Fix2)" begin
        @test BCB.clause(:Indicador, "IPCA") == "Indicador eq 'IPCA'"
        @test BCB.clause(:Indicador, ==("IPCA")) == "Indicador eq 'IPCA'"
        @test BCB.clause(:Data, >=(Date(2024, 1, 1))) == "Data ge '2024-01-01'"
        @test BCB.clause(:Data, <(Date(2025, 1, 1))) == "Data lt '2025-01-01'"
        @test BCB.clause(:Data, <=(Date(2025, 1, 1))) == "Data le '2025-01-01'"
        @test BCB.clause(:Data, >(Date(2025, 1, 1))) == "Data gt '2025-01-01'"
        @test BCB.clause(:Mediana, !=(0)) == "Mediana ne 0"
        @test BCB.clause(:Indicador, in(["IPCA", "Selic"])) ==
              "(Indicador eq 'IPCA' or Indicador eq 'Selic')"
        @test BCB.clause(:Indicador, contains("PCA")) == "contains(Indicador,'PCA')"
        @test BCB.clause(:Indicador, startswith("IP")) == "startswith(Indicador,'IP')"
        @test BCB.clause(:Indicador, endswith("CA")) == "endswith(Indicador,'CA')"
    end

    @testset "construção de URL OData" begin
        svc = olinda("Expectativas", "v1")
        @test svc.base ==
              "https://olinda.bcb.gov.br/olinda/servico/Expectativas/versao/v1/odata"

        q = endpoint(svc, "ExpectativaMercadoMensais") |>
            Where(:Indicador => ==("IPCA"), :Data => >=(Date(2024, 1, 1))) |>
            Select(:Data, :Mediana) |>
            OrderBy(:Data => :desc) |>
            Top(10)
        u = BCB.url(q)

        @test startswith(u,
            "https://olinda.bcb.gov.br/olinda/servico/Expectativas/versao/v1/odata/ExpectativaMercadoMensais?")
        @test occursin("%24filter=Indicador%20eq%20%27IPCA%27%20and%20Data%20ge%20%272024-01-01%27", u)
        @test occursin("%24select=Data%2CMediana", u)
        @test occursin("%24orderby=Data%20desc", u)
        @test occursin("%24top=10", u)
        @test occursin("%24format=json", u)

        # Where adicional compõe com "and"
        q2 = q |> Where("baseCalculo eq 0")
        @test occursin("%29%20and%20%28baseCalculo%20eq%200%29", BCB.url(q2))

        # setparam substitui em vez de duplicar
        q3 = q |> Top(99)
        @test occursin("%24top=99", BCB.url(q3))
        @test !occursin("%24top=10", BCB.url(q3))

        # validações
        @test_throws MethodError Where()
        @test_throws MethodError Select()
        @test_throws ArgumentError OrderBy(:Data => :sideways)
        @test_throws ArgumentError Top(0)
        @test_throws ArgumentError Skip(-1)
    end

    @testset "endpoint com parâmetros (função OData / PTAX)" begin
        ep = BCB.currency_endpoint("usd", Date(2024, 1, 1), Date(2024, 1, 31))
        u = BCB.url(ep)
        @test occursin(
            "CotacaoMoedaPeriodo(moeda=@moeda,dataInicial=@dataInicial,dataFinalCotacao=@dataFinalCotacao)?",
            u)
        @test occursin("%40moeda=%27USD%27", u)
        @test occursin("%40dataInicial=%2701-01-2024%27", u)
        @test occursin("%40dataFinalCotacao=%2701-31-2024%27", u)
    end

    @testset "execute + BCBTable + Tables.jl + parsedates" begin
        mock = MockTransport("ExpectativaMercadoMensais" => ODATA_BODY)
        t = with_transport(mock) do
            execute(expectations(:monthly, :Indicador => "IPCA") |> Top(2))
        end
        @test t isa BCBTable
        @test size(t) == (2, 4)
        @test size(t, 1) == 2 && size(t, 2) == 4
        @test !isempty(t)
        @test Tables.istable(t)
        @test Tables.columnnames(t) == [:Indicador, :Data, :Mediana, :numeroRespondentes]

        ct = Tables.columntable(t)
        @test ct.Indicador == ["IPCA", "IPCA"]
        @test ct.Data == [Date(2024, 1, 5), Date(2024, 1, 12)]      # parse automático
        @test ct.Mediana == [3.9, 3.85]
        @test eltype(ct.Mediana) == Float64
        @test eltype(ct.numeroRespondentes) == Int64

        @test t.Mediana == [3.9, 3.85]                              # getproperty
        @test propertynames(t) == [:Indicador, :Data, :Mediana, :numeroRespondentes]
        @test_throws ArgumentError Tables.getcolumn(t, :nope)

        sch = Tables.schema(t)
        @test sch.names == (:Indicador, :Data, :Mediana, :numeroRespondentes)

        @test length(mock.calls) == 1
        @test occursin("%24top=2", mock.calls[1])
        @test occursin("Indicador%20eq%20%27IPCA%27", mock.calls[1])

        # parsedates = false preserva strings
        t2 = with_transport(mock) do
            execute(expectations(:monthly); parsedates = false)
        end
        @test t2.Data == ["2024-01-05", "2024-01-12"]

        # show não explode
        @test occursin("BCBTable", sprint(show, MIME"text/plain"(), t))
        @test occursin("BCBTable", sprint(show, t))
    end

    @testset "paginação" begin
        mock = MockTransport(
            "%24skip=0" => """{"value":[{"a":1},{"a":2}]}""",
            "%24skip=2" => """{"value":[{"a":3}]}""",
        )
        t = with_transport(mock) do
            execute(expectations(:monthly); paginate = true, pagesize = 2)
        end
        @test size(t) == (3, 1)
        @test t.a == [1, 2, 3]
        @test length(mock.calls) == 2
    end

    @testset "tabela vazia e coluna numérica mista" begin
        mock = MockTransport("Moedas" => """{"value":[]}""")
        t = with_transport(mock) do
            currencies()
        end
        @test size(t) == (0, 0)

        mock2 = MockTransport("Moedas" => """{"value":[{"x":1},{"x":2.5},{"x":null}]}""")
        t2 = with_transport(mock2) do
            currencies()
        end
        @test eltype(t2.x) == Union{Missing, Float64}
        @test isequal(t2.x, [1.0, 2.5, missing])
    end

    @testset "SGS: URLs" begin
        @test BCB._sgs_url(433) ==
              "https://api.bcb.gov.br/dados/serie/bcdata.sgs.433/dados?formato=json"
        @test BCB._sgs_url(433; last = 12) ==
              "https://api.bcb.gov.br/dados/serie/bcdata.sgs.433/dados/ultimos/12?formato=json"
        u = BCB._sgs_url(433; start = Date(2024, 1, 1), stop = Date(2024, 6, 30))
        @test occursin("dataInicial=01%2F01%2F2024", u)
        @test occursin("dataFinal=30%2F06%2F2024", u)
    end

    @testset "SGS: parse, missings e Tables.jl" begin
        mock = MockTransport("bcdata.sgs.433" => SGS_BODY)
        s = with_transport(mock) do
            sgs(:ipca => 433; start = Date(2024, 1, 1), stop = Date(2024, 3, 31))
        end
        @test s isa SGSSeries
        @test s.name === :ipca
        @test s.code == 433
        @test length(s) == 3
        @test s.dates == [Date(2024, 1, 1), Date(2024, 2, 1), Date(2024, 3, 1)]
        @test s.values[1] == 1.5
        @test ismissing(s.values[2])
        @test s.values[3] == 2.25
        @test eltype(s.values) == Union{Missing, Float64}
        @test s isa SGSSeries{Union{Missing, Float64}}     # tipagem paramétrica

        # Tables.jl
        @test Tables.istable(typeof(s))
        ct = Tables.columntable(s)
        @test collect(keys(ct)) == [:date, :ipca]
        @test ct.date == s.dates
        @test Tables.schema(s).names == (:date, :ipca)

        # iteração
        row = first(s)
        @test row.date == Date(2024, 1, 1) && row.value == 1.5
        @test length(collect(s)) == 3
        @test s[end].value == 2.25

        # show com sparkline não explode
        @test occursin("SGSSeries", sprint(show, MIME"text/plain"(), s))
    end

    @testset "SGS: série completa estreita o parâmetro de tipo" begin
        mock = MockTransport("bcdata.sgs.1" => SGS_BODY_FULL)
        s = with_transport(mock) do
            sgs(1)
        end
        @test s isa SGSSeries{Float64}          # sem missing → Float64
        @test s.name === :sgs1
        @test length(mock.calls) == 1
        @test !occursin("dataInicial", mock.calls[1])
    end

    @testset "SGS: last e validações" begin
        mock = MockTransport("ultimos/12" => SGS_BODY_FULL)
        s = with_transport(mock) do
            sgs(433; last = 12)
        end
        @test length(s) == 2
        @test occursin("/dados/ultimos/12?formato=json", mock.calls[1])
        @test_throws ArgumentError sgs(433; last = 12, start = Date(2024, 1, 1))
    end

    @testset "SGS: chunking automático (> 10 anos)" begin
        mock = MockTransport("bcdata.sgs.12" => SGS_BODY_FULL)
        s = with_transport(mock) do
            sgs(12; start = Date(2000, 1, 1), stop = Date(2025, 12, 31))
        end
        @test length(mock.calls) == 3
        @test occursin("dataInicial=01%2F01%2F2000", mock.calls[1])
        @test occursin("dataFinal=31%2F12%2F2009", mock.calls[1])
        @test occursin("dataInicial=01%2F01%2F2010", mock.calls[2])
        @test occursin("dataFinal=31%2F12%2F2019", mock.calls[2])
        @test occursin("dataInicial=01%2F01%2F2020", mock.calls[3])
        @test occursin("dataFinal=31%2F12%2F2025", mock.calls[3])
        @test length(s) == 6

        # janelas contíguas e sem sobreposição
        ws = BCB._sgs_windows(Date(2000, 1, 1), Date(2025, 12, 31))
        @test first(ws) == (Date(2000, 1, 1), Date(2009, 12, 31))
        @test all(ws[i + 1][1] == ws[i][2] + Day(1) for i in 1:(length(ws) - 1))
        @test last(ws)[2] == Date(2025, 12, 31)
        @test_throws ArgumentError BCB._sgs_windows(Date(2025, 1, 1), Date(2024, 1, 1))
    end

    @testset "SGS: múltiplas séries (junção externa por data)" begin
        mock = MockTransport("bcdata.sgs.10" => SGS_BODY_FULL,
                             "bcdata.sgs.11" => SGS_BODY)
        t = with_transport(mock) do
            sgs(:a => 10, :b => 11)
        end
        @test t isa BCBTable
        @test Tables.columnnames(t) == [:date, :a, :b]
        @test size(t) == (3, 3)
        @test t.date == [Date(2024, 1, 1), Date(2024, 2, 1), Date(2024, 3, 1)]
        @test t.a[1] == 1.0
        @test ismissing(t.a[3])          # série 10 não tem março
        @test t.b[1] == 1.5
        @test ismissing(t.b[2])
    end

    @testset "PTAX: currency" begin
        mock = MockTransport("CotacaoMoedaPeriodo" => PTAX_BODY)
        t = with_transport(mock) do
            currency("USD", Date(2024, 1, 1), Date(2024, 1, 31); bulletin = :closing)
        end
        @test size(t, 1) == 1
        @test t.cotacaoVenda == [4.86]
        @test t.dataHoraCotacao == [DateTime(2024, 1, 2, 13, 9, 2, 871)]   # parse automático
        u = mock.calls[1]
        @test occursin("tipoBoletim%20eq%20%27Fechamento%27", u)
        @test occursin("%24orderby=dataHoraCotacao", u)
        @test_throws ArgumentError with_transport(mock) do
            currency("USD", Date(2024, 1, 1), Date(2024, 1, 31); bulletin = :midnight)
        end
    end

    @testset "expectations: validação e recursos" begin
        @test_throws ArgumentError expectations(:nope)
        @test occursin("ExpectativasMercadoSelic", BCB.url(expectations(:selic)))
        @test occursin("ExpectativasMercadoAnuais", BCB.url(expectations(:annual)))
        q = expectations(:monthly, :Indicador => "IPCA")
        @test BCB.getparam(q, "\$filter") == "Indicador eq 'IPCA'"
    end

    @testset "transporte: escopo e erros" begin
        old = BCB.current_transport()
        mock = MockTransport()
        with_transport(() -> nothing, mock)
        @test BCB.current_transport() === old       # restaurado

        @test_throws ErrorException with_transport(() -> sgs(999), mock)
        @test BCB.current_transport() === old       # restaurado mesmo com erro

        e = BCBError("teste")
        @test sprint(showerror, e) == "BCBError: teste"
        e2 = BCBError("externo", BCBError("interno"))
        @test occursin("causado por", sprint(showerror, e2))
    end

    @testset "respostas malformadas" begin
        mock = MockTransport("bcdata.sgs.7" => "<html>erro</html>")
        @test_throws BCBError with_transport(() -> sgs(7), mock)

        mock2 = MockTransport("bcdata.sgs.8" => """{"error":"nope"}""")
        @test_throws BCBError with_transport(() -> sgs(8), mock2)

        mock3 = MockTransport("Moedas" => """[1,2,3]""")
        @test_throws BCBError with_transport(currencies, mock3)
    end

    @testset "sparkline" begin
        @test BCB._sparkline(Float64[]) == ""
        @test BCB._sparkline([1.0, 1.0, 1.0]) == "▄▄▄"
        sp = BCB._sparkline([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0])
        @test length(collect(sp)) == 8
        @test first(sp) == '▁' && last(sp) == '█'
        @test BCB._sparkline(Union{Missing, Float64}[missing, missing]) == "  "
    end
end
