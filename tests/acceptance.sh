#!/usr/bin/env bash
# Acceptance tests for install.sh.
#
# Each test runs install.sh against a throwaway HOME so the real
# ~/.claude and ~/.claude-mem are never touched.
#
# Usage:
#   bash tests/acceptance.sh
#   KEEP_ON_FAIL=1 bash tests/acceptance.sh   # keep temp HOMEs on failure
set -uo pipefail

# Keep the suite isolated even if the caller has these overrides set.
unset CLAUDE_CONFIG_DIR CLAUDE_MEM_DATA_DIR

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_DIR/install.sh"
FAKE_KEY="fake-test-key-not-a-real-secret"
KEEP_ON_FAIL="${KEEP_ON_FAIL:-0}"

PASS=0
FAIL=0
FAILED_NAMES=()
TMP_DIRS=()

new_home() {
  local h
  h="$(mktemp -d)"
  TMP_DIRS+=("$h")
  printf '%s' "$h"
}

cleanup() {
  if [ "$FAIL" -gt 0 ] && [ "$KEEP_ON_FAIL" = "1" ]; then
    printf '\nKept temp HOMEs for debugging:\n'
    printf '  %s\n' "${TMP_DIRS[@]}"
    return
  fi
  local d
  for d in "${TMP_DIRS[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"
}

# run_install <home> <key-or-empty> <log>
# stdin is /dev/null: non-interactive. The key is only passed when non-empty.
run_install() {
  local home="$1" key="$2" log="$3"
  if [ -n "$key" ]; then
    HOME="$home" OPENCODE_API_KEY="$key" bash "$INSTALL" </dev/null >"$log" 2>&1
  else
    HOME="$home" env -u OPENCODE_API_KEY bash "$INSTALL" </dev/null >"$log" 2>&1
  fi
}

json_get() {
  # json_get <file> <dotted.path>
  node - "$1" "$2" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const dotted = process.argv[3];
let data;
try { data = JSON.parse(fs.readFileSync(file, 'utf8')); }
catch { process.exit(2); }
const value = dotted.split('.').reduce((o, k) => (o == null ? undefined : o[k]), data);
if (value === undefined) process.exit(3);
process.stdout.write(typeof value === 'object' ? JSON.stringify(value) : String(value));
NODE
}

assert_json_eq() {
  # assert_json_eq <name> <file> <dotted.path> <expected>
  local name="$1" file="$2" path="$3" expected="$4" actual
  if [ ! -f "$file" ]; then
    fail "$name" "missing file: $file"
    return
  fi
  actual="$(json_get "$file" "$path" 2>/dev/null)"
  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expected $path='$expected', got '${actual:-<missing>}'"
  fi
}

