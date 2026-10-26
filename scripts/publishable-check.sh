#!/usr/bin/env bash
# publishable-check.sh — readiness gate for voice-say public repo
#
# Run from the repo root:   bash scripts/publishable-check.sh
#
# Exits 0 only when every check passes.  Each check prints a header line
# and either "  OK" or a failure message followed by exit 1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# From scripts/ the repo is the parent. As a pre-commit hook in .git/hooks the
# parent is .git, not a work tree; git runs hooks from the top of the work tree.
if [[ "$(git -C "${SCRIPT_DIR}/.." rev-parse --is-inside-git-dir 2>/dev/null)" == "true" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
else
    REPO_ROOT="$(git -C "${SCRIPT_DIR}/.." rev-parse --show-toplevel 2>/dev/null || true)"
fi
# The scans list files with git: outside a checkout (a ZIP download) they would
# scan nothing and pass.
if [[ -z "${REPO_ROOT}" || ! -f "${REPO_ROOT}/scripts/publishable-check.sh" ]]; then
    echo "publishable-check: needs a git checkout of voice-say (git clone, not a ZIP download)." >&2
    exit 1
fi

# Relative path of this script (used to exclude it from the banned-term scan)
THIS_SCRIPT="scripts/publishable-check.sh"

cd "${REPO_ROOT}"

# A read loop, not mapfile: macOS ships bash 3.2.
ALL_FILES=()
while IFS= read -r f; do ALL_FILES+=( "$f" ); done \
  < <({ git ls-files; git ls-files --others --exclude-standard; } | sort -u)
if (( ${#ALL_FILES[@]} == 0 )); then
    echo "publishable-check: git lists no files in ${REPO_ROOT}; nothing to scan." >&2
    exit 1
fi

PASS=0
FAIL=0

fail() {
    echo "  FAIL: $*" >&2
    FAIL=$(( FAIL + 1 ))
}

ok() {
    echo "  OK"
}

echo ""
echo "==> [1/5] Scanning for secret patterns …"
echo "    (Excluded from scan: ${THIS_SCRIPT})"

SECRET_PATTERN='AKIA[0-9A-Z]{16}|-----BEGIN .* PRIVATE KEY-----|[Bb]earer [A-Za-z0-9\-_\.]{20,}|(api_key|secret|token)\s*[:=]\s*["'"'"'][A-Za-z0-9+/\-_]{16,}["'"'"']'

secret_hits=()
for f in "${ALL_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # Skip this script itself — it defines SECRET_PATTERN, which self-matches under GNU grep
    [[ "$f" == "${THIS_SCRIPT}" ]] && continue
    while IFS= read -r hit; do
        secret_hits+=( "  $f: $hit" )
    done < <(grep -nE "${SECRET_PATTERN}" "$f" 2>/dev/null || true)
done

if (( ${#secret_hits[@]} > 0 )); then
    fail "Secret pattern(s) detected:"
    for h in "${secret_hits[@]}"; do echo "$h" >&2; done
    echo "" >&2
else
    ok
fi

echo ""
echo "==> [2/5] Scanning for banned terms …"
echo "    (Excluded from scan: ${THIS_SCRIPT}, docs/adr/, docs/plans/ — history)"

# Proper-noun banned terms — word boundaries to avoid substrings (e.g. "DEALINGS IN" ≠ "Lin")
# The real terms (names, employers, personas) live outside the repo so this file can't disclose them:
# ${PUBLISHABLE_TERMS_FILE:-~/.config/voice-say/publishable-terms.sh} sets the three patterns below.
TERMS_FILE="${PUBLISHABLE_TERMS_FILE:-$HOME/.config/voice-say/publishable-terms.sh}"
BANNED_WORDS_PATTERN='\b(YourName|YourEmployer|YourClient)\b'
BANNED_PATH_PATTERN='/Users/|/home/'
# Persona / agent names can hide LOWERCASE inside identifiers (e.g. somename_persona),
# so they are matched case-INsensitively, bounded by any non-letter.
HIDDEN_NAME_PATTERN='(^|[^a-zA-Z])(yourpersona|yourhandle)([^a-zA-Z]|$)'
if [[ -f "$TERMS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$TERMS_FILE"
else
    echo "    WARNING: no private term list at $TERMS_FILE; scanning placeholders only"
fi

banned_hits=()
for f in "${ALL_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # Skip this script itself
    [[ "$f" == "${THIS_SCRIPT}" ]] && continue
    # ADRs and plans are history, kept verbatim
    [[ "$f" == docs/adr/* || "$f" == docs/plans/* ]] && continue
    # Word-bounded proper nouns (case-insensitive for the compound terms)
    while IFS= read -r hit; do
        banned_hits+=( "  ${f}: ${hit}" )
    done < <(grep -nE "${BANNED_WORDS_PATTERN}" "$f" 2>/dev/null || true)
    # Absolute path patterns
    while IFS= read -r hit; do
        banned_hits+=( "  ${f}: ${hit}" )
    done < <(grep -nE "${BANNED_PATH_PATTERN}" "$f" 2>/dev/null || true)
    # Persona/agent names hiding lowercase inside identifiers (case-insensitive)
    while IFS= read -r hit; do
        banned_hits+=( "  ${f}: ${hit}" )
    done < <(grep -niE "${HIDDEN_NAME_PATTERN}" "$f" 2>/dev/null || true)
done

if (( ${#banned_hits[@]} > 0 )); then
    fail "Banned term(s) detected:"
    for h in "${banned_hits[@]}"; do echo "$h" >&2; done
    echo "" >&2
else
    ok
fi

echo ""
echo "==> [3/5] Checking daemon/config.example.toml defaults …"

CONFIG="daemon/config.example.toml"
if [[ ! -f "${CONFIG}" ]]; then
    echo "  WARNING: ${CONFIG} does not exist yet — skipping config check."
else
    config_ok=1

    # For each key: extract the value portion, strip inline comments, then strip quotes/whitespace.
    _toml_val() { grep -E "^\s*$1\s*=" "${CONFIG}" | head -1 | sed 's/[^=]*=\s*//' | sed 's/\s*#.*//' | tr -d '"'"'"' \t'; }
    backend_val=$(_toml_val default_backend || true)
    voice_val=$(_toml_val   default_voice   || true)
    vault_val=$(_toml_val   vault_root      || true)
    tags_val=$(_toml_val    allowed_tags    || true)

    if [[ "${backend_val}" != "kokoro" ]]; then
        fail "config.example.toml: default_backend must be 'kokoro', got '${backend_val}'"
        config_ok=0
    fi
    if [[ "${voice_val}" != "default" ]]; then
        fail "config.example.toml: default_voice must be 'default', got '${voice_val}'"
        config_ok=0
    fi
    if [[ -n "${vault_val}" ]]; then
        fail "config.example.toml: vault_root must be empty, got '${vault_val}'"
        config_ok=0
    fi
    if [[ "${tags_val}" != "[]" ]]; then
        fail "config.example.toml: allowed_tags must be [], got '${tags_val}'"
        config_ok=0
    fi

    if (( config_ok )); then ok; fi
fi

echo ""
echo "==> [4/5] Running daemon test suite …"

(
    cd daemon
    if [[ -x .venv/bin/python ]]; then
        PYTEST_CMD=".venv/bin/python -m pytest"
    elif command -v python3 &>/dev/null && python3 -c "import pytest" 2>/dev/null; then
        PYTEST_CMD="python3 -m pytest"
    elif command -v pytest &>/dev/null; then
        PYTEST_CMD="pytest"
    else
        echo "  pytest not found: run make setup first." >&2
        exit 2
    fi
    ${PYTEST_CMD} -q 2>&1
) && PYTEST_EXIT=0 || PYTEST_EXIT=$?   # under set -e a bare failing subshell would exit here

if (( PYTEST_EXIT == 0 )); then
    ok
else
    fail "pytest exited ${PYTEST_EXIT} — test failures detected."
fi

echo ""
echo "==> [5/5] Checking required files (LICENSE, README.md) …"

missing=()
[[ -f "LICENSE"   ]] || missing+=( "LICENSE" )
[[ -f "README.md" ]] || missing+=( "README.md" )

if (( ${#missing[@]} > 0 )); then
    fail "Missing required file(s): ${missing[*]}"
else
    ok
fi

echo ""
if (( FAIL > 0 )); then
    echo "PUBLISHABLE-CHECK: FAIL  (${FAIL} check(s) failed)" >&2
    exit 1
else
    echo "PUBLISHABLE-CHECK: PASS"
    exit 0
fi
