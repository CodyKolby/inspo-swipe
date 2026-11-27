# Grok ↔ Inspo Swipe contract (Supabase)

Dominik swipes on the videos you find. Your job: add finds to the Supabase `videos` table, read his swipes from `swipes` / `swipe_events`, describe videos with Gemini, and get closer to his taste every run.

- App: `https://codykolby.github.io/inspo-swipe/` (repo `CodyKolby/inspo-swipe`, branch `main`). Reads videos and reads/writes swipes straight from Supabase. A switcher at the top has two windows: **Inspo** (format videos, this section) and **Hooks** (hook scout → editing → review, see "Hooks window" below). `#hooks` / `#inspo` in the URL opens one directly.
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
- **Pipeline (box only)**: secret-gated RPCs `public.pipeline_upsert(p_secret, p_table, p_rows jsonb)` (upserts only the keys present; tables `videos, creators, swipes, searches, taste_notes, swipe_events, hooks, hook_swipes, hook_swipe_events, clips, edits, critic_notes`; `pipeline_select` also reads the views `hook_library, hook_scout_library`) and `public.pipeline_select(p_secret, p_table, p_limit)`. The secret is in `/workspace/inspo/.supabase.env` (chmod 600, never commit it). Python helper: `/workspace/inspo/pipeline/sb.py` (`sb.select`, `sb.upsert`, `sb.private_select`).
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

# Hooks window (hook scout → editing agent → Dominik → publishing)

Flow: the **hook scout** finds videos whose on-screen text is the hook → Dominik swipes them in **Hooks › Swipe** → liked ones sit in **Hooks › Ready to edit**, he ticks some and presses *Submit for editing* → the **editing agent** picks the best of Dominik's ~30 recorded `clips`, adapts the hook, renders it and adds an `edits` row → Dominik watches it in **Hooks › Review edits** and approves (with platforms) or rejects with a note → approved TikTok goes to **Edits Chef**, approved Instagram goes to **Trial reels AGNT** as a trial reel. Schema: `sql/002_hook_scout.sql`, `sql/003_pipeline_fns.sql`.

## Tables

| Table | What | Who writes |
|---|---|---|
| `hooks` | One row per hook find. `id` = `platform_nativeId`. `url, platform, creator, creator_nickname, creator_followers, stats jsonb, posted_at, added_at, duration_s, hook_text` (exact on-screen wording, original language), `hook_language` (ISO, e.g. `en`, `pl`), `hook_text_en, hook_pattern` (name, e.g. "Someone said X if I Y"), `hook_template` ("My ___ said ___ if I ___"), `caption, hashtags text[], frame_url` (public image of the frame, optional), `frame_time_s, frame_description, why_picked, explore, status, status_changed_at, submitted_at, raw jsonb` | Hook scout (pipeline); `status` is moved by the app (see below) |
| `hook_swipes` | Current swipe per hook: `hook_id pk, decision (like/superlike/dislike), reasons text[], note, swiped_at, updated_at` | The app |
| `hook_swipe_events` | Append-only: `swipe, edit, undo, submit, unsubmit` | The app |
| `clips` | Dominik's recorded clips: `id` (slug), `title, description` (what he's doing, e.g. "running and singing" — the editor matches on this), `activity, setting, mood, text_space` (where hook text fits: top/middle/bottom), `storage` (`r2`/`drive`), `url, storage_key, duration_s, width, height, notes, active` | Editing agent / Grok |
| `edits` | One rendered video: `id` (text, default uuid), `hook_id, clip_id, adapted_hook_text, adapted_hook_text_en, language` (default `pl`), `caption, hashtags, video_url` (playable public MP4 URL, e.g. R2), `storage_key, thumbnail_url, duration_s, status (pending_review/approved/rejected), review_note, reviewed_at, target_platforms text[]` (default `{tiktok,instagram}`), `routed_to jsonb` (default `{"tiktok":"edits_chef","instagram":"trial_reels_agnt"}`), `posted jsonb` (`{tiktok:{by,url,posted_at}, instagram:{...}}`), `editor_notes, raw` | Editing agent (insert), app (review), publishers (`posted`) |
| `critic_notes` | Hook Critic verdicts: `target_type (video/hook/edit), target_id, author, verdict (APPROVE/REDO/NOTE), scores jsonb, note, rewrite` — shown in the Hooks window | Hook Critic via pipeline |

