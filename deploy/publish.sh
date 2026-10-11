#!/usr/bin/env bash
# =============================================================================
# Script: publish.sh
# Version: 1.0.0
# Created: 2026-10-11
#
# Summary:
#   Purpose:
#     Builds this fork from an explicit release tag (never a floating
#     branch), on a dedicated build host — never the host ARTEX itself ends
#     up running on. Pushes ghcr.io/${GHCR_NAMESPACE}/${GHCR_REPO}:<tag> and
#     :latest, and creates a matching GitHub Release (linux/amd64 zip +
#     SHA256SUMS) on this repo. linux/amd64 only — this is a Docker
#     deployment, not a native multi-platform binary distribution.
#
#   Usage:
#     ./publish.sh v0.1.0          # build + push + release that tag
#     ./publish.sh v0.1.0 --force  # rebuild even if already published
#     ./publish.sh v0.1.0 --check  # report status only, do nothing
#
#   Prerequisites:
#     - git + docker on the build host (the actual Go/Node toolchain runs
#       inside disposable golang/node containers — nothing else to
#       install)
#     - gh CLI (github.com/cli/cli), for the Release step only
#     - a classic GitHub PAT, write:packages + repo scope. Use a classic
#       token (github.com/settings/tokens), NOT a fine-grained one — GHCR
#       push does not work reliably with a fine-grained PAT regardless of
#       the scopes it's granted.
#     - GHCR defaults a new package to PRIVATE on first push — flip it to
#       Public once in GitHub's package settings (one-time).
#     - This repo must itself be public for the Release and a public GHCR
#       package to be pullable without extra credentials.
#
#   Warnings:
#     - Builds an explicit tag you pass, not a moving branch — there is no
#       "track main and rebuild on drift" behaviour here. Create/push the
#       tag first.
#     - Runs `git checkout <tag>` IN THIS SAME CLONE (it builds from the
#       repo it lives in, not a separate copy) — it will move you off
#       whatever branch you're on. Use a clone dedicated to publishing, or
#       stash/note your branch first if you run this from a working copy
#       you also develop in.
#     - The mounted source is read as the build context for `go build`,
#       and the build container runs as root, so git sees the bind-mounted
#       working tree as having "dubious ownership" and refuses to stamp
#       VCS info unless told not to try: -buildvcs=false. Confirmed
#       necessary against this exact repo (plain `go build` inside the
#       same container fails with "error obtaining VCS status: exit status
#       128" without that flag).
#     - This repo's own Dockerfile expects a pre-built dist/${TARGETARCH}/
#       artex binary already in the build context (see its header
#       comment) — it does not compile inside the image. This script does
#       that build first: a static frontend export via a node:20-bookworm
#       container, then the Go binary via a golang:1.26-bookworm container
#       (-tags embedui -buildvcs=false).
#
# Changelog:
#   1.0.0 (2026-10-11) - Initial version.
#
# =============================================================================

set -euo pipefail

# ---- configuration ----------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_ROOT="${PUBLISH_STATE_ROOT:-${REPO_ROOT}/deploy/build}"
LOG_FILE="${STATE_ROOT}/publish.log"
GHCR_TOKEN_FILE="${STATE_ROOT}/.ghcr-token"   # chmod 600, gitignored

GHCR_NAMESPACE="braedach"
GHCR_REGISTRY="ghcr.io"
GHCR_REPO="artex"           # ghcr.io/braedach/artex — matches the repo name,
                             # so GitHub links the package to it automatically.
GH_REPO_SLUG="Braedach/ARTEX"

# ---- colour helpers -----------------------------------------------------
COL_RESET='\033[0m'; COL_BLUE='\033[0;34m'; COL_GREEN='\033[0;32m'
COL_YELLOW='\033[0;33m'; COL_RED='\033[0;31m'
info()  { echo -e "${COL_BLUE}[INFO]${COL_RESET} $*"  | tee -a "$LOG_FILE"; }
warn()  { echo -e "${COL_YELLOW}[WARN]${COL_RESET} $*" | tee -a "$LOG_FILE" >&2; }
error() { echo -e "${COL_RED}[ERROR]${COL_RESET} $*"  | tee -a "$LOG_FILE" >&2; }
ok()    { echo -e "${COL_GREEN}[OK]${COL_RESET} $*"   | tee -a "$LOG_FILE"; }

# ---- args ---------------------------------------------------------------
FORCE=0
CHECK_ONLY=0
TAG=""
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    --check)    CHECK_ONLY=1 ;;
    v*)         TAG="$arg" ;;
    *) error "Unknown argument: $arg (expected a tag like v0.1.0, --force, or --check)"; exit 1 ;;
  esac
