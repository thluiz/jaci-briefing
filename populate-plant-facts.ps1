<#
.SYNOPSIS
  Refills plant-facts.json with curiosities extracted from real Wikipedia
  articles.

.DESCRIPTION
  Run on demand, not at 07:00. Separating it from the daily send is the whole
  point: writing a fact is where invention can creep in, so it happens here,
  once, where the result can be read before it ever goes to a group — and the
  briefing itself only relays what is already in the file.

  For each topic it fetches the full plain-text article from Wikipedia, hands
  that text to the local LLM gateway (vox-intelligence) and asks for one
  surprising fact GROUNDED IN THAT TEXT. Anything the model returns that cannot
  be traced back to the article is dropped: the check is mechanical, not a
  promise in the prompt.

  Topics already present in plant-facts.json or in plant-facts-sent.json are
  skipped, so nothing repeats across refills.

.PARAMETER Count
  How many new facts to add. Default 10.

.PARAMETER Topic
  Specific article title(s) instead of drawing from plant-topics.json.

.PARAMETER Preview
  Show what would be added, write nothing.
#>
[CmdletBinding()]
param(
  [int]$Count = 10,
  [string[]]$Topic,
  [switch]$Preview
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root       = $PSScriptRoot
$TopicsPath = Join-Path $Root "plant-topics.json"
$FactsPath  = Join-Path $Root "plant-facts.json"
$SentPath   = Join-Path $Root "plant-facts-sent.json"
$ChatUrl    = "http://localhost:8080/api/vox-intelligence/v1/chat/completions"
# Two models on purpose. The writer picks passages and drafts the framing; the
# checker judges translations and framing lines. On a test set of six framing
# lines the writer cleared half of the inventions ("escondida na mala", a
# pollinator called a fungus); the checker caught all of them.
$WriterModel  = "openrouter/deepseek/deepseek-v3.2"
$CheckerModel = "openrouter/anthropic/claude-sonnet-4.5"
$UserAgent  = "jaci-briefing/1.0 (personal automation; contact via github.com/thluiz)"

# Fetching an article and then its image for each of ~10 topics in a row is
# enough traffic to trip Wikipedia's rate limit (HTTP 429) mid-run. A single
# retry loop backs off and retries instead of the call silently coming back
# empty and the topic being skipped for no real reason.
function Invoke-WikipediaApi([string]$Url) {
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    try {
      return Invoke-RestMethod -Uri $Url -TimeoutSec 25 -Headers @{ "User-Agent" = $UserAgent }
    } catch {
      $status = $_.Exception.Response.StatusCode.value__
      if ($status -eq 429 -and $attempt -lt 4) {
        $wait = 5 * [Math]::Pow(2, $attempt - 1) # 5s, 10s, 20s
        Write-Host "  rate limited by Wikipedia, waiting $($wait)s..." -ForegroundColor Yellow
        Start-Sleep -Seconds $wait
        continue
      }
      return $null
    }
  }
  return $null
}

function Get-WikipediaArticle([string]$Title) {
  # Portuguese first, where the passage goes out verbatim. English is the
  # fallback for the many houseplants with no real pt article, and its passage
  # goes through Get-CheckedTranslation before it is accepted.
  foreach ($lang in @("pt", "en")) {
    $url = "https://{0}.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&exsectionformat=plain&redirects=1&format=json&titles={1}" -f $lang, [uri]::EscapeDataString($Title)
    $r = Invoke-WikipediaApi -Url $url
    if (-not $r) { continue }
    $page = $r.query.pages.PSObject.Properties.Value | Select-Object -First 1
    if (-not $page -or $page.missing -ne $null) { continue }
    if (-not $page.extract -or $page.extract.Length -lt 600) { continue }
    return @{
      title   = $page.title
      text    = $page.extract
      lang    = $lang
      url     = "https://{0}.wikipedia.org/wiki/{1}" -f $lang, [uri]::EscapeDataString(($page.title -replace " ", "_"))
    }
  }
  return $null
}

function Get-WikipediaImage([string]$Title, [string]$Lang) {
  # The page's own lead image — already curated by Wikipedia editors as the
  # one photo that represents the article, which is a better bet than trying
  # to pick a "good" one out of the raw image gallery ourselves.
  $url = "https://{0}.wikipedia.org/w/api.php?action=query&prop=pageimages&piprop=thumbnail&pithumbsize=1024&redirects=1&format=json&titles={1}" -f $Lang, [uri]::EscapeDataString($Title)
  $r = Invoke-WikipediaApi -Url $url
  if (-not $r) { return $null }
  $page = $r.query.pages.PSObject.Properties.Value | Select-Object -First 1
  if (-not $page -or -not $page.thumbnail) { return $null }
  return $page.thumbnail.source
}

