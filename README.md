# claude-code-setup

一条命令在新机器上复现本机的 Claude Code 插件环境：

- [claude-mem](https://github.com/thedotmack/claude-mem)（持久记忆，走 OpenCode Go）
- [context-mode](https://github.com/mksglu/context-mode)（上下文压缩 / 沙箱执行）
- [mattpocock-skills](https://github.com/mattpocock/skills)（TDD、code-review、PR 等工程技能）

脚本只做“安装 + 合并配置”，不包含、也不会下载任何个人记忆数据。

## 一键安装

```bash
export OPENCODE_API_KEY=oc_sk_xxxxxxxx
curl -fsSL https://raw.githubusercontent.com/yangwuan55/claude-code-setup/main/install.sh | bash
```

没有 key 也可以先安装，脚本会跳过 key 配置并继续装插件：

```bash
curl -fsSL https://raw.githubusercontent.com/yangwuan55/claude-code-setup/main/install.sh | bash
# 之后补上 key 再跑一次即可
export OPENCODE_API_KEY=oc_sk_xxxxxxxx
curl -fsSL https://raw.githubusercontent.com/yangwuan55/claude-code-setup/main/install.sh | bash
```

在终端里直接运行且未设置环境变量时，脚本会提示输入 key；在 CI / 非交互环境（没有 TTY）下则优雅跳过。

## 前置条件

| 依赖 | 是否必需 | 说明 |
| --- | --- | --- |
| Linux / macOS + bash | 必需 | Linux 与 macOS 自带的 bash 即可 |
| Node.js 18+ | 必需 | 用于 JSON 合并，也是 context-mode / claude-mem 的 MCP server 运行时 |
| git | 必需 | `claude plugin marketplace add` 通过 git 克隆 marketplace |
| curl | 必需 | 一键安装与 claude 官方安装器 |
| Claude Code (`claude`) | 可选 | 未安装时脚本用官方安装器自动安装；失败则回退 `npm install -g @anthropic-ai/claude-code` |
| bun | 可选 | 缺少时只警告，不影响安装 |

## 安装内容

### 插件（user scope，默认启用）

| 插件 | Marketplace | 说明 |
| --- | --- | --- |
| `context-mode@context-mode` | `mksglu/context-mode` | 提供 `context-mode` MCP server |
| `claude-mem@thedotmack` | `thedotmack/claude-mem` | 提供 `mcp-search` MCP server；marketplace 开启 `autoUpdate` |
| `mattpocock-skills@mattpocock` | `mattpocock/skills` | 27 个工程技能（`tdd`、`code-review`、`pr` 等） |

### `~/.claude/settings.json`

脚本把下列键**合并**进 `env`（其他键、`permissions`、`enabledPlugins` 等原样保留）：

```json
{
  "ANTHROPIC_BASE_URL": "https://opencode.ai/zen/go",
  "ANTHROPIC_API_KEY": "<你的 OpenCode Go key>",
  "ANTHROPIC_MODEL": "deepseek-v4.1-flash",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4.1-flash",
  "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4.1-flash",
  "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4.1-flash",
  "CLAUDE_CODE_AUTO_MODE_SERVER": "0",
  "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4.1-flash",
  "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "500000"
}
```

完整模板见 [`templates/claude-settings.json.template`](templates/claude-settings.json.template)。
模板是供阅读/手动配置的参考副本；`install.sh` 是自包含的，`curl | bash` 时不依赖仓库里的其他文件。

### `~/.claude-mem/settings.json`

```json
{
  "CLAUDE_MEM_RUNTIME": "worker",
  "CLAUDE_MEM_PROVIDER": "openai-compatible",
  "CLAUDE_MEM_OPENAI_COMPAT_PRESET": "opencode-go",
  "CLAUDE_MEM_OPENAI_COMPAT_MODEL": "deepseek-v4.1-flash"
}
```

模板见 [`templates/claude-mem-settings.json.template`](templates/claude-mem-settings.json.template)。

### API key 是怎么传给 claude-mem 的

claude-mem 源码的读取顺序是：

1. `~/.claude-mem/settings.json` 里的 `CLAUDE_MEM_OPENAI_COMPAT_API_KEY`
2. 回退到 `~/.claude-mem/.env` 里的 `OPENAI_COMPAT_API_KEY`（本机采用的方式）

本脚本沿用第 2 种方式，把 key 写入 `~/.claude-mem/.env`，并把文件权限设为 `600`。模板见
[`templates/claude-mem.env.template`](templates/claude-mem.env.template)。

> `opencode-go` preset 的 base URL 由 claude-mem 内置为 `https://opencode.ai/zen/go/v1`，
> 因此 `~/.claude/settings.json` 里的 `ANTHROPIC_BASE_URL` 写的是不带 `/v1` 的
> `https://opencode.ai/zen/go`。

## 幂等与合并

- 重复运行不会重复安装插件；已存在的 marketplace / 插件会跳过。
- `settings.json`、`known_marketplaces.json` 采用深度合并：只覆盖脚本负责的键，其余内容保持不变。
- 合并后内容没有变化时不写文件，第二次运行是真正的 no-op。
- `~/.claude-mem/.env` 只替换 `OPENAI_COMPAT_API_KEY` 一行，其他行（例如其他 provider 的凭据）保留。
- 不会修改真实环境之外的文件；`HOME` 指向哪里就写到哪里，便于用临时 HOME 验收。

## 安全说明

- 公开仓库中**不含**任何真实 key / token、设备 ID、记忆数据库（`claude-mem.db`）、
  `chroma/`、`logs/` 或私有仓库内容。
- `install.sh` 不会上传或回传任何数据。
- 脚本只会写：
  - `~/.claude/settings.json`
  - `~/.claude/plugins/`（由 `claude plugin` 命令管理）
  - `~/.claude-mem/settings.json`
  - `~/.claude-mem/.env`
- 含 key 的两个文件权限为 `600`；安装输出不会打印 key。
- 如果已有 `settings.json` 不是合法 JSON，脚本会报错退出而不是覆盖它。

## 验收

```bash
bash tests/acceptance.sh
```

测试会在临时 `HOME`（`mktemp -d`）中真实执行 `install.sh`，不会触碰真实的
`~/.claude` / `~/.claude-mem`。覆盖：

1. 干净 HOME + 假 key：三个插件已安装并启用、MCP server 已注册、mattpocock 技能可列出；
   `~/.claude/settings.json`、`~/.claude-mem/settings.json`、`.env` 键值与权限正确。
2. 第二次运行：所有配置文件哈希不变（no-op）。
3. 缺少 key 且无 TTY：退出码 0，不写入 key，其余照常安装。
4. 预置无关配置：合并后原有键保留，脚本管理的键被更新。
5. 安装日志中不出现 key。

测试需要网络（克隆三个 marketplace），耗时约 3–5 分钟。

## 仓库结构

```text
install.sh                                # 一键安装脚本（自包含）
templates/claude-settings.json.template   # ~/.claude/settings.json 模板
templates/claude-mem-settings.json.template
templates/claude-mem.env.template
tests/acceptance.sh                       # 验收测试
README.md
```
