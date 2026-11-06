# Mixcloud Direct for Lyrion

Lyrion Music Server (LMS) plugin for Mixcloud with no yt-dlp/OAuth, built to
work on LMS 9.0 (the owner's server, 192.168.1.133:9000, can't be upgraded).
Sibling of ~/Projects/KEXP (same conventions).

## Layout
- `src/MixcloudDirect/`: the plugin (installs as `Plugins/MixcloudDirect/`, package prefix `Plugins::MixcloudDirect::`, prefs `plugin.mixclouddirect`, menu tag `mixclouddirect`)
  - `Plugin.pm`: OPML menus (My Mixcloud by username, search, categories → Popular/Latest, open link, per-user pages, "More…" paging)
  - `ProtocolHandler.pm`: `mcdirect://<user>/<slug>`. `getNextTrack` fetches fresh streamInfo (GraphQL) → HLS master → variant → media playlist. The handler is an `IO::Handle` with no socket: `sysread` serves a buffer filled by async segment fetches (TS → ADTS) and returns `EINTR` while waiting. Seeks: `getSeekData` returns `{timeOffset}`, `new` picks the segment, trims frames (`adtsSkip`), and sets `$song->startOffset`.
  - `API.pm`: REST (api.mixcloud.com) + GraphQL (app.mixcloud.com/graphql) client; `API->request` builds every HTTP::Request
  - `Util.pm`: pure helpers (XOR stream-url decoding, m3u8 parsing, TS demux, ADTS walking): unit tested
  - `Settings.pm` + `HTML/EN/plugins/MixcloudDirect/settings/basic.html`: username, quality, show Select shows
- `tests/`: `prove tests/` (only Util is testable outside LMS; fixtures are real Mixcloud data)
- `scripts/dev-server.sh`: Docker LMS **9.0.0** on :9100 (`LMS_VERSION=` to change); `docker restart mixcloud-lms` reloads code, then rerun `scripts/test-player.sh`
- `scripts/icon.py`: generates the icon (original cloud + equaliser mark): `<name>.svg` 24×24 #000 glyph that Material swaps in for `<name>_svg.png`, plus the 512 px full-bleed colour tile (rendered with macOS `qlmanage`). Keep the tile full-bleed: QuickLook flattens transparency onto white, which showed as white corners on dark themes. Bump `NAME` (and install.xml) on any art change, since LMS caches resized icons by path.
- `scripts/smoke.py`: weekly CI check of the undocumented Mixcloud behaviour below

## Mixcloud facts (verified Nov 2026)
- **HTTP/1.0 → 426 Upgrade Required** on all Mixcloud hosts. LMS defaults to 1.0 unless you pass `request => HTTP::Request` with `protocol('HTTP/1.1')` in SimpleAsyncHTTP params. Always go through `API->request`.
- **CDN (aod.mixcloud.com) 403s any User-Agent starting `iTunes/`**, which is LMS's default. `API->request` sets our own; LMS's `init_header` doesn't override it.
- **`Content-Encoding: identity`** comes from www.mixcloud.com (OAuth). LMS < 9.2 inflates it into an empty body (fixed upstream in slimserver af0afcb). REST sends no encoding; GraphQL sends gzip. Don't use www.mixcloud.com.
- GraphQL `cloudcastLookup(lookup:{username,slug})` works unauthenticated with plain clients (no TLS impersonation needed). `streamInfo.{url,hlsUrl,dashUrl}` = base64(url XOR `IFYOUWANTTHEARTISTSTOGETPAIDDONOTDOWNLOADFROMMIXCLOUD`). `sections` gives tracklists with `startSeconds`. `restrictedReason`: `tracklist` (geo/licensing), `repeat_play`.
- HLS: master has 64k and (newer uploads) 192k variants; media playlists list ~10 s MPEG-TS segments of ADTS AAC (44.1 kHz stereo), unencrypted, no signature. Older uploads: a single 64k variant. `url` is a 64k progressive m4a (moov first): unused.
- REST list endpoints are public: `/<user>/{cloudcasts,favorites,listens,following,playlists}/`, `/discover/<tag>/{popular,latest}/`, `/categories/`, `/search/?type=cloudcast|user|tag`. Paging via `paging.next`. `is_exclusive` = Mixcloud Select (unplayable; hidden unless the pref is on).

## LMS gotchas (from KEXP, still apply)
- Material only refreshes now-playing when the server pushes (`newmetadata`); it never polls, so `getMetadataFor` alone goes stale (LyrionJS polls and looked fine). `_scheduleTrackChange` sets a per-client timer for the next tracklist boundary (capped at 60 s) that re-runs `getMetadataFor`, which notifies on change.
- Playable rows use the full favourite title as `name` (LyrionJS saves favourites under `name`) with `line1`/`line2` for display.
- Don't give `link` items a `play` attribute (Material ⋮ menu loses Play).
- Most CLI menu queries hang without a connected player: start the test player.
- Squeezelite with `-c flac,pcm,mp3` forces the faad transcode path (handler → faad | flac).

## No secrets
The Mixcloud APIs used are public and unauthenticated; `.env` exists only by convention.
