#!/usr/bin/env bash
# Release a new version of the office365-mcp Docker image.
#
# Usage:
#   ./release.sh 1.0.1 [notes...]        rebuild + push + tag + GitHub release
#   ./release.sh 1.0.1 --no-build        push the existing local image as-is
#   O365_MCP_VERSION=5.2.0 ./release.sh 1.0.1 "bump upstream"
#
# What it does:
#   1. Rebuilds the image (docker build, no cache)
#   2. Tags it teejeer/office365-mcp:<version> and :latest
#   3. Pushes both tags to Docker Hub
#   4. Tags git v<version> and pushes to origin
#   5. Creates a GitHub release (Teejer/office365-mcp)
#   6. Records the baked-in upstream package version in the release notes
#
# The upstream package is baked into the image at build time; its version is
# the O365_MCP_VERSION build arg (see Dockerfile). Override it per release:
#   O365_MCP_VERSION=5.2.0 ./release.sh 1.0.1 "upgrade upstream to 5.2.0"
#
# Requirements: docker (logged in as teejeer), gh (authenticated), git.
set -euo pipefail

IMAGE_HUB="teejeer/office365-mcp"
GH_REPO="Teejer/office365-mcp"
PKG="@jbctechsolutions/mcp-office365"
NO_BUILD=0

VERSION="${1:-}"
shift || true
if [[ "${1:-}" == "--no-build" ]]; then NO_BUILD=1; shift || true; fi
NOTES="${*:-"Release ${VERSION}"}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <semver e.g. 1.0.1> [--no-build] [release notes]"
  exit 1
fi

cd "$(dirname "$0")"

# --- sanity checks -----------------------------------------------------------
git diff --quiet --ignore-submodules HEAD -- || { echo "!! uncommitted changes — commit or stash first"; exit 1; }
# Live auth check: request a push-scoped token for our repo from the registry.
# (More reliable than parsing docker info / config.json, which vary by version
# and credential helper.)
HUB_USER="${IMAGE_HUB%%/*}"
docker push "${IMAGE_HUB}:__auth_probe__" 2>&1 | grep -qiE 'denied|unauthorized|no access' \
  && { echo "!! docker not logged in to Docker Hub as ${HUB_USER} (push denied)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "!! gh not authenticated"; exit 1; }
if git ls-remote --tags origin "v${VERSION}" | grep -q .; then
  echo "!! git tag v${VERSION} already exists on origin"; exit 1
fi

# --- build -------------------------------------------------------------------
if [[ "$NO_BUILD" -eq 0 ]]; then
  echo "==> docker build (no cache, O365_MCP_VERSION=${O365_MCP_VERSION:-Dockerfile default})"
  if [[ -n "${O365_MCP_VERSION:-}" ]]; then
    docker build --no-cache --build-arg O365_MCP_VERSION="$O365_MCP_VERSION" -t office365-mcp:latest .
  else
    docker build --no-cache -t office365-mcp:latest .
  fi
else
  docker inspect office365-mcp:latest >/dev/null || { echo "!! no local office365-mcp:latest to publish"; exit 1; }
  echo "==> skipping build, publishing existing local image"
fi

# --- which upstream version is baked into the image ---------------------------
# serverInfo reports the resolved upstream package version on MCP initialize.
UPSTREAM_VER=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"release","version":"0"}}}' \
  | timeout 60 docker run -i --rm --entrypoint mcp-office365 office365-mcp:latest --preset files 2>/dev/null \
  | grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' | tail -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') || UPSTREAM_VER=""
if [[ -n "$UPSTREAM_VER" ]]; then
  echo "==> image has ${PKG}@${UPSTREAM_VER} baked in"
else
  echo "==> (could not determine baked-in upstream version — continuing)"
fi

# --- tag & push to docker hub -------------------------------------------------
echo "==> tagging + pushing ${IMAGE_HUB}:${VERSION} and :latest"
docker tag office365-mcp:latest "${IMAGE_HUB}:${VERSION}"
docker tag office365-mcp:latest "${IMAGE_HUB}:latest"
docker push "${IMAGE_HUB}:${VERSION}"
docker push "${IMAGE_HUB}:latest"

# --- git tag + github release ---------------------------------------------------
BODY="${NOTES}"
if [[ -n "$UPSTREAM_VER" ]]; then
  BODY="${BODY}

Upstream: \`${PKG}@${UPSTREAM_VER}\`"
fi
echo "==> tagging git v${VERSION} and creating GitHub release"
git tag -a "v${VERSION}" -m "v${VERSION}"
git push origin "v${VERSION}"
gh release create "v${VERSION}" --repo "$GH_REPO" --title "v${VERSION}" --notes "$BODY" || {
  echo "!! GitHub release failed (does the tag already have a release?) — image and git tag are published, create the release manually if needed."
}

echo
echo "==> done: ${IMAGE_HUB}:${VERSION} + :latest, git tag v${VERSION}, release created."