done
if [[ -z "$TAG" ]]; then
  error "Usage: $0 <tag e.g. v0.1.0> [--force] [--check]"
  exit 1
fi
VERSION="${TAG#v}"

mkdir -p "$STATE_ROOT"

# ---- GHCR + GitHub auth (mandatory, skipped for --check) --------------------
if [[ "$CHECK_ONLY" -eq 0 ]]; then
  GH_TOKEN_VAL=""
  FROM_CACHE=0
  if [[ -f "$GHCR_TOKEN_FILE" ]]; then
    GH_TOKEN_VAL=$(cat "$GHCR_TOKEN_FILE")
    FROM_CACHE=1
  elif [[ -t 0 ]]; then
    read -srp "GitHub token (classic PAT, write:packages + repo scope): " GH_TOKEN_VAL
    echo
  else
    error "No GHCR_TOKEN_FILE and no TTY to prompt (unattended run before first interactive setup?)."
    error "Run once interactively first, or: echo \"ghp_xxx\" > ${GHCR_TOKEN_FILE} && chmod 600 ${GHCR_TOKEN_FILE}"
    exit 1
  fi

  info "Logging in to ${GHCR_REGISTRY} as ${GHCR_NAMESPACE}..."
  LOGIN_OK=0
  if echo "${GH_TOKEN_VAL}" | docker login "${GHCR_REGISTRY}" --username "${GHCR_NAMESPACE}" --password-stdin; then
    LOGIN_OK=1
  elif [[ "$FROM_CACHE" -eq 1 ]]; then
    warn "${GHCR_REGISTRY} login failed with the cached token in ${GHCR_TOKEN_FILE} - it has likely expired or been revoked."
    rm -f "$GHCR_TOKEN_FILE"
    warn "Removed the stale token file."
    if [[ -t 0 ]]; then
      read -srp "Replacement GitHub token (classic PAT, write:packages + repo scope): " GH_TOKEN_VAL
      echo
      FROM_CACHE=0
      if echo "${GH_TOKEN_VAL}" | docker login "${GHCR_REGISTRY}" --username "${GHCR_NAMESPACE}" --password-stdin; then
        LOGIN_OK=1
      fi
    fi
  fi

  if [[ "$LOGIN_OK" -eq 1 ]]; then
    ok "${GHCR_REGISTRY} login successful"
  else
    error "${GHCR_REGISTRY} login failed - check GHCR_NAMESPACE and the token (needs write:packages scope, classic token)."
    exit 1
  fi

  if [[ ! -f "$GHCR_TOKEN_FILE" && -t 0 ]]; then
    read -rp "Save for future/repeat runs at ${GHCR_TOKEN_FILE}? [y/N] " save_answer
    if [[ "$save_answer" =~ ^[Yy] ]]; then
      umask 077
      echo "$GH_TOKEN_VAL" > "$GHCR_TOKEN_FILE"
      chmod 600 "$GHCR_TOKEN_FILE"
      info "Saved to ${GHCR_TOKEN_FILE} (chmod 600)"
    fi
  fi

  command -v gh >/dev/null 2>&1 || { error "gh CLI not found - needed to create the GitHub Release. Install github.com/cli/cli."; exit 1; }
  export GH_TOKEN="$GH_TOKEN_VAL"
fi

# ---- check out the requested tag in-place -----------------------------------
git -C "$REPO_ROOT" fetch origin --tags
git -C "$REPO_ROOT" checkout "$TAG"
CURRENT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
info "Source at ${TAG} (${CURRENT_SHA})"

STATE_FILE="${STATE_ROOT}/.publish-state"
if [[ -f "$STATE_FILE" ]] && grep -q "^tag=${TAG}\$" "$STATE_FILE" 2>/dev/null && [[ "$FORCE" -eq 0 ]]; then
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    info "Check-only: ${TAG} already published - nothing to do"
    exit 0
  fi
  ok "${TAG} already built and published - nothing to do (use --force to rebuild/republish)"
  exit 0
fi
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  info "Check-only: ${TAG} not yet published"
  exit 0
fi

# ---- build: static frontend export (disposable node container) -------------
info "Building static frontend export (node:20-bookworm)..."
docker run --rm -v "${REPO_ROOT}":/repo -w /repo/web node:20-bookworm \
  bash -c "npm ci --include=dev && npm run build:static" 2>&1 | tee -a "$LOG_FILE"

rm -rf "${REPO_ROOT}/server/webui/dist"
mkdir -p "${REPO_ROOT}/server/webui"
cp -r "${REPO_ROOT}/web/out" "${REPO_ROOT}/server/webui/dist"
ok "Frontend synced into server/webui/dist"

