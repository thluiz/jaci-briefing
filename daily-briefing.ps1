<#
.SYNOPSIS
  Daily briefing written by Jaci: today's calendar, pending Todoist tasks and a
  plant curiosity pulled from Wikipedia. Delivered through GossipGate.

.DESCRIPTION
  Jaci composes the message herself, through her own MCP tools (calendar-gate
  and todoist), so it arrives in her voice and reads the same APIs an agent
  would read on demand. Delivery goes through GossipGate, the house standard.

  The plant curiosity is never asked of the model: a model invents plausible
  botany, and a briefing that invents is worse than one without a curiosity.
  The script fetches a real Wikipedia article and hands Jaci the text; she only
  picks the angle. The species list is curated because a free draw from a plant
  category lands almost every time on a two-line stub about some sedge — the
  subject is chosen, the content is not.

.PARAMETER Target
  GossipGate destination alias. Omit for the default channel.

.PARAMETER Agent
  Jaci agent id that composes. Default "oficina".

.PARAMETER DryRun
  Compose and print, send nothing.
#>
[CmdletBinding()]
param(
  [string]$Target,
  [string]$Agent = "oficina",
  [string]$Date,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root       = $PSScriptRoot
$FactsPath  = Join-Path $Root "plant-facts.json"     # the queue
$SentPath   = Join-Path $Root "plant-facts-sent.json" # what already went out
$LogDir     = Join-Path $Root "logs"
$GossipUrl  = "http://localhost:8080/api/gossip-gate/send"
$GossipKey  = (Get-Content (Join-Path $env:USERPROFILE ".gossipgate\api-key") -Raw).Trim()
$MaxChars   = 3500   # Telegram cuts at 4096; leave room for the part prefix.

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))

function Write-Log([string]$Message) {
  $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Message
  Add-Content -Path $LogFile -Value $line -Encoding utf8
  Write-Host $line
}

# ── the day, in Lisbon terms ────────────────────────────────────────────────
# Computed here rather than left to the model: date arithmetic is exactly what
# an LLM gets subtly wrong, and the whole briefing hangs off this window.
$tz  = [System.TimeZoneInfo]::FindSystemTimeZoneById("GMT Standard Time")  # Europe/Lisbon
$now = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::Now, $tz)
if ($Date) {
  # Testing another day: same code path, different window. The offset is read
  # for that date, not copied from today — a briefing tested across a DST change
  # would otherwise be an hour off.
  $parsed = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null)
  $now = [DateTimeOffset]::new($parsed, $tz.GetUtcOffset($parsed))
}
$sign   = if ($now.Offset.Ticks -lt 0) { "-" } else { "+" }
$offset = "{0}{1:00}:{2:00}" -f $sign, [Math]::Abs($now.Offset.Hours), [Math]::Abs($now.Offset.Minutes)
$dayStart = "{0:yyyy-MM-dd}T00:00:00{1}" -f $now, $offset
$dayEnd   = "{0:yyyy-MM-dd}T23:59:59{1}" -f $now, $offset
# Same reasoning as dayStart/dayEnd: the window for "what's new in the Scholion
# places collection" is midnight of the previous day, computed here rather than
# left for the model to work out.
$yesterday = "{0:yyyy-MM-dd}" -f $now.AddDays(-1)

$ptCulture = [System.Globalization.CultureInfo]::GetCultureInfo("pt-BR")
$dayLabel  = $now.ToString("dddd, d 'de' MMMM 'de' yyyy", $ptCulture)

# ── the plant of the day ────────────────────────────────────────────────────
# The file is a queue, not a rotation: the fact is consumed once it has actually
# been sent, so nothing ever repeats. The fact itself is never generated here —
# populate-plant-facts.ps1 writes it from a real article, this only relays it.
# The queue is runtime state, not source: a fresh clone seeds it from the
# example instead of failing at 07:00 on a missing file.
if (-not (Test-Path $FactsPath)) {
  Copy-Item (Join-Path $Root "plant-facts.example.json") $FactsPath
  Write-Log "seeded plant-facts.json from the example"
}
$factPool = @((Get-Content $FactsPath -Raw -Encoding utf8 | ConvertFrom-Json).facts)
$fact = if ($factPool.Count -gt 0) { $factPool | Get-Random } else { $null }