assert_json_present() {
  # assert_json_present <name> <file> <dotted.path>
  local name="$1" file="$2" path="$3"
  if json_get "$file" "$path" >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name" "missing $path in $file"
  fi
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# check_plugins <home> <log>
# Verifies the three plugins are installed and enabled, and that the two MCP
# servers are registered.
check_plugins() {
  local home="$1" out
  out="$(HOME="$home" claude plugin list --json 2>/dev/null)"
  if [ -z "$out" ]; then
    fail "plugins installed and enabled" "claude plugin list --json returned nothing"
    return
  fi
  if node - "$out" <<'NODE'
const data = JSON.parse(process.argv[2]);
const byId = Object.fromEntries(data.map((p) => [p.id, p]));
const want = {
  'context-mode@context-mode': 'context-mode',
  'claude-mem@thedotmack': 'mcp-search',
  'mattpocock-skills@mattpocock': null,
};
const problems = [];
for (const [id, mcp] of Object.entries(want)) {
  const p = byId[id];
  if (!p) problems.push(`missing ${id}`);
  else if (p.scope !== 'user') problems.push(`${id} is not user scope`);
  else if (p.enabled !== true) problems.push(`${id} is not enabled`);
  else if (mcp && !(p.mcpServers && p.mcpServers[mcp])) {
    problems.push(`${id} missing MCP server '${mcp}'`);
  }
}
if (problems.length) {
  console.error(problems.join('; '));
  process.exit(1);
}
NODE
  then
    pass "plugins installed and enabled"
  else
    fail "plugins installed and enabled" "plugin list check failed"
  fi
}

# check_skills <home>
check_skills() {
  local home="$1" out
  out="$(HOME="$home" claude plugin details mattpocock-skills@mattpocock 2>/dev/null)"
  if printf '%s' "$out" | grep -q 'Skills' \
    && printf '%s' "$out" | grep -qw 'tdd' \
    && printf '%s' "$out" | grep -qw 'code-review'; then
    pass "mattpocock skills available (tdd, code-review)"
  else
    fail "mattpocock skills available (tdd, code-review)" "skills missing from plugin details"
  fi
}

# check_env_settings <home> <expected-key>
check_env_settings() {
  local home="$1" key="$2" settings="$1/.claude/settings.json"
  assert_json_eq "settings: ANTHROPIC_BASE_URL" "$settings" env.ANTHROPIC_BASE_URL "https://opencode.ai/zen/go"
  assert_json_eq "settings: ANTHROPIC_API_KEY" "$settings" env.ANTHROPIC_API_KEY "$key"
  assert_json_eq "settings: ANTHROPIC_MODEL" "$settings" env.ANTHROPIC_MODEL "deepseek-v4.1-flash"
  assert_json_eq "settings: ANTHROPIC_DEFAULT_HAIKU_MODEL" "$settings" env.ANTHROPIC_DEFAULT_HAIKU_MODEL "deepseek-v4.1-flash"
  assert_json_eq "settings: ANTHROPIC_DEFAULT_SONNET_MODEL" "$settings" env.ANTHROPIC_DEFAULT_SONNET_MODEL "deepseek-v4.1-flash"
  assert_json_eq "settings: ANTHROPIC_DEFAULT_OPUS_MODEL" "$settings" env.ANTHROPIC_DEFAULT_OPUS_MODEL "deepseek-v4.1-flash"
  assert_json_eq "settings: CLAUDE_CODE_SUBAGENT_MODEL" "$settings" env.CLAUDE_CODE_SUBAGENT_MODEL "deepseek-v4.1-flash"
  assert_json_eq "settings: CLAUDE_CODE_AUTO_MODE_SERVER" "$settings" env.CLAUDE_CODE_AUTO_MODE_SERVER "0"
  assert_json_eq "settings: CLAUDE_CODE_MAX_CONTEXT_TOKENS" "$settings" env.CLAUDE_CODE_MAX_CONTEXT_TOKENS "500000"
}

check_mem_settings() {
  local home="$1" settings="$1/.claude-mem/settings.json"
  assert_json_eq "claude-mem: provider" "$settings" CLAUDE_MEM_PROVIDER "openai-compatible"
  assert_json_eq "claude-mem: preset" "$settings" CLAUDE_MEM_OPENAI_COMPAT_PRESET "opencode-go"
  assert_json_eq "claude-mem: model" "$settings" CLAUDE_MEM_OPENAI_COMPAT_MODEL "deepseek-v4.1-flash"
  assert_json_eq "claude-mem: runtime" "$settings" CLAUDE_MEM_RUNTIME "worker"
}

check_env_file() {
  local home="$1" key="$2" envfile="$1/.claude-mem/.env"
  if [ ! -f "$envfile" ]; then
    fail "claude-mem .env contains key" "missing $envfile"
    return
  fi
  if grep -qx "OPENAI_COMPAT_API_KEY=$key" "$envfile"; then
    pass "claude-mem .env contains key"
  else
    fail "claude-mem .env contains key" "OPENAI_COMPAT_API_KEY not set to the supplied key"
  fi
  local mode
  mode="$(file_mode "$envfile")"
  if [ "$mode" = "600" ]; then
    pass "claude-mem .env mode is 600"
  else
    fail "claude-mem .env mode is 600" "got mode $mode"
  fi
}

# ---------------------------------------------------------------------------
# Test 1: fresh install (also feeds tests 2 and 5)
# ---------------------------------------------------------------------------
printf '\n== fresh install ==\n'
HOME1="$(new_home)"
LOG1="$HOME1/install.log"
if run_install "$HOME1" "$FAKE_KEY" "$LOG1"; then
  pass "install.sh exits 0"
else
  fail "install.sh exits 0" "see $LOG1"
fi

check_plugins "$HOME1"
check_skills "$HOME1"
check_env_settings "$HOME1" "$FAKE_KEY"
check_mem_settings "$HOME1"
check_env_file "$HOME1" "$FAKE_KEY"
assert_json_eq "marketplace: thedotmack autoUpdate" "$HOME1/.claude/plugins/known_marketplaces.json" thedotmack.autoUpdate "true"

if grep -q "$FAKE_KEY" "$LOG1"; then
  fail "key is not printed to the log" "the API key appeared in install output"
else
  pass "key is not printed to the log"
fi

# ---------------------------------------------------------------------------
# Test 2: second run is a no-op
# ---------------------------------------------------------------------------
printf '\n== idempotent second run ==\n'
snapshot() {
  local f
  for f in \
    "$HOME1/.claude/settings.json" \
    "$HOME1/.claude-mem/settings.json" \
    "$HOME1/.claude-mem/.env" \
    "$HOME1/.claude/plugins/known_marketplaces.json" \
    "$HOME1/.claude/plugins/installed_plugins.json"; do
    if [ -f "$f" ]; then
      printf '%s  %s\n' "$(hash_file "$f")" "${f#"$HOME1"/}"
    fi
  done
}
BEFORE="$(snapshot)"
LOG2="$HOME1/install-second.log"
if run_install "$HOME1" "$FAKE_KEY" "$LOG2"; then
  pass "second run exits 0"
else
  fail "second run exits 0" "see $LOG2"
fi
AFTER="$(snapshot)"
if [ "$BEFORE" = "$AFTER" ]; then
  pass "second run leaves all config files unchanged"
else
  fail "second run leaves all config files unchanged" "config files changed:
$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") || true)"
fi
check_plugins "$HOME1"

# ---------------------------------------------------------------------------
# Test 3: missing key without a TTY is a graceful skip
# ---------------------------------------------------------------------------
printf '\n== missing key (non-interactive) ==\n'
HOME2="$(new_home)"
LOG3="$HOME2/install.log"
if run_install "$HOME2" "" "$LOG3"; then
  pass "missing-key install exits 0"
else
  fail "missing-key install exits 0" "see $LOG3"
fi
check_plugins "$HOME2"
if json_get "$HOME2/.claude/settings.json" env.ANTHROPIC_API_KEY >/dev/null 2>&1; then
  fail "missing key is not written to settings" "env.ANTHROPIC_API_KEY was set"
else
  pass "missing key is not written to settings"
fi
if [ -f "$HOME2/.claude-mem/.env" ] && grep -q '^OPENAI_COMPAT_API_KEY=' "$HOME2/.claude-mem/.env"; then
  fail "missing key is not written to claude-mem .env" "OPENAI_COMPAT_API_KEY was set"
else
  pass "missing key is not written to claude-mem .env"
fi

# ---------------------------------------------------------------------------
# Test 4: existing settings are merged, not overwritten
# ---------------------------------------------------------------------------
printf '\n== merge preserves existing settings ==\n'
HOME3="$(new_home)"
mkdir -p "$HOME3/.claude" "$HOME3/.claude-mem"
cat >"$HOME3/.claude/settings.json" <<'JSON'
{
  "env": {
    "CUSTOM_KEEP": "yes",
    "ANTHROPIC_MODEL": "old-model"
  },
  "permissions": { "defaultMode": "default" },
  "enabledPlugins": { "other@somewhere": true }
}
JSON
cat >"$HOME3/.claude-mem/settings.json" <<'JSON'
{
  "CUSTOM_MEM_KEEP": "yes",
  "CLAUDE_MEM_PROVIDER": "old-provider"
}
JSON
LOG4="$HOME3/install.log"
if run_install "$HOME3" "$FAKE_KEY" "$LOG4"; then
  pass "merge install exits 0"
else
  fail "merge install exits 0" "see $LOG4"
fi
assert_json_eq "merge: unrelated env key preserved" "$HOME3/.claude/settings.json" env.CUSTOM_KEEP "yes"
assert_json_eq "merge: target env key updated" "$HOME3/.claude/settings.json" env.ANTHROPIC_MODEL "deepseek-v4.1-flash"
assert_json_eq "merge: unrelated top-level key preserved" "$HOME3/.claude/settings.json" permissions.defaultMode "default"
assert_json_eq "merge: unrelated plugin preserved" "$HOME3/.claude/settings.json" enabledPlugins.other@somewhere "true"
assert_json_eq "merge: unrelated claude-mem key preserved" "$HOME3/.claude-mem/settings.json" CUSTOM_MEM_KEEP "yes"
assert_json_eq "merge: claude-mem provider updated" "$HOME3/.claude-mem/settings.json" CLAUDE_MEM_PROVIDER "openai-compatible"
check_plugins "$HOME3"

# ---------------------------------------------------------------------------
# Test 5: malformed settings JSON is reported, never overwritten
# ---------------------------------------------------------------------------
printf '\n== malformed settings JSON ==\n'
HOME4="$(new_home)"
mkdir -p "$HOME4/.claude"
printf '{ this is not valid json\n' >"$HOME4/.claude/settings.json"
BEFORE_INVALID="$(cat "$HOME4/.claude/settings.json")"
LOG5="$HOME4/install.log"
if run_install "$HOME4" "$FAKE_KEY" "$LOG5"; then
  fail "malformed settings JSON exits non-zero" "install.sh exited 0"
else
  pass "malformed settings JSON exits non-zero"
fi
if [ "$(cat "$HOME4/.claude/settings.json")" = "$BEFORE_INVALID" ]; then
  pass "malformed settings JSON is left untouched"
else
  fail "malformed settings JSON is left untouched" "file was modified"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
