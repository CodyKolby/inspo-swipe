# Grok ↔ Inspo Swipe contract (Supabase)

Dominik swipes on the videos you find. Your job: add finds to the Supabase `videos` table, read his swipes from `swipes` / `swipe_events`, describe videos with Gemini, and get closer to his taste every run.

- App: `https://codykolby.github.io/inspo-swipe/` (repo `CodyKolby/inspo-swipe`, branch `main`). Reads videos and reads/writes swipes straight from Supabase.
- Database: Supabase project **inspo-scout** (`nzefxnfkzybyhillndhz`, eu-central-1, free plan). REST: `https://nzefxnfkzybyhillndhz.supabase.co/rest/v1/`.
- `data/videos.json` and `data/swipes.json` are a **frozen backup** from 2026-11-26. Nothing writes to them any more; don't use them as the source of truth.
- **No video files are stored anywhere in Supabase.** Only the TikTok URL plus metadata and the Gemini description.

## Tables

| Table | What | Who writes |
|---|---|---|
| `videos` | One row per find. `id` = `platform_nativeId` (e.g. `tiktok_7312…`). Columns: `url, platform, creator, creator_nickname, creator_followers, creator_bio, stats jsonb, posted_at, added_at, duration_s, caption, hashtags text[], sound jsonb, hook, format, tags text[], promo_idea, why_picked, explore, transcript, description jsonb, description_model, description_cost_usd, described_at, raw jsonb` | Grok (pipeline) |
| `swipes` | Current state per video: `video_id pk, decision (like/superlike/dislike), reasons text[], note, swiped_at, updated_at`. A row disappears when he undoes a swipe. | The app |
| `swipe_events` | Append-only history of every `swipe`, `edit`, `undo` (plus `migrate` rows from the JSON backup): `video_id, action, decision, reasons, note, client_ts, created_at` | The app |
| `searches` | Every ScrapeCreators search: `query, kind, sort, page, credits, results_count, kept_count, ran_at, raw` | Grok |
| `creators` | `handle pk, nickname, followers, bio, notes, last_checked` | Grok |
| `taste_notes` | Running taste summary: `created_at, body` | Grok |

Field rules for new `videos` rows (same as before): `id`, `url` (canonical, no short links), `platform`, `added_at` required; `hook`, `format`, `promo_idea` shown on the card; `why_picked` recommended; `explore: true` for ~20% experiments; `caption`, `hashtags` (no `#`), `sound {title, author, is_original}`, `creator_bio`, `creator_nickname` on every new video. Use `null` when a value is missing; never invent. Never reuse an `id`.

Swipe semantics: `superlike` ("I'd make this") > `like` > `dislike`. `reasons` ∈ `Hook, Format, Topic, Editing, Sound, Humor, Fits my music, Easy to film, Seen it before` (on a dislike = "this part was the problem"). `note` is a direct instruction from Dominik.

## Access (RLS is on for every table)

- **Publishable key** (in `index.html`, public by design): `anon` can `SELECT videos`, `SELECT/INSERT/UPDATE/DELETE swipes` (delete = undo), `INSERT swipe_events`. Nothing else.
- **Pipeline (box only)**: secret-gated RPCs `public.pipeline_upsert(p_secret, p_table, p_rows jsonb)` (upserts only the keys present; tables `videos, creators, swipes, searches, taste_notes, swipe_events`) and `public.pipeline_select(p_secret, p_table, p_limit)`. The secret is in `/workspace/inspo/.supabase.env` (chmod 600, never commit it). Python helper: `/workspace/inspo/pipeline/sb.py` (`sb.select`, `sb.upsert`, `sb.private_select`).
- Ad-hoc SQL / schema changes: Supabase connector (`execute_sql`, `apply_migration`) on project `nzefxnfkzybyhillndhz`.

## Gemini descriptions

`/workspace/inspo/pipeline/describe.py` — for given video ids: fresh no-watermark URL via ScrapeCreators `/v2/tiktok/video` (1 credit; also stores transcript + duration) → download → trim to the first 60 s → Gemini Files API → `gemini-3.1-flash-lite` with `describe_prompt.md` + JSON schema → saves `videos.description / description_model / description_cost_usd / described_at` → deletes the Gemini upload and the local file.

```
cd /workspace/inspo/pipeline
../venv/bin/python describe.py --mode batch --undescribed          # default for real runs (50% cheaper, async)
../venv/bin/python describe.py --mode direct tiktok_123 tiktok_456  # small tests
../venv/bin/python describe.py --collect                            # pick up finished batch jobs
```

Caps: per-video `max_output_tokens`, any video costing > $0.02 is flagged; `--usd-cap` per run (default $1).

## Each run

1. Read `swipes` (+ `swipe_events` for history), join with `videos` (incl. `description`), update `taste_notes`.
2. Search ScrapeCreators with that taste (~80% close, ~20% `explore`); log each call in `searches`.
3. Upsert 10–20 new `videos` (+ `creators`), then describe them with the batch pipeline.
