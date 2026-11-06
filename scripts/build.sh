#!/usr/bin/env bash
# Package the plugin as dist/MixcloudDirect-<version>.zip (files at zip root,
# the layout LMS repo installs expect) and regenerate repo.xml to point at it.
# BASE_URL overrides where the zip is downloaded from (default: the GitHub
# release), e.g. BASE_URL=http://192.168.1.50:8765 to serve it over the LAN.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=Ethros19/lyrion-mixcloud
version=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' src/MixcloudDirect/install.xml)
zip="dist/MixcloudDirect-$version.zip"
base=${BASE_URL:-https://github.com/$REPO/releases/download/v$version}

mkdir -p dist
rm -f "$zip"
(cd src/MixcloudDirect && zip -qr "../../$zip" . -x '*.DS_Store')
sha=$(shasum "$zip" | cut -d' ' -f1)

cat > "${REPO_XML:-repo.xml}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<extensions>
	<details>
		<title lang="EN">Mixcloud Direct</title>
	</details>
	<plugins>
		<plugin name="MixcloudDirect" version="$version" minTarget="8.0" maxTarget="*">
			<title lang="EN">Mixcloud Direct</title>
			<desc lang="EN">Browse and play Mixcloud shows with no helper application: search, categories, and any user's uploads, favourites, playlists and follows. Works on Lyrion 8 and 9.</desc>
			<creator>Ethan Rosch</creator>
			<category>musicservices</category>
			<link>https://github.com/$REPO</link>
			<url>$base/MixcloudDirect-$version.zip</url>
			<sha>$sha</sha>
		</plugin>
	</plugins>
</extensions>
XML

echo "$zip ($sha)"
