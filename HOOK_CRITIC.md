# Hook Critic ↔ Inspo library

Read-only guide for **Hook Critic** (and any other agent) to use the hook data Viral Scout collects for Dominik (KOLBER).
Nothing here changes how Hook Critic works; it's just where the data is and how to get it.

## Where the data is

Supabase project **inspo-scout** (`nzefxnfkzybyhillndhz`). Two read-only views were built for you:

| View | One row per | Use it for |
|---|---|---|
| `hook_library` | TikTok format video Viral Scout found (Gemini-described, first 60 s) | exact on-screen hook text + spoken line + visual in the first ~3 s, a second-by-second `timeline_first_3s`, Gemini scores, and **Dominik's own verdict** on it |
| `hook_scout_library` | text-overlay hook from the hook scout (`hooks` table) | hook text (original + English), pattern/template, Dominik's swipe, the edits made from it and how he reviewed them |

Both views are `security_invoker`, so they follow the tables' RLS: readable with the public (publishable) key, never writable.

A JSON snapshot of both views is also written to the shared research folder you already know:
`/cursor/stores/store-c505614c-b66e-4350-96cf-f2e83b6ec7ee/trial-reels/research/viral-library.json`
(`{generated_at, counts, videos: [...hook_library rows], hooks: [...hook_scout_library rows]}`), refreshed by Viral Scout with
`pipeline/export_hook_library.py` after each run. Supabase is the source of truth if they differ.

> Note: the current videos are mostly **English-language TikTok music-promo formats**, not Polish feel-good reels. Use them for
> hook *mechanics* (pattern, length, placement, what Dominik reacts to), not as Polish wording examples.

### `hook_library` fields

`id, url, platform, creator, creator_followers, stats {views, likes, comments, shares, saves}, posted_at, duration_s, caption, hashtags,
scout_hook` (Viral Scout's one-line hook summary), `format, one_liner, language,
hook_on_screen_text, hook_on_screen_text_en, hook_spoken, hook_spoken_en, hook_visual, hook_sound, hook_tension,
timeline_first_3s` (jsonb array of `{t_start, t_end, on_screen, on_screen_text, spoken_original, spoken_en, sound, camera_cuts}`),
`mechanic, structure {setup, escalation, payoff, *_s}, payoff_and_loop, music_slot, red_flags, scores` (Gemini 1–5:
`hook, entertainment, music_fit, ease_to_copy, series_potential`, each `{score, reason}`), `score_hook, score_hook_reason,
decision` (`superlike` = "I'd make this" > `like` > `dislike`, null = not swiped yet), `reasons` (chips; on a dislike they mean
"this part was the problem"), `note` (Dominik's own words — treat as ground truth), `swiped_at, critic_notes, described_at, added_at`.

Gemini's scores often disagree with Dominik; when they do, **his decision and note win**.

### `hook_scout_library` fields

`id, url, platform, creator, creator_followers, stats, posted_at, duration_s, hook_text` (exact on-screen wording),
`hook_language, hook_text_en, hook_pattern, hook_template, caption, hashtags, frame_url, frame_description,
status` (`found → liked/disliked → submitted → editing → edited → approved/rejected → posted`), `status_changed_at,
decision, reasons` (`Hook text, Funny, Relatable, Fits my music, Easy to adapt, Seen it before`), `note, swiped_at,
edits` (jsonb array: `adapted_hook_text, language, status pending_review|approved|rejected, review_note, target_platforms, posted`),
`critic_notes, added_at`.

## How to query

**REST (public key, read-only)** — the key is in `index.html` (`SB_KEY`, public by design):

```bash
KEY=sb_publishable_IQrtX4qrePB1NDnAU73xyQ_KHzvCwM6
BASE=https://nzefxnfkzybyhillndhz.supabase.co/rest/v1
# Dominik's super likes with their first-3-second hook
curl -s "$BASE/hook_library?select=url,hook_on_screen_text,hook_spoken,hook_visual,timeline_first_3s,score_hook,decision,reasons,note&decision=eq.superlike" -H "apikey: $KEY"
# Everything he disliked because of the hook
curl -s "$BASE/hook_library?select=url,hook_on_screen_text,note&decision=eq.dislike&reasons=cs.%7BHook%7D" -H "apikey: $KEY"
# Liked text hooks and how their edits were reviewed
curl -s "$BASE/hook_scout_library?select=hook_text,hook_text_en,hook_pattern,decision,note,edits&decision=in.(like,superlike)" -H "apikey: $KEY"
```

**Python on the box:** `cd /workspace/inspo/pipeline && ../venv/bin/python -c "import sb; print(sb.select('hook_library','select=*&decision=eq.superlike'))"`

**Supabase connector** (`execute_sql` on project `nzefxnfkzybyhillndhz`), e.g.:

```sql
select hook_on_screen_text, hook_spoken_en, score_hook, decision, reasons, note
  from hook_library where decision is not null order by decision, score_hook desc;
```

## Writing critic notes (optional)

If you want your verdicts to show up in Dominik's app (on hook cards and on edits waiting for review), add a row to
`critic_notes`. Anyone can read them; writes go only through the secret-gated pipeline function (secret on the shared box in
`/workspace/inspo/.supabase.env`, never print or commit it):

```python
import sys; sys.path.insert(0, '/workspace/inspo/pipeline'); import sb
sb.upsert('critic_notes', {
  'target_type': 'edit',            # 'video' (videos.id) | 'hook' (hooks.id) | 'edit' (edits.id)
  'target_id': '<id>',
  'verdict': 'REDO',                # APPROVE | REDO | NOTE
  'scores': {'stopping_power': 6, 'clarity': 8, 'curiosity': 5, 'fit': 7, 'natural_polish': 9, 'avg': 7.0},
  'note': 'Reads as a caption, not a hook: no tension in the first 3 words.',
  'rewrite': 'Mój brat mówi, że ta piosenka nie ma szans…',
})
```

Notes are append-only; the app shows the newest two per item. `hook_library.critic_notes` / `hook_scout_library.critic_notes`
include them too.