# It travels as its own message, after the briefing. Two reasons: the briefing
# cannot push it past the Telegram limit, and the text never passes through the
# model, so it cannot come out reworded.
if ($fact) {
  # The image goes right after the fact, before the source line, so it is the
  # first link in the message and Telegram unfurls it as the preview instead
  # of the plain source URL.
  $imageBlock = if ($fact.image) { "`n`n$($fact.image)" } else { "" }
  $curiosityMessage = "🌿 Curiosidade do dia`n`n$($fact.fact)$imageBlock`n`nFonte: $($fact.source)$(if ($fact.url) { "`n$($fact.url)" })"
  Write-Log ("plant of the day: {0} | {1} in the queue" -f $fact.source, $factPool.Count)
} else {
  # Empty queue: the briefing still goes out, without a curiosity. Inventing one
  # to fill the gap is the single thing this design exists to prevent.
  Write-Log "WARNING: no plant facts left — run populate-plant-facts.ps1 to refill"
  $curiosityMessage = $null
}

# ── the prompt ──────────────────────────────────────────────────────────────
$prompt = @"
Monte o recado matinal do grupo. Hoje e $dayLabel.

Primeiro consulte, nesta ordem:
1. calendar-gate__search_events com time_min "$dayStart" e time_max "$dayEnd", para os compromissos de hoje.
2. As tarefas pendentes do Todoist para hoje e as que estao atrasadas.
3. places-oficina__places_search com updated_since "$yesterday" e limit 50, para os locais do Scholion
   (flores, restaurantes) que foram criados ou alterados desde ontem. Isso e sobre o REGISTO ter mudado,
   nao sobre quando a visita aconteceu — um local editado hoje aparece mesmo que a visita nele seja antiga.

Depois escreva a resposta em ATE DUAS PARTES, nesta ordem exata:

PARTE 1 — o recado de hoje (agenda + tarefas), na sua voz. Regras:
- Abra cumprimentando AS PESSOAS, calorosa e proxima, de quem conhece o grupo. Nunca cumprimente o dia da semana: "Bom dia, sabado!" nao faz sentido. Nada de "Bom dia, grupo", que soa a circular de empresa. Varie a abertura de um dia para o outro, e deixe o tom acompanhar o dia que voce acabou de ler: dia cheio pede uma coisa, agenda vazia pede outra.
- Depois de cumprimentar, diga que dia e hoje.
- Texto plano, sem NENHUMA formatacao markdown: nada de asterisco para negrito, nada de sublinhado, nada de cabecalho. O Telegram recebe isso como texto cru e os asteriscos aparecem na tela. Para destacar, use emoji ou uma linha em branco.
- Liste os compromissos com horario. Se nao houver nenhum, diga que a agenda esta livre.
- Liste as tarefas pendentes. Se forem muitas, cite as mais importantes e diga quantas ficaram de fora.
- Nao invente compromisso nem tarefa. Se uma ferramenta falhar, diga com todas as letras que nao conseguiu consultar aquilo.
- Nao inclua curiosidade sobre plantas nem os locais do Scholion: cada um vai numa mensagem separada.
- No maximo 2500 caracteres.

PARTE 2 — SOMENTE SE places_search trouxe pelo menos um resultado. Se nao trouxe nenhum, NAO escreva
PARTE 2 nem a linha separadora abaixo — pare depois da parte 1.
Se trouxe: para CADA local encontrado, chame places-oficina__place_get com o slug dele para ver as fotos
registradas. Se o local tiver ao menos uma foto, monte a URL dela como
https://scholion.thluiz.com/places/<slug>/<file>, usando exatamente o slug e o campo "file" da foto que a
ferramenta devolveu — nunca invente nome de arquivo nem escolha uma foto que nao veio na resposta. Se o
local nao tiver foto nenhuma, siga sem imagem de capa para ele — cada local e independente dos outros.

Depois escreva uma linha contendo exatamente ###LOCAIS### e, na parte de texto plano sem markdown, UM
BLOCO POR LOCAL, cada um vira a MENSAGEM daquele local sozinho (sera enviada separada das demais, e e
por isso que cada uma pode ter sua propria foto de capa). Cada bloco segue este formato: se aquele local
tem foto, a URL dela sozinha na primeira linha (assim o Telegram usa essa foto como preview daquela
mensagem); depois uma linha em branco; depois o texto comecando com 📍: o nome do local, se e NOVO
(created dentro da janela desde ontem) ou ATUALIZADO (created mais antigo que updated), o endereco quando
houver, e o link da pagina dele no Scholion — monte o link a partir do slug que a ferramenta devolveu,
como https://scholion.thluiz.com/places/<slug>/ (nao invente slug: use exatamente o que veio no
resultado). Separe um bloco do proximo com uma linha contendo exatamente ###LOCAL###, sem nada antes nem
depois dela nessa linha. Nao invente local nenhum: um bloco para cada local que a ferramenta devolveu, nem
mais nem menos.

Responda apenas com a(s) parte(s), sem comentario antes ou depois.
"@

# ── Jaci composes ───────────────────────────────────────────────────────────
# The prompt goes in as base64 to a file inside the distro: piping text through
# two shells is how quoting bugs get in.
# One session per run, not per day. With a per-day key a second run reuses the
# first one's context and answers from memory instead of calling the tools —
# which is exactly how a briefing full of yesterday's data would go out.
$sessionKey = "briefing-{0:yyyy-MM-dd}-{1:HHmmss}" -f $now, [DateTimeOffset]::Now
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($prompt))

Write-Log "composing (agent=$Agent, session=$sessionKey, window=$dayStart..$dayEnd)"

$b64 | wsl -d Jaci -u jaci -- bash -lc "base64 -di > /tmp/briefing-prompt.txt"
if ($LASTEXITCODE -ne 0) { Write-Log "FAILED to write the prompt into the Jaci distro"; exit 1 }

$raw = wsl -d Jaci -u jaci -- bash -lc "openclaw agent --agent $Agent --session-key $sessionKey --message-file /tmp/briefing-prompt.txt --json 2>/dev/null; rm -f /tmp/briefing-prompt.txt"
if ($LASTEXITCODE -ne 0) { Write-Log "FAILED: openclaw agent returned $LASTEXITCODE"; exit 1 }

$rawText = ($raw -join "`n")
try {
  $result = $rawText | ConvertFrom-Json
} catch {
  Write-Log "FAILED to parse the agent reply as JSON"
  Write-Log $rawText.Substring(0, [Math]::Min(500, $rawText.Length))
  exit 1
}

# The reply lives in result.payloads[].text; meta.finalAssistantVisibleText is
# the same string and serves as the fallback if the payload shape ever changes.
$text = (@($result.result.payloads) | ForEach-Object { $_.text } | Where-Object { $_ }) -join "`n`n"
if ([string]::IsNullOrWhiteSpace($text)) { $text = $result.result.meta.finalAssistantVisibleText }
if ([string]::IsNullOrWhiteSpace($text)) {
  Write-Log "FAILED: the agent returned no visible text"
  Write-Log ("status={0} summary={1}" -f $result.status, $result.summary)
  exit 1
}

# GossipGate sends plain text, so markdown markers reach the screen as literal
# asterisks. The prompt forbids them; this strips whatever slips through, because
# a rule the model has to remember every morning will be broken some morning.
function Strip-Markdown([string]$Body) {
  $Body = $Body -replace '\*\*([^\*]+)\*\*', '$1'   # **bold**
  $Body = $Body -replace '__([^_]+)__', '$1'        # __bold__
  $Body = $Body -replace '(?m)^\s*#{1,6}\s+', ''    # ## headings
  $Body = $Body -replace '(?m)^\s*\*\s+', '• '      # * bullets
  return $Body
}

# The reply carries up to two parts, split on the delimiter the prompt asked
# for. No delimiter means no places update today — that's the expected shape
# on a quiet day, not a parsing failure.
$sections = @($text -split '(?m)^\s*###LOCAIS###\s*$', 2)
$briefingText = Strip-Markdown($sections[0].Trim())
$placesText = if ($sections.Count -gt 1 -and $sections[1].Trim()) { Strip-Markdown($sections[1].Trim()) } else { $null }

# Each place is its own message, not one combined list: that's what lets each
# one carry its own cover photo as a Telegram preview instead of only the first
# link in a shared message getting unfurled.
$placeMessages = if ($placesText) {
  @($placesText -split '(?m)^\s*###LOCAL###\s*$' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} else { @() }

$tools = @($result.result.meta.toolSummary.tools) -join ", "
Write-Log ("composed {0} chars (briefing) + {1} local message(s), tools used: {2}" -f `
  $briefingText.Length, $placeMessages.Count, $(if ($tools) { $tools } else { "none" }))
if (-not $tools) {
  # A briefing that reached no tool has no data in it. Say so in the log rather
  # than sending a cheerful empty message every morning without anyone noticing.
  Write-Log "WARNING: no tool was called; the content is suspect"
}

# ── split, because Telegram cuts at 4096 ────────────────────────────────────
function Split-Message([string]$Body, [int]$Limit) {
  if ($Body.Length -le $Limit) { return @($Body) }
  $chunks = @()
  $current = ""
  foreach ($piece in ($Body -split "(?<=`n)")) {
    $paragraph = $piece
    if (($current.Length + $paragraph.Length) -gt $Limit -and $current.Length -gt 0) {
      $chunks += $current.TrimEnd()
      $current = ""
    }
    # A single paragraph over the limit still has to go out: cut it hard.
    while ($paragraph.Length -gt $Limit) {
      $chunks += $paragraph.Substring(0, $Limit)
      $paragraph = $paragraph.Substring($Limit)
    }
    $current += $paragraph
  }
  if ($current.Trim().Length -gt 0) { $chunks += $current.TrimEnd() }
  return $chunks
}

