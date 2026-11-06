#!/usr/bin/env python3
"""Check that Mixcloud still behaves the way the plugin assumes.

None of this is documented, so it's checked weekly in CI:
  - REST (api.mixcloud.com) browsing works unauthenticated and sends no
    "Content-Encoding: identity" (LMS < 9.2 turns that into an empty body)
  - GraphQL streamInfo urls still decode with the XOR key
  - the HLS master has variants, media playlists list .ts segments, and a
    segment is MPEG-TS carrying ADTS AAC
  - the CDN still accepts our User-Agent (and, for the record, still 403s
    LMS's default "iTunes/..." one)

On python.org Python for macOS, run with SSL_CERT_FILE=/etc/ssl/cert.pem.
"""

import base64
import itertools
import json
import sys
import urllib.parse
import urllib.request
import urllib.error

KEY = "IFYOUWANTTHEARTISTSTOGETPAIDDONOTDOWNLOADFROMMIXCLOUD"
UA = "Lyrion Music Server (MixcloudDirect/smoke)"
LMS_UA = "iTunes/4.7.1 (Linux; N; Debian; x86_64-linux; EN; utf8) SqueezeCenter, Squeezebox Server, Lyrion Music Server/9.0.0"

failures = []


def get(url, ua=UA, raw=False):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Accept-Encoding": "identity"})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
        return r.headers, (body if raw else body.decode("utf-8"))


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f" ({detail})" if detail else ""))
    if not ok:
        failures.append(name)


def decode(b64):
    data = base64.b64decode(b64)
    return "".join(chr(c ^ ord(k)) for c, k in zip(data, itertools.cycle(KEY)))


# REST
headers, body = get("https://api.mixcloud.com/discover/house/popular/?limit=5")
data = json.loads(body)
check("REST discover returns shows", len(data.get("data", [])) == 5)
check("REST sends no Content-Encoding: identity", headers.get("Content-Encoding") != "identity", headers.get("Content-Encoding") or "none")
check("REST entries have key/name/pictures", all(k in data["data"][0] for k in ("key", "name", "pictures", "audio_length")))
check("REST paging.next present", "next" in data.get("paging", {}))

headers, body = get("https://api.mixcloud.com/dholbach/favorites/?limit=2")
check("REST user favourites public", len(json.loads(body).get("data", [])) == 2)

# GraphQL
query = """{ cloudcastLookup(lookup: {username: "dholbach", slug: "cryptkeeper"}) {
  name audioLength restrictedReason streamInfo { url hlsUrl }
  sections { __typename ... on TrackSection { artistName songName startSeconds } } } }"""
headers, body = get("https://app.mixcloud.com/graphql?query=" + urllib.parse.quote(query))
show = json.loads(body)["data"]["cloudcastLookup"]
check("GraphQL sends no Content-Encoding: identity", headers.get("Content-Encoding") != "identity")
check("GraphQL show found", show and show["name"] == "Cryptkeeper")
check("GraphQL tracklist has start times", len(show.get("sections") or []) > 5 and show["sections"][1]["startSeconds"] > 0)

hls = decode(show["streamInfo"]["hlsUrl"])
check("hlsUrl decodes", hls.startswith("https://") and ".m3u8" in hls, hls[:60])

# HLS
_, master = get(hls)
variants = [l for l in master.splitlines() if l and not l.startswith("#")]
check("HLS master lists variants", "#EXT-X-STREAM-INF" in master and variants, f"{len(variants)} variant(s)")
media_url = urllib.parse.urljoin(hls, variants[0])
_, media = get(media_url)
segments = [l for l in media.splitlines() if l and not l.startswith("#")]
check("media playlist lists .ts segments", segments and segments[0].split("?")[0].endswith(".ts"), f"{len(segments)} segments")

_, seg = get(urllib.parse.urljoin(media_url, segments[0]), raw=True)
check("segment is MPEG-TS", seg[:1] == b"\x47" and seg[188:189] == b"\x47")
check("segment carries ADTS audio", b"\xff\xf1" in seg[:4096] or b"\xff\xf9" in seg[:4096])

# User-Agent handling on the CDN
try:
    get(hls, ua=LMS_UA)
    print("NOTE CDN now accepts LMS's default User-Agent")
except urllib.error.HTTPError as e:
    print(f"NOTE CDN rejects LMS's default User-Agent ({e.code}), as expected")

if failures:
    print(f"\n{len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("\nAll checks passed")
