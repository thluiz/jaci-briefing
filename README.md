# jaci-briefing

The 07:00 message Jaci sends every morning: today's calendar, the pending
Todoist tasks, places added or updated in the Scholion collection since
yesterday, and a plant curiosity. Windows Task Scheduler drives it,
`\Claude\JaciDailyBriefing`.

```
pwsh -NoProfile -File E:\jaci-briefing\daily-briefing.ps1            # send
pwsh -NoProfile -File E:\jaci-briefing\daily-briefing.ps1 -DryRun    # compose and print
pwsh -NoProfile -File E:\jaci-briefing\populate-plant-facts.ps1 -Count 10 -Preview
```

## Who writes what

**Jaci writes the briefing**, through her own MCP tools — `calendar-gate` for
the agenda, `todoist` for the tasks, and `places-oficina` (the `scholion-places`
MCP) for what changed in the places collection. The script only hands her the
day's window and collects the reply, so the message arrives in her voice and
reads the same APIs an agent would read on demand.

The places check asks `places_search` for `updated_since` yesterday — that
filters on when the *record* was created or changed, not on when a visit
happened, so an edited place shows up even without a fresh sighting. Jaci
answers in up to two parts, separated by a `###LOCAIS###` line the script
splits on: the briefing, and — only if something actually changed — one
short "📍" message **per place**, each naming that place, whether it is new
or updated, and its Scholion page (`https://scholion.thluiz.com/places/<slug>/`,
built from the slug the tool returned — no lookup needed, the site uses
Hugo's default permalink for that section). Nothing changed since yesterday
means no places messages at all, the same way an empty fact queue means no
curiosity: silence over a daily "nothing to report".

Places are one message each, not a combined list, so each can carry its own
cover photo: for every place found, Jaci calls `place_get` to check for a
photo, and if one exists its URL (`https://scholion.thluiz.com/places/<slug>/<file>`,
the page-bundle photo sitting next to that place's `index.md`) goes first in
that place's message, ahead of its own page link, so Telegram unfurls the
photo as the preview — same trick as the plant curiosity's image. A single
combined message would only ever unfurl the first link in it; splitting one
message per place is what lets every place with a photo actually show one.
A place with no photo yet just gets no cover; nothing is invented to fill the
gap. The script splits Jaci's reply on a `###LOCAL###` line between blocks —
one send to GossipGate per place.

**The script writes nothing about plants.** The curiosity is relayed verbatim
from `plant-facts.json` and never passes through the model on the way out.
That is the point: a model asked for a botanical fact produces a plausible one,
and a briefing that invents is worse than a briefing without a curiosity.

The parts go out as **separate messages** — the curiosity cannot push the
briefing past Telegram's 4096-character limit, a long agenda is split into
numbered parts, and each changed place is its own message so none of them
compete with each other, or with the briefing, for room (or for the one
link-preview Telegram is willing to unfurl). Order is always briefing →
one message per changed place (if any) → curiosity (if any).

Delivery is through **GossipGate**, the house standard for notifications.

## The fact queue

`plant-facts.json` is a queue, not a rotation. A fact is consumed **after** it
has actually been sent, and moves to `plant-facts-sent.json` with the date, so
nothing ever repeats and a failed send does not burn a fact.

It is runtime state, so it is not versioned: a fresh clone seeds it from
`plant-facts.example.json` on the first run. Versioning a file the service
rewrites every morning would leave the tree dirty daily and conflict on any
second machine.

`populate-plant-facts.ps1` refills it:

1. Picks a species from `plant-topics.json` that is not covered yet. The subject
   list is curated because a free draw from a plant category lands almost every
   time on a two-line stub about some sedge.
2. Fetches the **full** article text from Wikipedia (`action=query&prop=extracts`,
   not the REST `summary` endpoint, which returns only the lead paragraph).
3. Asks the local LLM gateway for one surprising fact **and the exact sentence
   from the article that supports it**.
4. **Rejects the fact if that sentence is not in the article.** The check is
   mechanical: an instruction in the prompt is not evidence.
5. Pulls the article's own lead image (`pageimages`/`thumbnail`), already
   curated by Wikipedia editors, and stores its URL alongside the fact. The
   briefing puts that URL first in the curiosity message so Telegram unfurls
   it as the preview; no image is sent as an attachment. When an article has
   no lead image, the fact still goes out, without a picture.

Known limit: it verifies the quoted sentence exists, not that the fact follows
from it. Run with `-Preview` and read before writing.

Facts are relayed verbatim, so text in `plant-facts.json` must be correct,
accented PT-BR.

## Failure modes it was built for

- **No tool was called.** The log says so and flags the content as suspect —
  that is how a briefing composed from stale session memory gets caught.
- **A second run on the same day.** The session key carries the time, not just
  the date, so a rerun re-reads the APIs instead of answering from the first
  run's context.
- **GossipGate down.** The send fails loudly and the fact stays in the queue.
- **Empty queue.** The briefing still goes out, without a curiosity, and the log
  says to run the populate script.

## Configuration

| What | Where |
|---|---|
| GossipGate key | `%USERPROFILE%\.gossipgate\api-key`, read at runtime, never stored here |
| Destination | GossipGate default; `-Target <alias>` to override |
| Composing agent | `-Agent`, default `oficina` |
| Timezone | Europe/Lisbon, computed in the script rather than left to the model |

Logs in `logs/YYYY-MM-DD.log`.
