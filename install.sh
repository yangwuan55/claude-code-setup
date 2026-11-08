#!/usr/bin/env bash
# claude-code-setup — 一键复现 Claude Code 插件环境
#
# 用法：
#   export OPENCODE_API_KEY=oc_sk_xxx
#   curl -fsSL https://raw.githubusercontent.com/yangwuan55/claude-code-setup/main/install.sh | bash
#
# 设计原则：
#   * 幂等：重复运行不会重复安装或改写相同内容。
#   * 合并：已有 settings.json / .env 中的其他键保持不变。
#   * 不写入任何个人记忆数据（数据库、chroma、日志、设备 ID 等）。
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MEM_DIR="${CLAUDE_MEM_DATA_DIR:-$HOME/.claude-mem}"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
MEM_SETTINGS="$MEM_DIR/settings.json"
MEM_ENV="$MEM_DIR/.env"
KNOWN_MARKETPLACES="$CLAUDE_DIR/plugins/known_marketplaces.json"

MARKETPLACE_SPECS=(
  "mksglu/context-mode|context-mode"
  "thedotmack/claude-mem|thedotmack"
  "mattpocock/skills|mattpocock"
)
PLUGINS=(
  "context-mode@context-mode"
  "claude-mem@thedotmack"
  "mattpocock-skills@mattpocock"
)

info() { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf '  [警告] %s\n' "$*" >&2; }
die()  { printf '\n[错误] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
ensure_node() {
  if ! command -v node >/dev/null 2>&1; then
    die "未找到 node。请先安装 Node.js 18+：https://nodejs.org/ 或使用 nvm。"
  fi
  info "node $(node --version)"
}

check_bun() {
  if command -v bun >/dev/null 2>&1; then
    info "bun $(bun --version)"
  else
    warn "未找到 bun（可选）。如需完整运行时体验：curl -fsSL https://bun.sh/install | bash"
  fi
}

check_git() {
  if ! command -v git >/dev/null 2>&1; then
    die "未找到 git。安装 marketplace 需要 git：https://git-scm.com/downloads"
  fi
}

ensure_claude() {
  if command -v claude >/dev/null 2>&1; then
    info "claude $(claude --version 2>/dev/null | head -n 1 || true)"
    return
  fi

  step "未找到 claude，使用官方方式安装"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://claude.ai/install.sh | bash || true
  else
    warn "未找到 curl，无法运行官方安装脚本"
  fi
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true

  if ! command -v claude >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    warn "官方安装脚本未生效，尝试 npm 安装"
    npm install -g @anthropic-ai/claude-code || true
  fi

  command -v claude >/dev/null 2>&1 \
    || die "无法安装 claude。请手动安装后重试：https://docs.claude.com/en/docs/claude-code/setup"
  info "claude 已安装"
}

# ---------------------------------------------------------------------------
# API key
# ---------------------------------------------------------------------------
read_api_key() {
  API_KEY="${OPENCODE_API_KEY:-}"
  if [ -n "$API_KEY" ]; then
    return
  fi

  # 有终端才提示（包括 curl | bash：此时 stdin 是脚本，stdout/stderr 仍是终端）。
  if { true </dev/tty; } 2>/dev/null && { [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; }; then
    printf '\n未检测到 OPENCODE_API_KEY。\n'
    printf '请输入 OpenCode Go API key（留空则跳过 key 配置）：' >/dev/tty
    IFS= read -r -s API_KEY </dev/tty || API_KEY=""
    printf '\n' >/dev/tty
  fi

  if [ -z "$API_KEY" ]; then
    warn "未提供 OPENCODE_API_KEY：跳过 API key 配置（其余环境仍会安装）"
  fi
}

validate_api_key() {
  case "$API_KEY" in
    *$'\n'*|*$'\r'*) die "OPENCODE_API_KEY 不能包含换行符" ;;
  esac
}

# ---------------------------------------------------------------------------
# JSON 合并：只覆盖给定键，保留其他内容；内容无变化时不写文件。
# merge_json <file> <patch-json> <mode>
# ---------------------------------------------------------------------------
merge_json() {
  local file="$1" patch="$2" mode="${3:-}"
  PATCH_JSON="$patch" node - "$file" "$mode" <<'NODE'
const fs = require('fs');
const path = require('path');

const file = process.argv[2];
const mode = process.argv[3] || null;
const patch = JSON.parse(process.env.PATCH_JSON);

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function deepMerge(base, extra) {
  const out = { ...base };
  for (const [key, value] of Object.entries(extra)) {
    out[key] = isObject(value) && isObject(out[key])
      ? deepMerge(out[key], value)
      : value;
  }
  return out;
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (isObject(value)) {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = canonical(value[key]);
    return out;
  }
  return value;
}

let existing = {};
if (fs.existsSync(file)) {
  const raw = fs.readFileSync(file, 'utf8').trim();
  if (raw) {
    try {
      existing = JSON.parse(raw);
    } catch {
      console.error(`[错误] ${file} 不是合法 JSON，未做修改。请修复后重试。`);
      process.exit(2);
    }
  }
}
if (!isObject(existing)) {
  console.error(`[错误] ${file} 的顶层必须是 JSON 对象，未做修改。`);
  process.exit(2);
}

const merged = deepMerge(existing, patch);
const changed = JSON.stringify(canonical(merged)) !== JSON.stringify(canonical(existing));

if (changed) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp.${process.pid}.${require('crypto').randomBytes(4).toString('hex')}`;
  fs.writeFileSync(tmp, JSON.stringify(merged, null, 2) + '\n', { mode: 0o600 });
  if (mode) fs.chmodSync(tmp, parseInt(mode, 8));
  fs.renameSync(tmp, file);
}
if (mode) fs.chmodSync(file, parseInt(mode, 8));
process.stdout.write(changed ? 'changed' : 'unchanged');
NODE
}

# ---------------------------------------------------------------------------
# ~/.claude-mem/.env 合并（保留其他行）
# ---------------------------------------------------------------------------
write_mem_env() {
  local key="$1" tmp rc=0
  mkdir -p "$MEM_DIR"
  tmp="$(mktemp "$MEM_ENV.tmp.XXXXXX")" || die "无法创建临时文件（$MEM_DIR）"
  if [ -f "$MEM_ENV" ]; then
    grep -v '^[[:space:]]*OPENAI_COMPAT_API_KEY=' "$MEM_ENV" >"$tmp" || rc=$?
    if [ "$rc" -gt 1 ]; then
      rm -f "$tmp"
      die "无法读取 $MEM_ENV（grep 退出码 $rc）"
    fi
  fi
  # 确保原有最后一行有换行符
  if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then
    printf '\n' >>"$tmp"
  fi
  printf 'OPENAI_COMPAT_API_KEY=%s\n' "$key" >>"$tmp"
  chmod 600 "$tmp"
  if [ -f "$MEM_ENV" ] && cmp -s "$tmp" "$MEM_ENV"; then
    rm -f "$tmp"
    chmod 600 "$MEM_ENV"
    printf 'unchanged'
  else
    mv "$tmp" "$MEM_ENV"
    printf 'changed'
  fi
}

# ---------------------------------------------------------------------------
# 插件安装
# ---------------------------------------------------------------------------
marketplace_exists() {
  local name="$1" json
  json="$(claude plugin marketplace list --json 2>/dev/null)" || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | node -e '
    const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
    process.exit(data.some((m) => m.name === process.argv[1]) ? 0 : 1);
  ' "$name" 2>/dev/null
}

plugin_state() {
  local id="$1" json
  json="$(claude plugin list --json 2>/dev/null)" || { printf 'missing'; return; }
  [ -n "$json" ] || { printf 'missing'; return; }
  printf '%s' "$json" | node -e '
    const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const plugin = data.find((p) => p.id === process.argv[1] && p.scope === "user");
    if (!plugin) console.log("missing");
    else console.log(plugin.enabled === true ? "enabled" : "disabled");
  ' "$id" 2>/dev/null || printf 'missing'
}

install_marketplaces() {
  step "配置插件 marketplace"
  local entry spec name output
  for entry in "${MARKETPLACE_SPECS[@]}"; do
    spec="${entry%%|*}"
    name="${entry##*|}"
    if marketplace_exists "$name"; then
      info "marketplace 已存在：$name"
      continue
    fi
    info "添加 marketplace：$spec"
    if ! output="$(claude plugin marketplace add "$spec" --json 2>&1)"; then
      printf '%s\n' "$output" >&2
      die "添加 marketplace 失败：$spec"
    fi
  done
}

install_plugins() {
  step "安装并启用插件"
  local id state output
  for id in "${PLUGINS[@]}"; do
    state="$(plugin_state "$id")"
    if [ "$state" = "missing" ]; then
      info "安装：$id"
      if ! output="$(claude plugin install "$id" --scope user -y --json 2>&1)"; then
        printf '%s\n' "$output" >&2
        die "安装插件失败：$id"
      fi
      state="$(plugin_state "$id")"
      if [ "$state" = "missing" ]; then
        die "安装后仍未检测到插件：$id"
      fi
    fi
    if [ "$state" = "disabled" ]; then
      info "启用：$id"
      if ! output="$(claude plugin enable "$id" --scope user --json 2>&1)"; then
        printf '%s\n' "$output" >&2
        die "启用插件失败：$id"
      fi
    elif [ "$state" = "enabled" ]; then
      info "已安装并启用：$id"
    fi
  done

  # 最终校验：三个插件都必须已启用。
  local json
  json="$(claude plugin list --json 2>/dev/null)" || die "无法读取插件列表"
  if ! printf '%s' "$json" | node -e '
    const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const want = {
      "context-mode@context-mode": "context-mode",
      "claude-mem@thedotmack": "mcp-search",
      "mattpocock-skills@mattpocock": null,
    };
    const byId = Object.fromEntries(data.filter((p) => p.scope === "user").map((p) => [p.id, p]));
    const problems = [];
    for (const [id, mcp] of Object.entries(want)) {
      const plugin = byId[id];
      if (!plugin || plugin.enabled !== true) problems.push(`${id} 未启用`);
      else if (mcp && !(plugin.mcpServers && plugin.mcpServers[mcp])) {
        problems.push(`${id} 缺少 MCP server ${mcp}`);
      }
    }
    if (problems.length) {
      console.error(problems.join("; "));
      process.exit(1);
    }
  '; then
    die "插件安装校验失败"
  fi
}

# ---------------------------------------------------------------------------
# 配置写入
# ---------------------------------------------------------------------------
configure_claude_settings() {
  step "写入 ~/.claude/settings.json（合并）"
  local patch
  patch="$(KEY="$API_KEY" node -e '
    const env = {
      ANTHROPIC_BASE_URL: "https://opencode.ai/zen/go",
    };
    if (process.env.KEY) env.ANTHROPIC_API_KEY = process.env.KEY;
    Object.assign(env, {
      ANTHROPIC_MODEL: "deepseek-v4.1-flash",
      ANTHROPIC_DEFAULT_HAIKU_MODEL: "deepseek-v4.1-flash",
      ANTHROPIC_DEFAULT_SONNET_MODEL: "deepseek-v4.1-flash",
      ANTHROPIC_DEFAULT_OPUS_MODEL: "deepseek-v4.1-flash",
      CLAUDE_CODE_AUTO_MODE_SERVER: "0",
      CLAUDE_CODE_SUBAGENT_MODEL: "deepseek-v4.1-flash",
      CLAUDE_CODE_MAX_CONTEXT_TOKENS: "500000",
    });
    process.stdout.write(JSON.stringify({ env }));
  ')"
  mkdir -p "$CLAUDE_DIR"
  local result
  result="$(merge_json "$CLAUDE_SETTINGS" "$patch" 600)" || die "写入 $CLAUDE_SETTINGS 失败"
  if [ "$result" = "changed" ]; then
    info "已更新 $CLAUDE_SETTINGS"
  else
    info "无变化：$CLAUDE_SETTINGS"
  fi
}

configure_mem_settings() {
  step "写入 ~/.claude-mem/settings.json（合并）"
  local patch='{"CLAUDE_MEM_RUNTIME":"worker","CLAUDE_MEM_PROVIDER":"openai-compatible","CLAUDE_MEM_OPENAI_COMPAT_PRESET":"opencode-go","CLAUDE_MEM_OPENAI_COMPAT_MODEL":"deepseek-v4.1-flash"}'
  mkdir -p "$MEM_DIR"
  local result
  result="$(merge_json "$MEM_SETTINGS" "$patch" 600)" || die "写入 $MEM_SETTINGS 失败"
  if [ "$result" = "changed" ]; then
    info "已更新 $MEM_SETTINGS"
  else
    info "无变化：$MEM_SETTINGS"
  fi
}

configure_mem_key() {
  [ -n "$API_KEY" ] || return 0
  step "写入 claude-mem API key（~/.claude-mem/.env，权限 600）"
  if [ "$(write_mem_env "$API_KEY")" = "changed" ]; then
    info "已更新 $MEM_ENV"
  else
    info "无变化：$MEM_ENV"
  fi
}

configure_autoupdate() {
  if [ ! -f "$KNOWN_MARKETPLACES" ]; then
    warn "未找到 $KNOWN_MARKETPLACES，跳过 autoUpdate 配置"
    return 0
  fi
  step "启用 claude-mem marketplace 自动更新"
  local patch='{"thedotmack":{"autoUpdate":true}}' result
  result="$(merge_json "$KNOWN_MARKETPLACES" "$patch")" || die "写入 $KNOWN_MARKETPLACES 失败"
  if [ "$result" = "changed" ]; then
    info "已启用 thedotmack.autoUpdate"
  else
    info "已启用（无变化）"
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  printf 'claude-code-setup\n'
  printf '目标 HOME: %s\n' "$HOME"

  step "检查前置依赖"
  ensure_node
  check_git
  check_bun
  ensure_claude

  read_api_key
  validate_api_key

  install_marketplaces
  install_plugins

  configure_claude_settings
  configure_mem_settings
  configure_mem_key
  configure_autoupdate

  step "完成"
  info "插件：context-mode / claude-mem / mattpocock-skills 均已安装并启用"
  info "配置：$CLAUDE_SETTINGS"
  info "记忆服务：$MEM_SETTINGS"
  if [ -n "$API_KEY" ]; then
    info "API key：已写入 ~/.claude/settings.json 与 ~/.claude-mem/.env（600）"
  else
    info "API key：未配置（可 export OPENCODE_API_KEY=... 后重跑）"
  fi
  info "重启 Claude Code 后生效。"
}

main "$@"
