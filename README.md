<p align="center">
  <img src="src/MixcloudDirect/HTML/EN/plugins/MixcloudDirect/html/images/mixcloud-direct-2_svg.png" width="128" alt="Mixcloud Direct icon">
</p>

# Mixcloud Direct for Lyrion

**Mixcloud for Lyrion servers that can't run the official plugin.**

Built for a Lyrion 9.0 server that can't be upgraded, for anyone in the same spot.
Since late 2026 the official Mixcloud plugin needs **Lyrion 9.2 or later** to log in. On
older servers it can't log in, and it often can't play either, because it needs yt-dlp on the
server. This plugin plays Mixcloud's own streams directly, with **no login and no helper
application**, so it works where the official one doesn't.

| Lyrion / LMS version | Official Mixcloud plugin | Mixcloud Direct |
| --- | --- | --- |
| 8.x – 9.1 | login fails; playback needs yt-dlp | ✅ tested on 8.5.2, 9.0.0, 9.1.2 |
| 9.2+ | works | ✅ tested on 9.2.0 |

Tested with Material Skin, LyrionJS and Lyrion's default web UI. Squeezelite players get AAC
directly; players without AAC are transcoded by Lyrion as usual.

## Read-only: manage your account on mixcloud.com

This plugin **never logs in to Mixcloud and can't change your account.** It reads your
*public* profile by username. To follow DJs, favourite shows, edit playlists or upload,
use [mixcloud.com](https://www.mixcloud.com) or the Mixcloud app. Those changes show up in
Lyrion within about 10 minutes.

*Follow in Lyrion* (below) is separate: it's a list kept on your Lyrion server only. It
isn't sent to Mixcloud and doesn't appear in the Mixcloud app.

## What you get

- **My Mixcloud**: your shows, favourites, listening history, playlists and the people you
  follow, from your public profile. Enter your username once, in the menu or in settings.
- **Followed**: tap **Follow in Lyrion** on any DJ or station page, then open
  **New from People You Follow** for their latest uploads, newest first. Unfollow sits at the
  bottom of their page.
- **Live streams**: when a DJ or station is broadcasting on Mixcloud Live, a **Live now** entry
  appears on their page and at the top of **Followed**, and pasted `mixcloud.com/live/…` links
  play. Audio only, 320 kbps AAC, played like a radio station (no seeking). Live streams work
  as favourites too: they play whatever that DJ has on air.
- **Search**: shows, DJs & stations, and genres. Or paste a mixcloud.com link: a show plays,
  a profile opens, a live link plays the stream.
- **Music and Talk categories**, each with **Popular** and **Latest**.
- **192 kbps AAC** where Mixcloud offers it (older uploads are 64 kbps only), with accurate
  seeking.
- **Now playing follows the tracklist** when the show has one: the current song and artist,
  updating as the mix moves on (in Material too).
- Shows work in Lyrion's **Favourites**, presets and alarms like any station.
- Every menu has its own icon. Material Skin draws them in its own themed style.
- Mixcloud Select (subscriber-only) shows are hidden, since they can't be played here. A
  setting lists them anyway.
- **Settings → Plugins → Mixcloud Direct**: username, stream quality (192 or 64 kbps),
  Select shows, version, and links to this project and its issues.

## Install

In Lyrion: *Settings → Manage Plugins*, scroll to the bottom, and add this repository URL:

```
https://raw.githubusercontent.com/Ethros19/lyrion-mixcloud/main/repo.xml
```

Save, find **Mixcloud Direct** in the plugin list, tick it, apply, and restart when prompted.
It shows up under **My Apps** as **Mixcloud Direct**, so it's easy to tell apart from the official plugin if you have both. Updates appear in the same place after a new release.

If the official Mixcloud plugin is installed, you can untick it: the two don't share settings,
favourites or URLs. (Unticking a plugin from a repository uninstalls it; you can reinstall it
from the same list.)

## Help

Something not working, or have an idea? [Open an issue](https://github.com/Ethros19/lyrion-mixcloud/issues).
The plugin's settings page links there too. Please include your Lyrion version and, if a show
won't play, its mixcloud.com link.

## How it works

Three things changed on Mixcloud's side that older Lyrion servers trip over:

1. **Login**: Mixcloud's OAuth endpoint replies with `Content-Encoding: identity`, which Lyrion
   before 9.2 tries to decompress, leaving an empty response
   ([fixed in 9.2](https://github.com/LMS-Community/slimserver/commit/af0afcbe342da3397dfdcf19e733060efca37670)).
2. **HTTP/1.0**: Mixcloud answers HTTP/1.0 requests, Lyrion's default, with `426 Upgrade Required`.
3. **User-Agent**: Mixcloud's audio CDN returns `403` for Lyrion's default `iTunes/…` User-Agent.

Mixcloud Direct uses only Mixcloud's public REST and GraphQL APIs, so it never needs OAuth. It
sends HTTP/1.1 with its own User-Agent. It plays the HLS stream by fetching the segments itself
and passing the AAC inside them to Lyrion, in plain Perl: MPEG-TS for shows, and the audio-only
fragmented-MP4 rendition for live streams (the video is never downloaded). That costs about 1 ms of CPU per
10 s of audio, so it's comfortable on modest hardware.

## Release

Bump `<version>` in `src/MixcloudDirect/install.xml`, commit, then `./scripts/release.sh`.
It runs the tests, builds the zip, regenerates `repo.xml`, tags, pushes, and creates the GitHub release.

## Develop

```sh
./scripts/dev-server.sh          # Lyrion 9.0.0 on http://localhost:9100 with the plugin mounted
LMS_VERSION=9.2.0 ./scripts/dev-server.sh    # any other version
docker restart mixcloud-lms      # reload after editing Perl (then rerun test-player.sh)
docker logs -f mixcloud-lms      # plugin logs at INFO
./scripts/test-player.sh         # headless player for CLI testing (plays faster than real time)
./scripts/lms.sh 00:11:22:33:44:66 '["mixclouddirect","items",0,10]'   # browse via JSON-RPC
prove tests/                     # unit tests: URL decoding, HLS parsing, TS and fMP4 demux, ADTS
python3 scripts/smoke.py         # do Mixcloud's services still behave as assumed? (weekly in CI)
python3 scripts/icon.py          # regenerate the icons
./scripts/serve-lan.sh           # serve a build to a Lyrion server on your LAN, no GitHub needed
./scripts/installs.sh            # install counts
```

See `CLAUDE.md` for notes on how Mixcloud's services and Lyrion's internals behave.

## License

Copyright (C) 2026 Ethan Rosch

This plugin is free software, licensed under the [GNU General Public License, version 2](LICENSE)
or (at your option) any later version, the same license family as Lyrion Music Server itself.
Menu icons use glyphs from Google's [Material Icons](https://github.com/google/material-design-icons)
(Apache-2.0).

This is an unofficial, fan-made plugin, not affiliated with or endorsed by Mixcloud. The Mixcloud
name is Mixcloud's, and the icon is original artwork, not Mixcloud's logo. All audio and data come
from Mixcloud's public services, streamed for listening only, never downloaded or saved. To
support the DJs you listen to, consider [Mixcloud Select](https://www.mixcloud.com/select/).
