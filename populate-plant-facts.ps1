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
$UserAgent  = "jaci-briefing/1.0 (personal automation; contact via github.com/thluiz)"

function Get-WikipediaArticle([string]$Title) {
  foreach ($lang in @("pt", "en")) {
    $url = "https://{0}.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&exsectionformat=plain&redirects=1&format=json&titles={1}" -f $lang, [uri]::EscapeDataString($Title)
    try {
      $r = Invoke-RestMethod -Uri $url -TimeoutSec 25 -Headers @{ "User-Agent" = $UserAgent }
    } catch {
      continue
    }
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

function Get-FactFromArticle($Article) {
  # The article goes in whole (capped) and the model is asked to quote back the
  # sentence it used, which is what makes the grounding checkable afterwards.
  $body = @{
    model = "openrouter/deepseek/deepseek-v3.2"
    messages = @(
      @{
        role = "system"
        content = "Voce extrai curiosidades de textos enciclopedicos. Responde SEMPRE em JSON valido, sem markdown, no formato {`"fato`": `"...`", `"trecho`": `"...`"}. O campo fato e uma curiosidade em portugues do Brasil, de uma ou duas frases, escrita para quem nao entende de botanica, sobre o detalhe mais surpreendente do texto. O campo trecho e a frase EXATA do texto original que sustenta o fato, copiada sem alteracao. Nunca use informacao que nao esteja no texto. Se o texto nao tiver nada surpreendente, responda {`"fato`": `"`", `"trecho`": `"`"}."
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
  if (-not $parsed.fato -or -not $parsed.trecho) { return $null }

  # Mechanical grounding check. The quoted sentence has to actually be in the
  # article — a promise in the prompt is not evidence, this is.
  $needle = ($parsed.trecho -replace '\s+', ' ').Trim()
  $hay    = ($Article.text -replace '\s+', ' ')
  if ($needle.Length -lt 25 -or -not $hay.Contains($needle)) {
    Write-Host "  rejected: the quoted sentence is not in the article" -ForegroundColor Yellow
    return $null
  }

  return @{
    fact   = $parsed.fato.Trim()
    source = "Wikipedia ($($Article.lang)) — $($Article.title)"
    url    = $Article.url
    quote  = $needle
  }
}

# ── what is already covered ─────────────────────────────────────────────────
$existing = @()
if (Test-Path $FactsPath) { $existing += @((Get-Content $FactsPath -Raw -Encoding utf8 | ConvertFrom-Json).facts) }
if (Test-Path $SentPath)  { $existing += @((Get-Content $SentPath  -Raw -Encoding utf8 | ConvertFrom-Json).sent) }
$covered = @($existing | ForEach-Object { $_.source } | Where-Object { $_ })

$pool = if ($Topic) { $Topic } else {
  @((Get-Content $TopicsPath -Raw -Encoding utf8 | ConvertFrom-Json).topics) |
    Where-Object { $t = $_; -not ($covered | Where-Object { $_ -like "*$t*" }) } |
    Sort-Object { Get-Random }
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

  Write-Host "  fato : $($fact.fact)" -ForegroundColor Green
  Write-Host "  base : $($fact.quote.Substring(0, [Math]::Min(120, $fact.quote.Length)))..."
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
# The quote stays out of the file: it did its job at validation time, and the
# briefing has no use for it.
$current += @($added | ForEach-Object { [ordered]@{ fact = $_.fact; source = $_.source; url = $_.url } })
@{ facts = $current } | ConvertTo-Json -Depth 5 | Set-Content -Path $FactsPath -Encoding utf8

Write-Host "`nAdded $($added.Count). Queue now holds $($current.Count) facts." -ForegroundColor Green
