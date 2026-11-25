# Grok ↔ Inspo Swipe contract

Dominik swipes on the videos you find. Your job: add finds to `data/videos.json`, read his swipes from `data/swipes.json`, and get closer to his taste every run.

Repo: `https://github.com/CodyKolby/inspo-swipe` · branch `main`

## 1. Add videos → `data/videos.json`

A JSON array. **Append only**: never delete, reorder or edit existing entries, never reuse an `id`, skip any video whose `id` or `url` is already in the file.

```json
{
  "id": "tiktok_7312345678901234567",
  "url": "https://www.tiktok.com/@creator/video/7312345678901234567",
  "platform": "tiktok",
  "creator": "creator",
  "creator_followers": 12000,
  "stats": { "views": 1840000, "likes": 210000, "comments": 3100, "shares": 18000, "saves": 9000 },
  "posted_at": "2026-11-20T18:00:00Z",
  "added_at": "2026-11-25T21:00:00Z",
  "hook": "What is said or shown in the first 2 seconds",
  "format": "Short label, e.g. Street reaction",
  "tags": ["music", "pov"],
  "promo_idea": "How Dominik could use this format to promote his music",
  "why_picked": "Which of his past swipes this is based on",
  "explore": false,
  "caption": "Full post description text",
  "hashtags": ["karaoke", "carkaraoke"],
  "sound": { "title": "original sound - creator", "author": "Display name", "is_original": true },
  "creator_bio": "The creator's TikTok bio/signature",
  "creator_nickname": "Display name"
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | `platform_nativeId`, unique |
| `url` | yes | Full canonical URL. No short links (`vm.tiktok.com`), or the in-app player can't embed it |
| `platform` | yes | `tiktok`, `instagram`, `youtube` or `x` |
| `added_at` | yes | ISO 8601 UTC, used to show newest finds first |
| `hook`, `format`, `promo_idea` | yes | Shown on the card |
| `why_picked` | recommended | Shown on the card, lets Dominik see your reasoning |
| `explore` | optional | `true` for deliberate experiments outside his proven taste. Aim for ~20% of each batch |
| `caption`, `hashtags`, `sound`, `creator_bio`, `creator_nickname` | recommended | Include on every new video. `hashtags` are names without `#`, from `text_extra` / `cha_list` or parsed from the caption. `sound` is `{title, author, is_original}` (`is_original` = TikTok's original-sound flag). Use `null` when a value is missing; never invent. |
| everything else | optional | |

How to write (GitHub contents API):

1. `GET https://api.github.com/repos/CodyKolby/inspo-swipe/contents/data/videos.json?ref=main` → decode `content` (base64), keep `sha`.
2. Append your new entries.
3. `PUT` the same URL with `{"message": "grok: +N videos", "content": "<base64 JSON>", "sha": "<sha>", "branch": "main"}` and header `Authorization: Bearer <your token>`.
4. On `409`, re-read and retry.

## 2. Read feedback → `data/swipes.json`

Read-only for you. Public URL: `https://raw.githubusercontent.com/CodyKolby/inspo-swipe/main/data/swipes.json` (can be cached ~5 min; the contents API is always fresh).

```json
{
  "video_id": "tiktok_7312345678901234567",
  "url": "https://www.tiktok.com/@creator/video/7312345678901234567",
  "decision": "superlike",
  "reasons": ["Hook", "Fits my music"],
  "note": "love the pacing",
  "swiped_at": "2026-11-25T21:14:03Z"
}
```

- `decision`: `superlike` (strongest signal, "I'd make this") > `like` > `dislike`.
- `reasons`: what drove the decision. Possible values: `Hook`, `Format`, `Topic`, `Editing`, `Sound`, `Humor`, `Fits my music`, `Easy to film`, `Seen it before`. On a dislike they mean "this part was the problem".
- `note`: free text from Dominik; treat it as a direct instruction.
- A swipe can disappear (he undid it) or change (he edited reasons later). Always re-read the whole file.

## Each run

1. Read `swipes.json`, join with `videos.json` by `id`, update your taste notes.
2. Search ScrapeCreators with that taste. ~80% close to what he likes, ~20% `explore: true`.
3. Append 10–20 new videos.