`hooks.status`: `found → liked | disliked` (automatic: a trigger on `hook_swipes`; undo → `found`) `→ submitted` (app: `rpc/app_submit_hooks`, only from `liked`; `rpc/app_unsubmit_hooks` moves it back) `→ editing` (editing agent, when it starts) `→ edited` (editing agent, when an `edits` row is ready) `→ approved | rejected` (app: `rpc/app_review_edit`) `→ posted` (publisher, after both target platforms are out). Pipeline writes never need to send `status` for a new find (default `found`); never move a hook backwards except `rejected → editing` for a redo.

Reason chips (hooks): `Hook text, Funny, Relatable, Fits my music, Easy to adapt, Seen it before`.

## Access

- anon (app): `SELECT hooks, clips, edits, critic_notes, hook_library, hook_scout_library`; `SELECT/INSERT/UPDATE/DELETE hook_swipes`; `INSERT hook_swipe_events`; `EXECUTE app_submit_hooks, app_unsubmit_hooks, app_review_edit` (only the allowed transitions). No direct writes to `hooks`/`edits`/`clips`.
- Pipeline: `sb.upsert('hooks'|'clips'|'edits'|'critic_notes'|…, rows)`, `sb.private_select('hook_swipe_events')`.

## Hand-offs

- **Hook scout** → upsert `hooks` (exact `hook_text` read off a frame ~1 s in, `hook_text_en`, `hook_pattern`, `hook_template`; never invent text). Read `hook_swipes` (+ events) to learn his hook taste.
- **Editing agent** → poll `hooks?status=eq.submitted`, set `editing`, pick a clip from `clips` by `description`, render, upload the MP4 somewhere playable (R2 public URL), insert `edits` (`status pending_review`), set the hook to `edited`. On `rejected`, read `edits.review_note`; a redo = a new `edits` row (+ hook back to `edited`).
- **Publishers** → `edits?status=eq.approved`: `routed_to.tiktok = edits_chef` → Edits Chef; `routed_to.instagram = trial_reels_agnt` → Trial reels AGNT (trial reel). Each fills `edits.posted.<platform>` and, when all targets are done, sets the hook to `posted`.
- **Hook Critic** → see `HOOK_CRITIC.md` (views `hook_library`, `hook_scout_library`; JSON snapshot via `pipeline/export_hook_library.py` → `trial-reels/research/viral-library.json`; verdicts into `critic_notes`).
- No video files in Supabase (free plan storage is 1 GB). Clips and renders live in R2 (or Drive); only URLs go in the tables.

## Thumbnails (saved lists)
Saved lists (Super / Liked / Disliked) and the Hooks lists show a cover on the left with a ▶ overlay that opens the TikTok in a new tab.
Covers are durable files in `thumbs/<video id>.jpg` (240 px JPEG, ~15 KB), served by GitHub Pages — no expiring CDN links, no ScrapeCreators credits.
They are made by `/workspace/inspo/pipeline/thumbs.py` (headless TikTok player page → cover image → ffmpeg resize); it skips ids that already have a file.
After adding new videos: run `../venv/bin/python thumbs.py` in the pipeline folder, then commit `thumbs/`. Missing file → 🎬 placeholder + ▶ (still links to the video).

## Hook scout pipeline (box: `/workspace/inspo/pipeline/hookscout/`)
Run by Hook Critic. Finds TikToks where the on-screen text hook carries the video (footage = filler) and the hook promotes the creator's own music.
1. `search.py`: ScrapeCreators keyword search (`queries.txt`, 1 credit/call, cached in `pipeline/state/sc_cache`) + latest posts of `creators.txt`. Dedupes against `videos` + `hooks`, metadata prefilter (views ≥ `HOOK_MIN_VIEWS`, default 200k; music words; no lyric/cover edits) → `state/candidates.json`.
2. `describe_hooks.py`: downloads the mp4 from the search result's own media link (free; 1-credit `/v2/tiktok/video` only as a capped fallback), cuts it to the **first 15 s**, Gemini `gemini-3.1-flash-lite` batch (`hook_prompt.md`, capped schema; $0.02/video, $1.50/run caps) → `state/results/<id>.json`.
3. Review by hand into `state/review.json` (`review_list.py` prints a compact list): drop non-promo / US-only / begging / cover / song-is-the-joke / duplicates; score with the Hook Critic rubric + Polish adaptation.
4. `write_hooks.py`: upserts `hooks` (status stays `found`), saves the hook frame (360 px) to `thumbs/<hook id>.jpg` and sets `frame_url` to its GitHub Pages URL, adds a `critic_notes` NOTE row (scores + Polish idea as `rewrite`). Then commit `thumbs/` and run `pipeline/export_hook_library.py`.
