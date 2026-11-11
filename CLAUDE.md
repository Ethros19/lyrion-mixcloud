# Mixcloud Direct for Lyrion

Lyrion Music Server (LMS) plugin for Mixcloud with no yt-dlp/OAuth, built to
work on LMS 9.0 (the owner's server, which can't be upgraded) and
published for others in the same spot. Tested on LMS 8.5.2, 9.0.0, 9.1.2, 9.2.0.
Read-only by design: it never logs in or changes the Mixcloud account (README,
plugin description and settings page all say so; keep it that way).
Sibling of ~/Projects/KEXP (same conventions).

## Layout
- `src/MixcloudDirect/`: the plugin (installs as `Plugins/MixcloudDirect/`, package prefix `Plugins::MixcloudDirect::`, prefs `plugin.mixclouddirect`, menu tag `mixclouddirect`)
  - `Plugin.pm`: OPML menus (My Mixcloud by username, Followed, Search folder, categories → Popular/Latest, open link, per-user pages, "More…" paging)
  - `ProtocolHandler.pm`: `mcdirect://<user>/<slug>`. `getNextTrack` fetches fresh streamInfo (GraphQL) → HLS master → variant → media playlist. The handler is an `IO::Handle` with no socket: `sysread` serves a buffer filled by async segment fetches (TS → ADTS) and returns `EINTR` while waiting. Seeks: `getSeekData` returns `{timeOffset}`, `new` picks the segment, trims frames (`adtsSkip`), and sets `$song->startOffset`.
  - `Live.pm`: stream handler for `mcdirect://live/<user>` (ProtocolHandler::new hands live urls to it). `resolve` = GraphQL `userLookup{isLive liveStream{hlsUrl}}` → master → audio-only rendition → playlist → init segment (AAC config). Starts BACKLOG=3 segments behind the edge, re-reads the playlist every target duration, converts each fMP4 segment to ADTS (`fmp4ToAdts`). After 3 playlist failures it re-resolves (the url's token expires, ~1 day); stops when the user is no longer live.
  - `API.pm`: REST (api.mixcloud.com) + GraphQL (app.mixcloud.com/graphql) client; `API->request` builds every HTTP::Request
  - `Util.pm`: pure helpers (XOR stream-url decoding, m3u8 parsing, TS demux, ADTS walking): unit tested
  - `Settings.pm` + `HTML/EN/plugins/MixcloudDirect/settings/basic.html`: username, quality, show Select shows
- `tests/`: `prove tests/` (only Util is testable outside LMS; fixtures are real Mixcloud data)
- `scripts/dev-server.sh`: Docker LMS **9.0.0** on :9100 (`LMS_VERSION=` to change; 8.x is `LMS_IMAGE=lmscommunity/logitechmediaserver LMS_VERSION=8.5.2`); `docker restart mixcloud-lms` reloads code, then rerun `scripts/test-player.sh`
- `scripts/icon.py`: generates the icon (original cloud + equaliser mark): `<name>.svg` 24×24 #000 glyph that Material swaps in for `<name>_svg.png`, plus the 512 px full-bleed colour tile (rendered with macOS `qlmanage`). Keep the tile full-bleed: QuickLook flattens transparency onto white, which showed as white corners on dark themes. Bump `NAME` (and install.xml) on any art change, since LMS caches resized icons by path. It also renders `MTL_icon_<name>.png` menu tiles from Google's Material Icons (Apache-2.0, fetched from jsdelivr).
- `scripts/installs.sh`: install counts (Lyrion community stats + GitHub release downloads)
- `scripts/smoke.py`: weekly CI check of the undocumented Mixcloud behaviour below

## Mixcloud facts (verified Nov 2026)
- **HTTP/1.0 → 426 Upgrade Required** on all Mixcloud hosts. LMS defaults to 1.0 unless you pass `request => HTTP::Request` with `protocol('HTTP/1.1')` in SimpleAsyncHTTP params. Always go through `API->request`.
- **CDN (aod.mixcloud.com) 403s any User-Agent starting `iTunes/`**, which is LMS's default. `API->request` sets our own; LMS's `init_header` doesn't override it.
- **`Content-Encoding: identity`** comes from www.mixcloud.com (OAuth). LMS < 9.2 inflates it into an empty body (fixed upstream in slimserver af0afcb). REST sends no encoding; GraphQL sends gzip. Don't use www.mixcloud.com.
- GraphQL `cloudcastLookup(lookup:{username,slug})` works unauthenticated with plain clients (no TLS impersonation needed). `streamInfo.{url,hlsUrl,dashUrl}` = base64(url XOR `IFYOUWANTTHEARTISTSTOGETPAIDDONOTDOWNLOADFROMMIXCLOUD`). `sections` gives tracklists with `startSeconds`. `restrictedReason`: `tracklist` (geo/licensing), `repeat_play`.
- HLS: master has 64k and (newer uploads) 192k variants; media playlists list ~10 s MPEG-TS segments of ADTS AAC (44.1 kHz stereo), unencrypted, no signature. Older uploads: a single 64k variant. `url` is a 64k progressive m4a (moov first): unused.
- Live: `userLookup(lookup:{username}) { isLive liveStream { name description hlsUrl streamStatus } }`. `hlsUrl` is plain (not XOR'd) on live.mixcloud.com with an expiring token in the path. The master has 360p/720p video variants and `#EXT-X-MEDIA:TYPE=AUDIO,URI="index-audio.m3u8"`: AAC-LC 48 kHz stereo, 320 kbps (esds avgBitrate), 2 s CMAF segments (`tfhd` default-base-is-moof, `trun` sample sizes), sliding window of ~40, sequence numbers ~1.8e15. Introspection is denied; probe fields by trial (errors name the bad field). `/live/<user>/` links: `parseKey` must refuse user "live". HSEFM (House FM) broadcasts 24/7: handy for testing.
- REST list endpoints are public: `/<user>/{cloudcasts,favorites,listens,following,playlists}/`, `/discover/<tag>/{popular,latest}/`, `/categories/`, `/search/?type=cloudcast|user|tag`. Paging via `paging.next`. `is_exclusive` = Mixcloud Select (unplayable; hidden unless the pref is on).

## Follow in Lyrion
- Pref `follows` = { username => { name, image, added } }, on the server only (never sent to Mixcloud). `Followed` menu: "New from People You Follow" merges each followed user's last 10 uploads (cached 15 min), newest first, max 100.
- Follow entries sit LAST on a user page, so nothing else moves. LMS addresses OPML entries by position and remotes show stale pages, so the layout depends on the client: `handleFeed` reads `$args->{params}{menu}` (only the top level is told; LMS rebuilds from there on every request) and every passthrough to a user page carries `menu`. **Menu mode (Material)**: ONE toggle with no `type` and no `image`; Material treats it as a clickable text row, runs it in place (`doTextClick` → `browseHandleNextWindow`), shows the reply as a message and reloads the page (`nextWindow: refresh`). **Plain lists (LyrionJS's own look)**: "Follow in Lyrion" (shows "✓ Following in Lyrion" when following; idempotent) plus "Unfollow" only when following, with icons, because LyrionJS keeps its old page on Back. `setFollow` ignores a request for the same user within 2 s of the previous one: LyrionJS ≥0.2.33 re-asks every text reply in menu mode, which would hit the toggle. Its reply carries a `weblink`, or Material wraps a lone unclickable text item in `<div style=…>` and the message box shows that raw. "Live now" is always first. (Before 0.3.2: Follow first / Unfollow last, which shifted every entry by one, so a stale tap could land on the wrong entry, including Unfollow.) Verified on LMS 9.0.0: Material 6.4.14 in a browser (Playwright); the plain-list layout and the echo guard via JSON-RPC. Same design as ~/Projects/YouTube, where LyrionJS 0.2.34 was also tested in a browser.

## LMS gotchas (from KEXP, still apply)
- Material menu icons: an image path containing `MTL_icon_<name>` makes Material draw its own Material Design icon `<name>` (other skins show the PNG; `Plugin::_icon`, generated by `scripts/icon.py`). Material hides a list's images when they're all identical and always renders `type: search` items as bare text fields with no icon, so the top level is four links with distinct icons and the search fields live in a Search folder.
- Material only refreshes now-playing when the server pushes (`newmetadata`); it never polls, so `getMetadataFor` alone goes stale (LyrionJS polls and looked fine). `_scheduleTrackChange` sets a per-client timer for the next tracklist boundary (capped at 60 s) that re-runs `getMetadataFor`, which notifies on change.
- Playable rows use the full favourite title as `name` (LyrionJS saves favourites under `name`) with `line1`/`line2` for display.
- Don't give `link` items a `play` attribute (Material ⋮ menu loses Play).
- Most CLI menu queries hang without a connected player: start the test player.
- Squeezelite with `-c flac,pcm,mp3` forces the faad transcode path (handler → faad | flac).

## No secrets
The Mixcloud APIs used are public and unauthenticated; `.env` exists only by convention.
