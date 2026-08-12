#!/bin/bash
# =============================================================================
# Standalone LLM configuration script
# Updates model, url, and api_key in llm_config.json for registry-center
# and/or orchestration-center.
#
# Usage: ./configure_llm.sh --model <name> --url <url> --api-key <key> \
#                           --project registry|orchestration|all \
#                           --validate|--no-validate
# =============================================================================
set -euo pipefail

# =============================================================================
# Argument parsing
# =============================================================================
LLM_MODEL=""
LLM_URL=""
API_KEY_FLAG=""
PROJECT="all"
VALIDATE=true

DEFAULT_LLM_MODEL="qwen3.6-flash"
DEFAULT_LLM_URL="https://dashscope.aliyuncs.com/compatible-mode/v1"

print_usage() {
    cat << 'USAGE_EOF'
Usage: configure_llm.sh [OPTIONS]

Update LLM configuration (model, url, api_key) in llm_config.json.

Options:
  --model <name>       LLM model name (default: qwen3.6-flash)
  --url <url>          LLM API URL (default: https://dashscope.aliyuncs.com/compatible-mode/v1)
  --api-key <key>      API key (or set LLM_API_KEY env var)
  --project <target>   registry | orchestration | all (default: all)
  --validate           Validate API connection before writing (default)
  --no-validate        Skip API validation
  -h, --help           Show this help message and exit

Examples:
  ./configure_llm.sh --model glm-5.1 --url https://open.bigmodel.cn/api/paas/v4/chat/completions --api-key your-key
  ./configure_llm.sh --project registry --api-key your-key
  LLM_API_KEY=your-key ./configure_llm.sh --model glm-5.1 --url https://open.bigmodel.cn/api/paas/v4/chat/completions
USAGE_EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --model)
            LLM_MODEL="$2"
            shift 2
            ;;
        --url)
            LLM_URL="$2"
            shift 2
            ;;
        --api-key)
            API_KEY_FLAG="$2"
            shift 2
            ;;
        --project)
            PROJECT="$2"
            shift 2
            ;;
        --validate)
            VALIDATE=true
            shift
            ;;
        --no-validate)
            VALIDATE=false
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Apply defaults
LLM_MODEL="${LLM_MODEL:-${DEFAULT_LLM_MODEL}}"
LLM_URL="${LLM_URL:-${DEFAULT_LLM_URL}}"

# Resolve API key: --api-key flag takes priority over LLM_API_KEY env var.
# Note: Do NOT initialize LLM_API_KEY at the top of the script, as that would
# shadow the inherited environment variable. API_KEY_FLAG is used for the
# --api-key flag value, and LLM_API_KEY is read from the environment with
# ${LLM_API_KEY:-} to safely handle the case where it is not set.
if [ -n "${API_KEY_FLAG}" ]; then
    LLM_API_KEY="${API_KEY_FLAG}"
else
    LLM_API_KEY="${LLM_API_KEY:-}"
fi

if [ -z "${LLM_API_KEY}" ]; then
    echo "[ERROR] API key is required."
    echo "        Provide via --api-key flag or LLM_API_KEY environment variable."
    exit 1
fi

# Validate --project value
case "${PROJECT}" in
    registry|orchestration|all) ;;
    *)
        echo "[ERROR] Invalid --project value: ${PROJECT}"
        echo "        Valid values: registry, orchestration, all"
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Display configuration
# =============================================================================
KEY_LEN=${#LLM_API_KEY}
if [ "${KEY_LEN}" -gt 8 ]; then
    KEY_MASK="${LLM_API_KEY:0:4}...${LLM_API_KEY: -4}"
else
    KEY_MASK="***"
fi

echo "[CONFIG] LLM configuration:"
echo "         model:    ${LLM_MODEL}"
echo "         url:      ${LLM_URL}"
echo "         api_key:  ${KEY_MASK} (length=${KEY_LEN})"
echo "         project:  ${PROJECT}"
echo "         validate: ${VALIDATE}"
echo ""

# =============================================================================
# Function: validate LLM API key and URL by sending a minimal test request.
# Returns 0 if valid, 1 otherwise.
# =============================================================================
validate_llm() {
    local model="$1"
    local url="$2"
    local api_key="$3"

    # Construct the chat completions endpoint.
    # If the URL doesn't already end with /chat/completions, append it.
    local test_url="${url}"
    if [[ "${test_url}" != */chat/completions ]]; then
        test_url="${test_url%/}/chat/completions"
    fi

    echo "[TEST] Validating LLM connection..."
    echo "       URL:   ${test_url}"
    echo "       Model: ${model}"

    local tmp_resp http_code body
    tmp_resp=$(mktemp /tmp/llm-validate-XXXXXX)
    http_code=$(curl -s -o "${tmp_resp}" -w "%{http_code}" \
        -X POST "${test_url}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${api_key}" \
        -d "{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}], \"max_tokens\": 1}" \
        --connect-timeout 10 \
        --max-time 30 2>/dev/null) || http_code="000"
    body=$(cat "${tmp_resp}" 2>/dev/null)
    rm -f "${tmp_resp}"

    case "${http_code}" in
        200|201)
            echo "  [OK] LLM API validation successful (HTTP ${http_code})."
            return 0
            ;;
        401|403)
            echo "  [ERROR] Authentication failed (HTTP ${http_code}) — invalid API key."
            [ -n "${body}" ] && echo "          Response: $(printf '%.300s' "${body}")"
            return 1
            ;;
        404)
            echo "  [ERROR] Endpoint not found (HTTP 404) — invalid API URL."
            echo "          Tried: ${test_url}"
            [ -n "${body}" ] && echo "          Response: $(printf '%.300s' "${body}")"
            return 1
            ;;
        000)
            echo "  [ERROR] Cannot connect to ${test_url}."
            echo "          Please check the URL and your network connection."
            return 1
            ;;
        *)
            echo "  [ERROR] Validation failed (HTTP ${http_code})."
            [ -n "${body}" ] && echo "          Response: $(printf '%.300s' "${body}")"
            return 1
            ;;
    esac
}