# ---- build: Go binary (disposable golang container) -------------------------
info "Compiling Go binary (golang:1.26-bookworm, -tags embedui)..."
mkdir -p "${REPO_ROOT}/dist/amd64"
docker run --rm -v "${REPO_ROOT}":/repo -w /repo \
  -e CGO_ENABLED=0 -e GOARCH=amd64 -e GOOS=linux golang:1.26-bookworm \
  go build -tags embedui -trimpath -buildvcs=false -o dist/amd64/artex ./cmd/artex 2>&1 | tee -a "$LOG_FILE"
[[ -s "${REPO_ROOT}/dist/amd64/artex" ]] || { error "Binary not produced at dist/amd64/artex"; exit 1; }
ok "Binary built: $(du -h "${REPO_ROOT}/dist/amd64/artex" | cut -f1)"

# ---- build: Docker image via the repo's own Dockerfile -----------------------
IMAGE_LOCAL="artex:${TAG}"
info "docker build (uses the pre-built dist/amd64/artex above)..."
docker build -t "$IMAGE_LOCAL" "$REPO_ROOT" 2>&1 | tee -a "$LOG_FILE"
ok "Image built: ${IMAGE_LOCAL}"

# ---- push to GHCR: version tag + :latest ------------------------------------
GHCR_REF_VER="${GHCR_REGISTRY}/${GHCR_NAMESPACE}/${GHCR_REPO}:${TAG}"
GHCR_REF_LATEST="${GHCR_REGISTRY}/${GHCR_NAMESPACE}/${GHCR_REPO}:latest"
docker tag "$IMAGE_LOCAL" "$GHCR_REF_VER"
docker tag "$IMAGE_LOCAL" "$GHCR_REF_LATEST"
info "Pushing ${GHCR_REF_VER}..."
docker push "$GHCR_REF_VER"
info "Pushing ${GHCR_REF_LATEST}..."
docker push "$GHCR_REF_LATEST"
ok "Pushed ${GHCR_REF_VER} and ${GHCR_REF_LATEST}"

# ---- package the linux/amd64 zip + checksums, same shape as this repo's own
#      (unused, by-hand-replaced) release.yml, so it's a familiar artifact
#      shape -----------------------------------------------------------------
PKG_DIR="${STATE_ROOT}/pkg"
rm -rf "$PKG_DIR"
mkdir -p "${PKG_DIR}/artex-${VERSION}-linux-amd64"
cp "${REPO_ROOT}/dist/amd64/artex" "${PKG_DIR}/artex-${VERSION}-linux-amd64/"
cp "${REPO_ROOT}/start.sh" "${PKG_DIR}/artex-${VERSION}-linux-amd64/"
cp -r "${REPO_ROOT}/skills" "${PKG_DIR}/artex-${VERSION}-linux-amd64/"
(cd "$PKG_DIR" && zip -qr "artex-${VERSION}-linux-amd64.zip" "artex-${VERSION}-linux-amd64")
(cd "$PKG_DIR" && sha256sum "artex-${VERSION}-linux-amd64.zip" > SHA256SUMS)
ok "Packaged ${PKG_DIR}/artex-${VERSION}-linux-amd64.zip"

# ---- create the GitHub Release ----------------------------------------------
info "Creating GitHub Release ${TAG} on ${GH_REPO_SLUG}..."
gh release create "$TAG" \
  --repo "$GH_REPO_SLUG" \
  --title "ARTEX ${TAG}" \
  --generate-notes \
  "${PKG_DIR}/artex-${VERSION}-linux-amd64.zip" \
  "${PKG_DIR}/SHA256SUMS"
ok "Release ${TAG} published: https://github.com/${GH_REPO_SLUG}/releases/tag/${TAG}"

# ---- record state, clean up local images ------------------------------------
{
  echo "tag=${TAG}"
  echo "sha=${CURRENT_SHA}"
  echo "published=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STATE_FILE"

docker rmi "$IMAGE_LOCAL" "$GHCR_REF_VER" "$GHCR_REF_LATEST" >/dev/null 2>&1 || warn "Could not remove local images after push (non-fatal)"
docker image prune -f | tee -a "$LOG_FILE"

ok "Build and publish complete for ${TAG}"
echo ""
info "Published:"
echo "    ${GHCR_REF_VER}"
echo "    ${GHCR_REF_LATEST}"
echo "    https://github.com/${GH_REPO_SLUG}/releases/tag/${TAG}"
echo ""
warn "First-ever push of this image defaults to PRIVATE on GHCR - flip it to Public"
warn "once in GitHub's package settings. Tags pushed after that stay public automatically."
