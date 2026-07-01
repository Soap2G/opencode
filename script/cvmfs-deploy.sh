#!/usr/bin/env bash
#
# Build lumi from source and deploy to CVMFS.
#
# Usage:
#   ./script/cvmfs-deploy.sh                    # build + stage locally
#   ./script/cvmfs-deploy.sh --publish           # also publish to CVMFS
#
# Prerequisites:
#   - bun (https://bun.sh)
#   - CVMFS publisher access (for --publish)
#
# The script:
#   1. Builds the opencode binary for linux-x64 (lxplus target)
#   2. Stages it into a versioned directory with a `lumi` symlink
#   3. Creates the setup.sh that users will source
#   4. Optionally publishes to CVMFS
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CVMFS_BASE="/cvmfs/sw.escape.eu/lumi"
STAGE_DIR="${REPO_ROOT}/dist/cvmfs-stage"
PUBLISH=false

for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Determine version
# ---------------------------------------------------------------------------
VERSION=$(node -e "console.log(require('${REPO_ROOT}/packages/opencode/package.json').version)")
echo "==> Building lumi v${VERSION}"

# ---------------------------------------------------------------------------
# 2. Build the binary (linux-x64 for lxplus, or current platform for testing)
# ---------------------------------------------------------------------------
cd "${REPO_ROOT}/packages/opencode"

# If on macOS (dev machine), build for current platform for testing.
# On Linux (CI/lxplus), build the real target.
echo "==> Running bun build (--single for current platform)..."
bun run build --single

# Find the built binary
BUILT_BIN=$(find "${REPO_ROOT}/packages/opencode/dist" -name "opencode" -type f ! -name "*.exe" | head -1)
if [ -z "$BUILT_BIN" ]; then
  echo "ERROR: Could not find built binary"
  exit 1
fi
echo "==> Built binary: ${BUILT_BIN}"

# ---------------------------------------------------------------------------
# 3. Stage the CVMFS directory structure
# ---------------------------------------------------------------------------
DEST="${STAGE_DIR}/${VERSION}"
rm -rf "${DEST}"
mkdir -p "${DEST}/bin"
mkdir -p "${DEST}/etc"

cp "${BUILT_BIN}" "${DEST}/bin/opencode"
chmod +x "${DEST}/bin/opencode"
ln -sf opencode "${DEST}/bin/lumi"

# Write version marker
echo "${VERSION}" > "${DEST}/VERSION"

# Write default opencode.json config
cat > "${DEST}/etc/opencode.json" << 'CONFIG_EOF'
{
  "$schema": "https://opencode.ai/config.json",

  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "CERN LiteLLM Gateway",
      "env": ["LITELLM_API_KEY"],
      "options": {
        "baseURL": "https://llmgw-litellm.web.cern.ch/v1"
      },
      "models": {
        "devstral-small-latest": {
          "name": "Devstral Small (Mistral coding)",
          "tool_call": true,
          "temperature": true,
          "reasoning": false,
          "attachment": false,
          "release_date": "2025-05-01",
          "limit": { "context": 131072, "output": 8192 }
        },
        "qwen/qwen3-32b": {
          "name": "Qwen 3 32B",
          "tool_call": true,
          "temperature": true,
          "reasoning": true,
          "attachment": false,
          "release_date": "2025-06-01",
          "limit": { "context": 32768, "output": 8192 }
        },
        "hf-qwen25-32b": {
          "name": "Qwen 2.5 32B (no tool calling)",
          "tool_call": false,
          "temperature": true,
          "reasoning": false,
          "attachment": false,
          "release_date": "2025-01-01",
          "limit": { "context": 32768, "output": 4096 }
        },
        "llama-3.1-8b-instruct": {
          "name": "Llama 3.1 8B (fast/lightweight)",
          "tool_call": true,
          "temperature": true,
          "reasoning": false,
          "attachment": false,
          "release_date": "2024-07-01",
          "limit": { "context": 8192, "output": 2048 }
        },
        "codestral-latest": {
          "name": "Codestral (Mistral code generation)",
          "tool_call": true,
          "temperature": true,
          "reasoning": false,
          "attachment": false,
          "release_date": "2025-01-01",
          "limit": { "context": 131072, "output": 8192 }
        },
        "meta-llama/llama-4-scout-17b-16e-instruct": {
          "name": "Llama 4 Scout 17B",
          "tool_call": true,
          "temperature": true,
          "reasoning": false,
          "attachment": false,
          "release_date": "2025-04-01",
          "limit": { "context": 131072, "output": 8192 }
        }
      }
    }
  },

  "model": "litellm/devstral-small-latest",
  "small_model": "litellm/llama-3.1-8b-instruct",

  "mcp": {
    "atlasopenmagic": {
      "type": "remote",
      "url": "https://atlasopenmagic-mcp.app.cern.ch/mcp",
      "oauth": false
    }
  }
}
CONFIG_EOF

