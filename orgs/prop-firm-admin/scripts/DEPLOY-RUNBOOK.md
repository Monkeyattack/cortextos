# Deploy Runbook — static/web artifacts on this box

Written 2026-08-04 from a day of deploys where every failure was a **plausible clean pass**.
That is the theme: none of these announce themselves. Each one produces a believable
success signal while the thing you wanted did not happen.

---

## 1. Three verification claims. They are not interchangeable.

| Claim | What it proves | Who can prove it |
|---|---|---|
| **RENDER-verified** | Boots, draws, zero console errors, canvas sized | An agent with a headless browser |
| **FEEL-verified** | Sequencing, input-locking during resolution, state visibly advancing | An agent driving real interaction |
| **AUDIBLE-verified** | A human hears sound | **Only a human** |

`AudioContext` instantiated proves the pipeline is *wired*, not that anyone hears anything.
Say so rather than implying audio works.

On 2026-08-04 Score v2 needed all three, from two agents plus Chris. A still frame cannot
show sequencing or input-locking — and "feels like a mouse clicker" was a complaint about
exactly those. **Never report render-verified as though it settles feel.**

**The sharpest form: a correct no-op is indistinguishable from a broken one.** On the
2026-08-05 punch-list gate, tapping an out-of-range camera *correctly did nothing* — and a
tap the app ignored because it was broken looks identical. Only the refusal text
("Tile is out of range") separates them. A render check cannot reach this at all: the
screenshot of a working suppression and a dead input are the same image. When a spec says
"X should not happen", the gate must assert **why** it did not happen, not that the screen
stayed still.

## 2. HTTP 200 is not a deploy. Load the page.

A 200 with correct MIME can sit on top of a silently dead app. Godot/WASM in particular
fails to a **black canvas with no error**. Always drive a real browser and assert on
engine boot + a ready signal, not on status codes.

## 3. Verify the file that CHANGED, not the biggest one.

**Godot: `index.wasm` is the ENGINE. `index.pck` is the GAME.**
Across two different content builds on 2026-08-04 the wasm was byte-identical
(`cfed4460` both). The pck went `58.1KB → 479.8KB`, `5abc06bc → 0bc011ee`.

md5-ing the wasm would have **confirmed a successful deploy of nothing**. The requested
check was wrong. What caught it was not stopping at the pass: a wasm matching a build that
*should* have changed was the tell, and the pck was hashed only because that felt wrong.
The instruction was to hash *something*; the catch was hashing the *right* thing.

> Before hashing anything, ask: *would this file differ if the deploy had failed?*
> If not, it is not a verification.

## 4. `curl … | md5sum` LIES on binaries. Write to disk first.

```bash
curl -s --output /tmp/x.bin "$URL" && md5sum /tmp/x.bin   # correct
curl -s "$URL" | md5sum                                    # FALSE MISMATCH on a 491KB pck
```
Piping binary through the shell corrupted it and produced a confident wrong hash.
Same class as a 415KB JSON response truncating mid-pipe and reading as malformed data.
**Large or binary response → file → then parse/hash.**

## 5. `umask 0077` → nginx 403 on everything you just deployed

This account's umask makes `mkdir`/`cp` produce `700`/`600`. Files read fine **as you**
and are unreadable to `www-data`. The 403 looks like an nginx misconfiguration.

```bash
chmod -R a+rX "$TARGET"   # after every copy, before going live
```

## 6. Stage-and-swap. Never copy over a live directory.

```bash
rm -rf "$BASE/.new" "$BASE/.old"           # <-- MANDATORY. See the mv trap below.
mkdir -p "$BASE/.new" && cp -r "$SRC"/. "$BASE/.new"/
chmod -R a+rX "$BASE/.new"                 # fix perms BEFORE it is live
mv "$LIVE" "$BASE/.old" && mv "$BASE/.new" "$LIVE"
```

**THE `mv` TRAP — this silently poisons your rollback on the SECOND deploy.**
`mv live .old` behaves differently depending on whether `.old` already exists:
- `.old` absent → renames. Correct.
- `.old` present → **moves live INSIDE it**, producing `.old/live/`. `.old` still holds the
  version from the deploy BEFORE last, and `mv .old live` would restore *that* — two
  versions back — while looking like a normal rollback.