# Portuguese Wikipedia mixes both orthographies. The passage is relayed as is,
# so one written in PT-EU spelling is dropped rather than "fixed". The last
# alternative catches é/ó before n/m (milénio, fenómeno, económico), which
# Brazil writes with ê/ô.
$PtEuPattern = '(?i)\b(facto|factos|contacto\w*|extract\w*|actua\w*|ac[çc][ãa]o|ac[çc][õo]es|adopt\w*|reflect\w*|direct\w*|[óo]ptim\w*|g[ée]nero|colec[çc]\w*|el[ée]ctric\w*|objectiv\w*|exact\w*|baptiz\w*|recep[çc]\w*|correct\w*|selec[çc]\w*|sector\w*|projecto\w*|ac[çc]ion\w*|\w*[éó][nm][aeiou]\w*)\b'

# Returns $null when the line is clear, or the reason it is not.
function Get-FramingObjection([string]$Line, [string]$Passage) {
  $v = Invoke-GatewayJson -Model $CheckerModel -MaxTokens 200 -System "Voce confere se uma frase de apresentacao ou de comentario inventa algo. Responde SOMENTE em JSON valido, sem markdown: {`"ok`": true} ou {`"ok`": false, `"motivo`": `"...`"}. A pergunta e uma so: a frase atribui a planta algum FATO que o trecho nao diz? Fato e caracteristica, aparencia, uso, perigo, efeito, origem, numero, lugar ou historia. Reacoes, opinioes, metaforas e exageros comicos sobre o que o trecho diz sao ok, porque ninguem os le como fato. Exemplos ok: 'Que historia!'; 'Uma planta que pegou carona numa fuga e virou xodo da Escandinavia' (se o trecho conta a fuga e a ida para a Escandinavia); 'Quem diria que mosquitos tambem sao jardineiros?' (se o trecho diz que mosquitos a polinizam); 'Nunca mais vou olhar para ela do mesmo jeito'. Exemplos false: 'parece de plastico', 'limpa o ar', 'pode ser perigosa', 'resistente como ferro', 'planta que todo mundo tem em casa' - quando o trecho nao diz isso. Tambem false se a frase nao faz sentido." -User "Trecho: $Passage`n`nFrase: $Line"
  # No verdict means no clearance.
  if (-not $v) { return "sem resposta do verificador" }
  if ($v.ok -eq $true) { return $null }
  if ($v.motivo) { return $v.motivo } else { return "reprovada" }
}

function Invoke-GatewayJson([string]$System, [string]$User, [int]$MaxTokens = 600, [string]$Model = $WriterModel) {
  $body = @{
    model = $Model
    messages = @(@{ role = "system"; content = $System }, @{ role = "user"; content = $User })
    maxOutputTokens = $MaxTokens
  }
  $payload = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 6 -Compress))
  try {
    $r = Invoke-RestMethod -Uri $ChatUrl -Method Post -Body $payload -ContentType "application/json; charset=utf-8" -TimeoutSec 180
    $content = ($r.choices[0].message.content -replace '(?s)^.*?\{', '{') -replace '(?s)\}[^}]*$', '}'
    return $content | ConvertFrom-Json
  } catch { return $null }
}

# Digits with separators stripped: "1,275" and "1.275", "3.5" and "3,5" compare
# equal, which is exactly the difference between English and Portuguese style.
function Get-Numbers([string]$Text) {
  @([regex]::Matches($Text, '\d+(?:[.,]\d+)*') | ForEach-Object { $_.Value -replace '[.,]', '' } | Sort-Object)
}

# A translation is a rewrite, which is where every wrong fact used to come
# from, so it has to clear three gates or the fact is dropped: the same numbers
# as the original (mechanical), Brazilian spelling (mechanical), and a second
# call that compares the two texts and only passes a faithful rendering.
function Get-CheckedTranslation([string]$English) {
  $t = Invoke-GatewayJson -System "Voce traduz trechos de enciclopedia do ingles para o portugues do Brasil. Responde SOMENTE em JSON valido, sem markdown: {`"traducao`": `"...`"}. Traducao fiel e natural: nao acrescente, nao omita, nao suavize nem reforce nada. Mantenha todos os numeros e unidades como estao, sem converter. Nomes cientificos ficam como estao; nomes populares so quando houver um consagrado no Brasil." -User $English
  if (-not $t -or -not $t.traducao) { Write-Host "  rejected: no translation" -ForegroundColor Yellow; return $null }
  $pt = ($t.traducao -replace '\s+', ' ').Trim()

  if (((Get-Numbers $English) -join '|') -ne ((Get-Numbers $pt) -join '|')) {
    Write-Host "  rejected: translation changed the numbers: $pt" -ForegroundColor Yellow
    return $null
  }
  if ($pt -match $PtEuPattern) {
    Write-Host "  rejected: translation in PT-EU spelling ($($Matches[0]))" -ForegroundColor Yellow
    return $null
  }
  $v = Invoke-GatewayJson -Model $CheckerModel -MaxTokens 200 -System "Voce confere traducoes. Responde SOMENTE em JSON valido, sem markdown: {`"ok`": true} ou {`"ok`": false, `"motivo`": `"...`"}. E ok somente se a traducao diz exatamente o mesmo que o original: nada acrescentado, nada omitido, nenhum sentido trocado, nenhuma afirmacao suavizada ou reforcada. Na duvida, false." -User "Original: $English`n`nTraducao: $pt"
  if (-not $v -or $v.ok -ne $true) {
    Write-Host "  rejected: translation not faithful ($($v.motivo)): $pt" -ForegroundColor Yellow
    return $null
  }
  return $pt
}

function Get-FactFromArticle($Article) {
  # The model only CHOOSES. What goes into the queue is the passage copied
  # from the article, never a rewrite: every wrong fact the old paraphrase
  # step produced (overstated, embellished, misdated) came from the rewrite,
  # and the containment check below could not catch any of them.
  $body = @{
    model = $WriterModel
    messages = @(
      @{
        role = "system"
        content = "Voce escolhe curiosidades em textos enciclopedicos. Responde SEMPRE em JSON valido, sem markdown, no formato {`"gancho`": `"...`", `"trecho`": `"...`", `"comentario`": `"...`"}. O campo trecho e o detalhe mais surpreendente do texto para quem nao entende de botanica: UMA a TRES frases CONSECUTIVAS copiadas do texto EXATAMENTE como estao, sem alterar, cortar ou juntar nada, com no maximo 450 caracteres. O trecho deve fazer sentido sozinho, ao lado do nome da planta. O trecho fica no idioma do texto, mesmo que seja ingles; gancho e comentario sao sempre em portugues do Brasil. Prefira trechos escritos na grafia do Brasil. O campo gancho e UMA frase curta (ate 120 caracteres), leve e bem-humorada, em portugues do Brasil, que abre a mensagem e da vontade de ler o trecho: uma pergunta, uma provocacao, uma brincadeira. O gancho NAO pode afirmar nenhum fato, numero, data, nome ou lugar que nao esteja no trecho; na duvida, faca uma pergunta em vez de uma afirmacao. O campo comentario e UMA frase curta (ate 140 caracteres), em portugues do Brasil, que fecha a mensagem reagindo ao trecho com leveza: espanto, graca, uma ligacao com o dia a dia de quem le. Vale a mesma regra do gancho: nenhum fato, numero, data, nome ou lugar que nao esteja no trecho. Antes de responder, confira palavra por palavra: se o gancho ou o comentario menciona QUALQUER coisa (processo, uso, origem, caracteristica) que o trecho nao diz, reescreva como pergunta ou reacao generica. Gancho e comentario nao repetem o trecho com outras palavras. Sem emojis. Se o texto nao tiver nada surpreendente, responda {`"gancho`": `"`", `"trecho`": `"`", `"comentario`": `"`"}."
      },
      @{
        role = "user"
        content = "Artigo: $($Article.title)`n`n$($Article.text.Substring(0, [Math]::Min(6000, $Article.text.Length)))"
      }
    )
    maxOutputTokens = 600
  }

  $payload = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 6 -Compress))
  try {
    $r = Invoke-RestMethod -Uri $ChatUrl -Method Post -Body $payload -ContentType "application/json; charset=utf-8" -TimeoutSec 180
  } catch {
    Write-Host "  gateway failed: $($_.Exception.Message)" -ForegroundColor Yellow
    return $null
  }

  $content = $r.choices[0].message.content
  if (-not $content) { return $null }
  # Models wrap JSON in fences no matter how firmly you ask them not to.
  $content = ($content -replace '(?s)^.*?\{', '{') -replace '(?s)\}[^}]*$', '}'
  try { $parsed = $content | ConvertFrom-Json } catch { return $null }
  if (-not $parsed.trecho) { return $null }

  # Mechanical check. The passage has to be in the article character for
  # character — a promise in the prompt is not evidence, this is.
  $needle = ($parsed.trecho -replace '\s+', ' ').Trim()
  $hay    = ($Article.text -replace '\s+', ' ')
  if ($needle.Length -lt 25 -or -not $hay.Contains($needle)) {
    Write-Host "  rejected: the passage is not verbatim in the article" -ForegroundColor Yellow
    return $null
  }
  # A passage that opens in quotes is the article quoting someone else (a care
  # guide, a newspaper), not the encyclopedia speaking.
  if ($needle -match '^["“«]') {
    Write-Host "  rejected: the passage is a quotation inside the article" -ForegroundColor Yellow
    return $null
  }
  # Prose ends in a full stop; a synonym list or a taxon line does not.
  if ($needle -notmatch '[.!?]["”»]?$') {
    Write-Host "  rejected: the passage is not a sentence" -ForegroundColor Yellow
    return $null
  }
  if ($Article.lang -eq "pt") {
    if ($needle -match $PtEuPattern) {
      Write-Host "  rejected: PT-EU spelling ($($Matches[0]))" -ForegroundColor Yellow
      return $null
    }
    $passage = $needle
  } else {
    Write-Host "  original: $needle" -ForegroundColor DarkGray
    # English articles repeat every metric measure in imperial units, "15 cm
    # (5.9 in)". The repeat adds nothing, a translator drops it, and the number
    # check then rejects a faithful translation, so it goes before translating.
    $toTranslate = $needle -replace '\s*\((?:about |approx\.? |c\. )?[\d.,\s–−-]+\s*(?:in|ft|yd|mi|lb|oz|°F|sq ft|sq mi|acres?)\)', ''
    $passage = Get-CheckedTranslation $toTranslate
    if (-not $passage) { return $null }
  }

  # The opening and closing lines are the only creative text, and they stay
  # apart from the passage (the briefing prints the passage in quotes) so they
  # never pass for source. What can be checked mechanically is checked: no
  # digits, short, BR spelling. A bad line costs that line, not the fact.
  # The prompt alone was not enough: in the first unattended run, 4 of 10
  # lines claimed things the passage never said. So a second call, which sees
  # only the passage and the line, has to clear it.
  # A rejected line gets one rewrite, told why the first was refused, so the
  # message does not end up dry; if that fails too, the line is left out.
  $roles = @{
    hook    = "a frase de ABERTURA: UMA frase curta (ate 120 caracteres), leve e bem-humorada, que da vontade de ler o trecho: uma pergunta, uma provocacao, uma brincadeira"
    comment = "o COMENTARIO final: UMA frase curta (ate 140 caracteres) que reage ao trecho com leveza: espanto, graca, uma ligacao com o dia a dia de quem le"
  }
  function Get-FramingLine([string]$Line, [string]$Label) {
    for ($try = 1; $try -le 2; $try++) {
      if ($Line) {
        $Line = ($Line -replace '\s+', ' ').Trim()
        $objection = if ($Line.Length -gt 160 -or $Line -match '\d' -or $Line -match $PtEuPattern) {
          "tem algarismos, grafia de Portugal ou passa de 160 caracteres"
        } else { Get-FramingObjection -Line $Line -Passage $passage }
        if (-not $objection) { return $Line }
        Write-Host "  $Label dropped ($objection): $Line" -ForegroundColor Yellow
      } else { $objection = "veio vazia" }
      if ($try -eq 2) { break }
      $retry = Invoke-GatewayJson -MaxTokens 200 -System "Voce escreve $($roles[$Label]), em portugues do Brasil, para uma curiosidade sobre plantas. Responde SOMENTE em JSON valido, sem markdown: {`"frase`": `"...`"}. A frase NAO pode afirmar nem insinuar nenhum fato, numero, data, nome, lugar, uso ou caracteristica que nao esteja no trecho; na duvida, prefira uma pergunta ou uma reacao. Nao repita o trecho com outras palavras. Sem emojis, sem algarismos." -User "Planta: $($Article.title)`n`nTrecho: $passage`n`nFrase rejeitada: $Line`nMotivo da rejeicao: $objection"
      $Line = if ($retry) { $retry.frase } else { "" }
    }
    return ""
  }
  $hook    = Get-FramingLine $parsed.gancho "hook"
  $comment = Get-FramingLine $parsed.comentario "comment"

  return @{
    fact     = $passage
    original = $(if ($Article.lang -ne "pt") { $needle } else { $null })
    hook     = $hook
    comment  = $comment
    plant    = $Article.title
    source   = "Wikipedia ($($Article.lang)) — $($Article.title)$(if ($Article.lang -ne 'pt') { ', trecho traduzido' })"
    url      = $Article.url
  }
}