$parts = @(Split-Message -Body $briefingText -Limit $MaxChars)
if ($parts.Count -gt 1) {
  for ($i = 0; $i -lt $parts.Count; $i++) {
    $parts[$i] = "({0}/{1})`n{2}" -f ($i + 1), $parts.Count, $parts[$i]
  }
}

# The places update, when there is one, rides between the briefing and the
# curiosity — one message per place, so each keeps its own cover photo as the
# first (and only) link Telegram has to unfurl for that message.
foreach ($placeMessage in $placeMessages) { $parts += @(Split-Message -Body $placeMessage -Limit $MaxChars) }

# The curiosity is the last message of the sequence.
if ($curiosityMessage) { $parts += $curiosityMessage }

if ($DryRun) {
  Write-Log ("DRY RUN — {0} message(s), nothing sent" -f $parts.Count)
  $parts | ForEach-Object { Write-Host "`n---------- message ----------`n$_" }
  exit 0
}

# ── deliver through GossipGate ──────────────────────────────────────────────
$sent = 0
foreach ($part in $parts) {
  $payload = @{ message = $part }
  if ($Target) { $payload.target = $Target }
  # UTF-8 bytes, never a pwsh string: the pipeline mangles accents otherwise.
  $body = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 3 -Compress))
  try {
    Invoke-RestMethod -Uri $GossipUrl -Method Post -Body $body `
      -ContentType "application/json; charset=utf-8" `
      -Headers @{ "X-Api-Key" = $GossipKey } | Out-Null
    $sent++
  } catch {
    Write-Log ("FAILED to send message {0} of {1}: {2}" -f ($sent + 1), $parts.Count, $_.Exception.Message)
    # The fact is only consumed below, so a failure here leaves it in the queue
    # for tomorrow instead of burning it on a message nobody received.
    exit 1
  }
  Start-Sleep -Milliseconds 400
}