# =============================================================================
# Step 1: Validate LLM connection (if enabled)
# =============================================================================
if [ "${VALIDATE}" = "true" ]; then
    if ! validate_llm "${LLM_MODEL}" "${LLM_URL}" "${LLM_API_KEY}"; then
        echo ""
        echo "[ERROR] LLM validation failed. Configuration was NOT written."
        echo "        Use --no-validate to skip validation."
        exit 1
    fi
    echo ""
else
    echo "[SKIP] LLM validation skipped (--no-validate)."
    echo ""
fi

# =============================================================================
# Step 2: Resolve Python command
# Try venv python first, fall back to system python3.
# configure_llm.sh only uses the standard library json module, so python3
# without venv is sufficient.
# =============================================================================
PYTHON_CMD=""

# Try registry-center venv
if [ -x "${SCRIPT_DIR}/registry-center/venv/bin/python" ]; then
    PYTHON_CMD="${SCRIPT_DIR}/registry-center/venv/bin/python"
# Try orchestration-center venv
elif [ -x "${SCRIPT_DIR}/orchestration-center/venv/bin/python" ]; then
    PYTHON_CMD="${SCRIPT_DIR}/orchestration-center/venv/bin/python"
# Fall back to system python3
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
else
    echo "[ERROR] Python 3 is required but not found."
    echo "        No venv found in registry-center/ or orchestration-center/,"
    echo "        and python3 is not available in PATH."
    exit 1
fi

echo "[PYTHON] Using: ${PYTHON_CMD}"
echo ""

# =============================================================================
# Step 3: Build target file list based on --project flag
# =============================================================================
LLM_CONFIGS=()
case "${PROJECT}" in
    registry)
        LLM_CONFIGS+=("${SCRIPT_DIR}/registry-center/common/config/llm_config.json")
        ;;
    orchestration)
        LLM_CONFIGS+=("${SCRIPT_DIR}/orchestration-center/common/config/llm_config.json")
        ;;
    all)
        LLM_CONFIGS+=("${SCRIPT_DIR}/registry-center/common/config/llm_config.json")
        LLM_CONFIGS+=("${SCRIPT_DIR}/orchestration-center/common/config/llm_config.json")
        ;;
esac

# =============================================================================
# Step 4: Update llm_config.json files
# =============================================================================
# Export API key as env var so Python can read it safely (avoids shell
# escaping issues with special characters in command-line arguments)
export LLM_API_KEY
export LLM_MODEL
export LLM_URL

SUCCESS_COUNT=0
FAIL_COUNT=0

for LLM_CONFIG in "${LLM_CONFIGS[@]}"; do
    if [ ! -f "${LLM_CONFIG}" ]; then
        echo "[WARN] ${LLM_CONFIG} not found, skipping."
        echo "       (Is the corresponding project installed?)"
        continue
    fi

    echo "[CONFIG] Updating ${LLM_CONFIG}..."

    if ! "${PYTHON_CMD}" -c "
import json, os, sys

config_path = sys.argv[1]
api_key = os.environ.get('LLM_API_KEY', '')
model = os.environ.get('LLM_MODEL', '')
url = os.environ.get('LLM_URL', '')

try:
    with open(config_path, 'r', encoding='utf-8') as f:
        config = json.load(f)
except json.JSONDecodeError as e:
    print(f'  [ERROR] Invalid JSON in {config_path}: {e}', file=sys.stderr)
    sys.exit(1)
except FileNotFoundError:
    print(f'  [ERROR] File not found: {config_path}', file=sys.stderr)
    sys.exit(1)

if 'chat' not in config:
    print(f'  [ERROR] Missing \"chat\" key in {config_path}', file=sys.stderr)
    sys.exit(1)

config['chat']['model'] = model
config['chat']['url'] = url
if api_key:
    config['chat']['api_key'] = api_key

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write('\n')

# Report what was written for verification
written_key = config.get('chat', {}).get('api_key', '(missing)')
if written_key and len(written_key) > 8:
    display = written_key[:4] + '...' + written_key[-4:]
else:
    display = '***'
print(f'  chat.model    = {model}')
print(f'  chat.url      = {url}')
print(f'  chat.api_key  = {display}')
" "${LLM_CONFIG}" 2>&1; then
        echo "  [ERROR] Failed to update ${LLM_CONFIG}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    echo "  [OK] Updated: ${LLM_CONFIG}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=========================================="
echo " LLM configuration complete"
echo "=========================================="
echo "  Updated: ${SUCCESS_COUNT} file(s)"
if [ "${FAIL_COUNT}" -gt 0 ]; then
    echo "  Failed:  ${FAIL_COUNT} file(s)"
fi
echo "  Model:   ${LLM_MODEL}"
echo "  URL:     ${LLM_URL}"
echo "  API Key: ${KEY_MASK}"
echo "=========================================="

if [ "${SUCCESS_COUNT}" -eq 0 ]; then
    echo ""
    echo "[ERROR] No files were updated. Please check the warnings above."
    exit 1
fi
