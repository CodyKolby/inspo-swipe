# Inspo Swipe

Tinder-style feed of viral video ideas found by Grok. Swipe right = like, left = dislike, ★ = super like, then optionally tap why. Swipes are saved to `data/swipes.json`, Grok reads them and improves its next batch.

## Setup (5 min)

1. Create a **public** repo (e.g. `inspo-swipe`) and upload everything in this folder. GitHub Pages is free only for public repos, so the video list and swipes are publicly readable.
2. Repo → Settings → Pages → Source: *Deploy from a branch* → `main` / root.
3. Create a fine-grained token for **you**: GitHub → Settings → Developer settings → Fine-grained tokens → only this repo → *Contents: Read and write*.
4. Open `https://OWNER.github.io/inspo-swipe/` on your phone → ⚙︎ → paste token → Test connection → Save. Then Share → *Add to Home Screen*.
5. Create a **second** token the same way for Grok, replace `OWNER/REPO` in `GROK.md`, and give Grok the file + token.

## Files

- `index.html`: the whole app, no build step.
- `data/videos.json`: written by Grok (append only).
- `data/swipes.json`: written by the app.
- `GROK.md`: the data contract for Grok.

## Controls

Buttons, swipe on the card text, or keyboard on desktop: ← dislike, → like, ↑ super like, Z undo. ★ in the header shows your saved ideas. Swipes made offline or without a token stay on the device and save on the next sync.
