#!/usr/bin/env bash
# Release a new version of the office365-mcp Docker image.
#
# Usage:
#   ./release.sh 1.0.1 [notes...]        rebuild + push + tag + GitHub release
#   ./release.sh 1.0.1 --no-build        push the existing local image as-is
#
# What it does:
#   1. Rebuilds the image (docker build, no cache)
#   2. Tags it teejeer/office365-mcp:<version> and :latest
#   3. Pushes both tags to Docker Hub
#   4. Tags git v<version> and pushes to origin
#   5. Creates a GitHub release (Teejer/office365-mcp)
#   6. Records the current upstream package version in the release notes
#      (the image resolves it via npx at container start, not build time)
#
# Requirements: docker (logged in as teejeer), gh (authenticated), git.
#
# Tip: for a reproducible image, pin the upstream in the Dockerfile ENTRYPOINT
# (e.g. @jbctechsolutions/mcp-office365@5.1.1) before releasing.
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
[[ -n "$(docker info 2>/dev/null | grep 'Username: teejeer')" ]] || { echo "!! docker not logged in as teejeer"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "!! gh not authenticated"; exit 1; }
if git ls-remote --tags origin "v${VERSION}" | grep -q .; then
  echo "!! git tag v${VERSION} already exists on origin"; exit 1
fi

# --- build -------------------------------------------------------------------
if [[ "$NO_BUILD" -eq 0 ]]; then
  echo "==> docker build (no cache)"
  docker build --no-cache -t office365-mcp:latest .
else
  docker inspect office365-mcp:latest >/dev/null || { echo "!! no local office365-mcp:latest to publish"; exit 1; }
  echo "==> skipping build, publishing existing local image"
fi

# --- show which upstream version the image will use ---------------------------
# The image resolves the upstream package via npx at container START, so the
# best available record is whatever is current on npm at release time.
UPSTREAM_VER=$(curl -s https://registry.npmjs.org/@jbctechsolutions%2fmcp-office365 \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['dist-tags']['latest'])" 2>/dev/null) || UPSTREAM_VER=""
if [[ -n "$UPSTREAM_VER" ]]; then
  echo "==> upstream ${PKG} is currently ${UPSTREAM_VER} on npm"
else
  echo "==> (could not determine upstream version — continuing)"
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