Verified 2026-08-05: with `.old/marker`=v1 and `live/marker`=v2, after `mv live .old` the file
at `.old/marker` still read **v1**, with v2 buried at `.old/live/marker`. No error, exit 0.
The first deploy of any site works fine and hides this until the second one.
Three reasons, all bit on 2026-08-04:
- **Stale files survive a copy-over.** The live dir held 3 Godot `.import` editor artifacts
  the new export does not produce. `cp -r` leaves them served forever.
- Permissions get fixed while staged, so the site is never live-but-unreadable.
- The broken window is milliseconds instead of seconds on a 37MB tree.

Keep `.old` until the verdict lands. Rollback is one `mv`. Retain it on an ITERATE
verdict for A/B, not just as failure recovery.

## 7. SPA fallback: a real directory beats `try_files`

`try_files $uri $uri/ /index.html;` sends unknown paths to the old app's index — so
`/thing/` served stale content while looking deployed. Creating a **real directory** with
its own `index.html` makes `$uri/` match first. The old app at `/` is untouched.

Docroots do not always match the conf filename: `play.profithits.app` is served by
`sites-available/coretext.profithits.app` from `repos/mission-engine/build/web`.

## 8. COOP/COEP is per-EXPORT, not per-engine

Same engine, opposite requirements on the same day:
- **threaded** export → needs `Cross-Origin-Opener-Policy: same-origin` +
  `Cross-Origin-Embedder-Policy: require-corp`, or it dies silently. Also needs
  `Cross-Origin-Resource-Policy` on the assets or the isolated document blocks its own files.
- **single-threaded** export → needs none. Boots with `crossOriginIsolated: false`.

`index.js` greps positive for `SharedArrayBuffer` in **both** cases — the loader checks and
degrades. **Do not decide this from a grep or from the export preset. Load the page.**

## 9. If you cannot edit nginx, you may not need to

`/etc/nginx` needs root; `sudo` needs a password. But the preview-server runs as
`claude-dev`, so headers can be set in code instead — version-controlled, and no root.
Before escalating "needs Chris", check whether the thing you need is reachable from
something you already own.

## 10. Cite the repo path. `/preview/` links rot to 403.

files.profithits.app has three sharing shapes: `/preview/<token>/…` **token-rots to 403 over
time**, while `/media/…` and `/file/…` are durable. So a preview link is fine for "look at
this now" and useless as a citation in anything meant to last.

A file drop does not earn you a durable link. Each route has a precondition:
- **`/media/…`** serves only from `/mnt/r2/files/media/`. A copy to any sibling
  (`/mnt/r2/files/devops/`) is not routed → 403.
- **`/file/<id>`** needs a `.meta.json` minted by the upload API. Files copied straight
  onto the filesystem bypass it → 404. Mint the meta inline or upload properly.

```bash
cp "$F" /mnt/r2/files/media/ && chmod a+r /mnt/r2/files/media/"$(basename "$F")"
curl -sI "https://files.profithits.app/media/$(basename "$F")" | head -1   # expect 200
```

**§5's umask trap applies to the PARENT DIRECTORIES, and it took the whole route down.**
On 2026-08-05 `/mnt/r2/files`, `/mnt/r2/files/media` and all 11 subdirs were `drwx------`,
with 278 files lacking `o+r`. nginx runs as `www-data` and could not traverse, so **every
`/media/` URL the fleet had ever sent was returning 403** — including files that had
verified 200 when they were sent. A `chmod a+r` on your file cannot fix a parent it cannot
enter. Restored with, and re-verify a *pre-existing* file, not just your new one:

```bash
chmod o+x /mnt/r2/files          # traverse only — siblings still do not list
chmod -R o+rX /mnt/r2/files/media
```

The diagnostic that separates "my file is wrong" from "the route is down": **request a file
that used to work.** Mine 403'd and so did a months-old photo — that second request is what
turned a publishing question into an outage.

Practical rule: always curl for 200 before sending any link, and for anything referenced
later **cite the repo path**, with a URL as convenience only. A 200 today is not a 200
tomorrow. This runbook's canonical address is
`orgs/prop-firm-admin/scripts/DEPLOY-RUNBOOK.md`.

---

**The through-line:** every item here is an instrument that answered a slightly different
question than the one being asked, and answered it convincingly. When a check passes,
ask what *else* would produce that same pass.
