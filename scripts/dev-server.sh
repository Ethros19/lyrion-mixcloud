#!/usr/bin/env bash
# Throwaway Lyrion 9.0.0 (the oldest version we support, and the one whose
# HTTP client mishandles Mixcloud's "Content-Encoding: identity") in Docker
# with this plugin mounted live. Web UI: http://localhost:9100
# Restart the container to reload Perl code: docker restart mixcloud-lms
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .dev/config
docker rm -f mixcloud-lms >/dev/null 2>&1 || true
docker run -d --name mixcloud-lms \
  -p 9100:9000 -p 9190:9090 \
  -v "$PWD/.dev/config:/config" \
  -v "$PWD/src/MixcloudDirect:/config/cache/Plugins/MixcloudDirect:ro" \
  -e EXTRA_ARGS="--debug plugin.mixclouddirect=INFO" \
  "lmscommunity/lyrionmusicserver:${LMS_VERSION:-9.0.0}"
echo "Lyrion starting on http://localhost:9100 (logs: docker logs -f mixcloud-lms)"
