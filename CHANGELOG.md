# Changelog

## 2026-09-11

- Refilled the fact queue: 10 new curiosities pulled and grounding-checked from Wikipedia (queue went from 8 to 18 entries).
- Added lead images to the fact pipeline: `populate-plant-facts.ps1` now fetches each article's Wikipedia thumbnail (`pageimages`) and stores it as `image`; `daily-briefing.ps1` puts that URL first in the curiosity message so Telegram unfurls it as a preview. No photo attachment — GossipGate only accepts text, so the image rides as a link.
- Backfilled `image` for all 18 facts already sitting in the queue.
- Added retry-with-backoff for Wikipedia's rate limit (HTTP 429) in `populate-plant-facts.ps1`, after a live run fetching 18 images back-to-back got throttled mid-run.

## 2026-09-03

- Daily briefing shipped: Jaci composes the message (calendar + Todoist tasks) through her own MCP tools, GossipGate delivers it, and a plant curiosity is relayed verbatim from a queue rather than generated.
- Briefing greeting changed to address the people rather than name the weekday, and Telegram-unsafe markdown is stripped from the composed text.
- The fact queue (`plant-facts.json`) was reworked to behave as runtime state rather than versioned source: seeded from `plant-facts.example.json` on first run, consumed only after a real send, sent history kept in `plant-facts-sent.json`.
