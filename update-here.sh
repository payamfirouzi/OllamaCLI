#!/usr/bin/env bash
# Update the current folder from the public OllamaCLI GitHub repo.
# This script is public so it can repair stale local folders with:
#   curl -fsSL https://raw.githubusercontent.com/payamfirouzi/OllamaCLI/main/update-here.sh | bash

set -euo pipefail

REPO_ZIP="${REPO_ZIP:-https://github.com/payamfirouzi/OllamaCLI/archive/refs/heads/main.zip}"
HERE="$(pwd)"
TMP_DIR="$(mktemp -d)"
ZIP_FILE="$TMP_DIR/OllamaCLI-main.zip"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

need_cmd curl
need_cmd unzip

echo "Updating this folder from GitHub main:"
echo "  $HERE"
echo

curl -fL "$REPO_ZIP" -o "$ZIP_FILE"
unzip -q "$ZIP_FILE" -d "$TMP_DIR"

SRC="$TMP_DIR/OllamaCLI-main"
if [[ ! -d "$SRC" ]]; then
    echo "Downloaded repo archive did not contain expected folder: $SRC" >&2
    exit 1
fi

cp -R "$SRC"/. "$HERE"/
chmod +x "$HERE/patch-agents.sh" "$HERE/Start-OllamaEnv.sh" "$HERE/update-here.sh" 2>/dev/null || true

echo
echo "Done. This folder now has the latest OllamaCLI files from GitHub main."
echo "Verify there is no sed usage:"
echo "  grep -n 'sed' *.sh || true"
echo
echo "Then run:"
echo "  bash patch-agents.sh"