# ── what is already covered ─────────────────────────────────────────────────
$existing = @()
if (Test-Path $FactsPath) { $existing += @((Get-Content $FactsPath -Raw -Encoding utf8 | ConvertFrom-Json).facts) }
if (Test-Path $SentPath)  { $existing += @((Get-Content $SentPath  -Raw -Encoding utf8 | ConvertFrom-Json).sent) }
$covered = @($existing | ForEach-Object { $_.source } | Where-Object { $_ })

function Get-UncoveredShuffled([string[]]$List) {
  @($List | Where-Object { $t = $_; -not ($covered | Where-Object { $_ -like "*$t*" }) } |
    Sort-Object { Get-Random })
}

$pool = if ($Topic) { $Topic } else {
  $topicsJson   = Get-Content $TopicsPath -Raw -Encoding utf8 | ConvertFrom-Json
  $interiorPool = Get-UncoveredShuffled @($topicsJson.interior)
  $wildPool     = Get-UncoveredShuffled @($topicsJson.topics)

  # A lista "topics" (selvagem/agricola/arvores) e bem maior que "interior",
  # entao um sorteio unico sobre as duas juntas quase nunca cairia numa planta
  # de casa. Intercalar — interior, selvagem, interior, selvagem... — garante
  # que cada remessa tenha as duas, em vez de depender de sorte.
  $interleaved = @()
  $max = [Math]::Max($interiorPool.Count, $wildPool.Count)
  for ($i = 0; $i -lt $max; $i++) {
    if ($i -lt $interiorPool.Count) { $interleaved += $interiorPool[$i] }
    if ($i -lt $wildPool.Count)     { $interleaved += $wildPool[$i] }
  }
  $interleaved
}