Write-Log ("sent {0} message(s) via GossipGate{1}" -f $sent, $(if ($Target) { " to '$Target'" } else { " (default)" }))

# ── consume the fact, only now that it really went out ──────────────────────
# Removing it before the send would silently burn a fact whenever GossipGate is
# down. Sent facts are kept in a dated history rather than deleted outright.
if ($fact) {
  $remaining = @($factPool | Where-Object { $_.fact -ne $fact.fact })
  @{ facts = $remaining } | ConvertTo-Json -Depth 5 | Set-Content -Path $FactsPath -Encoding utf8

  $history = @()
  if (Test-Path $SentPath) {
    try { $history = @((Get-Content $SentPath -Raw -Encoding utf8 | ConvertFrom-Json).sent) } catch { $history = @() }
  }
  $history += [ordered]@{
    date   = "{0:yyyy-MM-dd}" -f $now
    fact   = $fact.fact
    source = $fact.source
    url    = $fact.url
    image  = $fact.image
  }
  @{ sent = $history } | ConvertTo-Json -Depth 5 | Set-Content -Path $SentPath -Encoding utf8

  Write-Log ("fact consumed, {0} left in the queue" -f $remaining.Count)
  if ($remaining.Count -le 5) {
    Write-Log "WARNING: fewer than 6 facts left — run populate-plant-facts.ps1"
  }
}
