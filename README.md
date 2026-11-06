# Mixcloud Direct for Lyrion

A [Lyrion Music Server](https://lyrion.org) plugin for Mixcloud that needs
**no helper application** (no yt-dlp, no Python) and works on **Lyrion 8 and 9**,
including 9.0/9.1 where the official Mixcloud plugin can't log in.

- **My Mixcloud**: your uploads, favourites, listening history, playlists and
  the people you follow. Enter your username once; no password or login.
- **Search** shows, DJs & stations, and genres, or paste a Mixcloud link
- **Music and Talk categories**, each with Popular and Latest
- **192 kbps AAC** where Mixcloud offers it (64 kbps for older uploads), with
  accurate seeking
- **Now playing follows the tracklist** when the show has one
- Favourites, alarms and playlists work like any other station

## Install

Settings → Plugins → *Additional repositories* (bottom of the page), add:

    https://raw.githubusercontent.com/Ethros19/lyrion-mixcloud/main/repo.xml

Then enable **Mixcloud Direct**, restart Lyrion, and set your username under
Settings → Plugins → Mixcloud Direct (or from the Mixcloud menu itself).

If you also have the original Mixcloud plugin installed, you can disable it;
the two don't share settings or URLs.

## Why another Mixcloud plugin?

Late in 2026 the official plugin broke on older servers in three ways:

1. **Login**: Mixcloud's OAuth endpoint replies with `Content-Encoding: identity`,
   which Lyrion before 9.2 tries to inflate, leaving an empty response.
2. **Playback**: it shells out to yt-dlp, which needs a bundled binary or a
   modern Python on the server.
3. **HTTP/1.0 and the User-Agent**: Mixcloud now answers HTTP/1.0 requests
   (Lyrion's default) with `426 Upgrade Required`, and its CDN returns `403`
   for Lyrion's default `iTunes/…` User-Agent.

This plugin avoids all three: it uses only the public REST and GraphQL APIs
(no OAuth, so no `identity` responses), fetches and demuxes Mixcloud's HLS
stream itself in Perl, and sends HTTP/1.1 requests with its own User-Agent.

## Development

    scripts/dev-server.sh     # Lyrion 9.0.0 in Docker on :9100, plugin mounted live
    scripts/test-player.sh    # headless squeezelite (plays faster than real time)
    scripts/lms.sh 00:11:22:33:44:66 '["mixclouddirect","items",0,10]'
    prove tests/              # unit tests (Util: decoding, HLS, TS demux, ADTS)
    python3 scripts/smoke.py  # are Mixcloud's services still as assumed?
    scripts/serve-lan.sh      # serve a build to a Lyrion server on your LAN
    scripts/release.sh        # tag + GitHub release (bump install.xml first)

## License

GPL-2.0, like Lyrion itself. Menu icons use glyphs from Google's
[Material Icons](https://github.com/google/material-design-icons) (Apache-2.0).