if ($pool.Count -eq 0) {
  Write-Host "Every topic in plant-topics.json is already covered. Add new titles there first." -ForegroundColor Yellow
  exit 0
}

# ── work ────────────────────────────────────────────────────────────────────
$added = @()
foreach ($t in $pool) {
  if ($added.Count -ge $Count) { break }
  Write-Host "`n$t"

  $article = Get-WikipediaArticle -Title $t
  if (-not $article) { Write-Host "  no usable article" -ForegroundColor Yellow; continue }
  Write-Host "  article: $($article.title) ($($article.lang), $($article.text.Length) chars)"

  $fact = Get-FactFromArticle -Article $article
  if (-not $fact) { continue }

  Start-Sleep -Milliseconds 500 # stay under Wikipedia's rate limit across the run
  $fact.image = Get-WikipediaImage -Title $article.title -Lang $article.lang
  Write-Host "  gancho: $($fact.hook)" -ForegroundColor Cyan
  Write-Host "  trecho: $($fact.fact)" -ForegroundColor Green
  Write-Host "  coment: $($fact.comment)" -ForegroundColor Cyan
  Write-Host "  img  : $(if ($fact.image) { $fact.image } else { '(none found)' })"
  $added += $fact
}

if ($added.Count -eq 0) {
  Write-Host "`nNothing added." -ForegroundColor Yellow
  exit 0
}

if ($Preview) {
  Write-Host "`nPREVIEW — $($added.Count) fact(s), nothing written." -ForegroundColor Cyan
  exit 0
}

$current = @()
if (Test-Path $FactsPath) { $current = @((Get-Content $FactsPath -Raw -Encoding utf8 | ConvertFrom-Json).facts) }
$current += @($added | ForEach-Object { [ordered]@{ fact = $_.fact; original = $_.original; hook = $_.hook; comment = $_.comment; plant = $_.plant; source = $_.source; url = $_.url; image = $_.image } })
@{ facts = $current } | ConvertTo-Json -Depth 5 | Set-Content -Path $FactsPath -Encoding utf8

Write-Host "`nAdded $($added.Count). Queue now holds $($current.Count) facts." -ForegroundColor Green