# Write setup.sh
cat > "${DEST}/bin/setup.sh" << 'SETUP_EOF'
#!/usr/bin/env bash
# Lumi setup script for CVMFS
# Usage: source /cvmfs/sw.escape.eu/lumi/latest/bin/setup.sh

_lumi_dir="/cvmfs/sw.escape.eu/lumi/latest/bin"

# Add lumi to PATH (idempotent)
case ":${PATH}:" in
  *":${_lumi_dir}:"*) ;;
  *) export PATH="${_lumi_dir}:${PATH}" ;;
esac

# Lumi version info
export LUMI_VERSION="$(cat "${_lumi_dir}/../VERSION" 2>/dev/null || echo unknown)"

# Prevent opencode's built-in auto-update (we manage versions via CVMFS)
export OPENCODE_DISABLE_AUTOUPDATE=1

# Load shared config from CVMFS (user/project configs can override)
export OPENCODE_CONFIG="${_lumi_dir}/../etc/opencode.json"

# Load LiteLLM API key from per-user file if it exists
if [ -z "${LITELLM_API_KEY:-}" ] && [ -f "$HOME/.lumi/litellm-key" ]; then
  export LITELLM_API_KEY="$(cat "$HOME/.lumi/litellm-key")"
fi

echo "lumi v${LUMI_VERSION} ready"

unset _lumi_dir
SETUP_EOF
chmod +x "${DEST}/bin/setup.sh"

# Create/update the "latest" symlink
ln -sfn "${VERSION}" "${STAGE_DIR}/latest"

echo "==> Staged to: ${DEST}"
echo "    ${DEST}/bin/opencode    (binary)"
echo "    ${DEST}/bin/lumi        (symlink -> opencode)"
echo "    ${DEST}/bin/setup.sh    (user sources this)"
echo "    ${STAGE_DIR}/latest     (symlink -> ${VERSION})"

# ---------------------------------------------------------------------------
# 4. Publish to CVMFS (if requested)
# ---------------------------------------------------------------------------
if [ "$PUBLISH" = true ]; then
  echo "==> Publishing to CVMFS at ${CVMFS_BASE}..."

  # CVMFS publication transaction
  cvmfs_server transaction sw.escape.eu

  mkdir -p "${CVMFS_BASE}"
  rsync -a --delete "${STAGE_DIR}/" "${CVMFS_BASE}/"

  cvmfs_server publish sw.escape.eu

  echo "==> Published lumi v${VERSION} to ${CVMFS_BASE}"
  echo "    Users can now run:"
  echo "    source ${CVMFS_BASE}/latest/bin/setup.sh"
else
  echo ""
  echo "==> Dry run complete. To publish to CVMFS:"
  echo "    1. Copy ${STAGE_DIR}/ to a machine with CVMFS publisher access"
  echo "    2. Run: cvmfs_server transaction sw.escape.eu"
  echo "    3. Run: rsync -a --delete ${STAGE_DIR}/ ${CVMFS_BASE}/"
  echo "    4. Run: cvmfs_server publish sw.escape.eu"
  echo ""
  echo "    Or re-run with --publish on a CVMFS publisher node."
fi
