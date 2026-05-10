# Claude Code + OMC 完整配置指南（Termux/Android）

> 环境要求：Termux（或 ZeroTermux）| Android | aarch64 | 已安装 glibc 包

---

## 一、环境概述

### 系统架构

```
Android (Kernel 6.6.89, SM8750)
└── Termux (bionic libc)
    ├── Node.js (bionic)
    ├── glibc 2.42 (termux-pacman/glibc-packages)
    │   ├── ld-linux-aarch64.so.1
    │   ├── libc.so.6
    │   └── patchelf, strace 等工具
    ├── glibc-runner (启动器)
    └── Claude Code v2.1.138 (glibc 原生二进制, 230MB)
```

### 版本说明

| 组件 | 版本 | 说明 |
|------|------|------|
| Claude Code | v2.1.138 | 原生 glibc 二进制（非 JS 版本） |
| oh-my-claudecode (OMC) | v4.13.7 | 多 Agent 编排层 |
| glibc | 2.42 | termux-pacman 构建 |
| Node.js | 当前 Termux 版本 | OMC hooks 运行所需 |

### 关键发现

- Claude Code v2.1.112 是最后一个 JS 版本（直接在 Termux 运行）
- v2.1.113+ 改为原生 glibc 二进制，不能直接运行
- 通过 `glibc-runner` 可以在 Termux 上运行 v2.1.138
- **不要使用 `patchelf` 修改二进制**（会导致 TLS 布局崩溃）
- 必须通过 `ld.so` 间接加载（glibc-runner 的方式）

---

## 二、Termux glibc 安装

### 安装 glibc 生态

```bash
# 添加 glibc 源
pkg install glibc-repo

# 安装核心 glibc
pkg install glibc

# 安装必要工具
pkg install glibc-runner patchelf-glibc strace-glibc

# 安装基础运行库
pkg install bash-glibc coreutils-glibc ncurses-glibc
```

### 验证 glibc

```bash
ls /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1
# 应该存在
```

---

## 三、Claude Code 安装

### 3.1 安装主包

```bash
npm install -g @anthropic-ai/claude-code@latest
```

npm 会安装主包，但原生二进制不会被自动下载（npm 检测 libc 类型失败）。

### 3.2 手动安装原生二进制

```bash
# 下载平台包
mkdir -p /tmp/claude-install && cd /tmp/claude-install
npm pack @anthropic-ai/claude-code-linux-arm64@latest

# 解压（npm pack 可能因 libc 检测失败，可用以下替代方式）
# 如果 npm pack 失败：
#   curl -sL https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64/-/claude-code-linux-arm64-2.1.138.tgz -o claude.tgz
mkdir -p pkg && tar xzf *.tgz -C pkg

# 替换占位符为真实二进制
cp pkg/package/claude ~/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe

# 清理
rm -rf /tmp/claude-install
```

### 3.3 创建启动脚本

```bash
# 删除 npm 创建的符号链接
rm ~/.npm-global/bin/claude

# 创建 wrapper 脚本
cat > ~/.npm-global/bin/claude << 'WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
exec glibc-runner /data/data/com.termux/files/home/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe "$@"
WRAPPER

chmod +x ~/.npm-global/bin/claude
```

### 3.4 验证

```bash
claude --version
# 应输出: 2.1.138 (Claude Code)
```

### 3.5 重要注意事项

- **npm update 会覆盖 wrapper 脚本**：更新后需重新执行 3.3 步骤
- **不要用 `patchelf --configure`**：会导致 TLS 初始化崩溃
- **不要设置 `LD_PRELOAD`**：`libtermux-exec-ld-preload.so` 与 glibc 冲突

---

## 四、OMC（oh-my-claudecode）安装

### 4.1 安装

```bash
npm install -g oh-my-claude-sisyphus@latest
```

### 4.2 验证

```bash
# 检查版本
node -e "console.log(require('$HOME/.npm-global/lib/node_modules/oh-my-claude-sisyphus/package.json').version)"

# 检查 hooks
cat ~/.npm-global/lib/node_modules/oh-my-claude-sisyphus/hooks/hooks.json | head -20
```

---

## 五、Auto-Memory 系统（claude-mem → OMC 融合）

基于 [claude-mem](https://github.com/thedotmack/claude-mem) 的设计理念，原生实现到 OMC 中。

### 5.1 架构

```
PostToolUse → capture tool data → append to batch file
                                          ↓ (threshold reached: 5)
                                    compress via GLM API
                                          ↓
                                    insert into SQLite (.omc/state/memory.db)

SessionEnd   → flush batch → compress session summary → insert → prune (30天)
SessionStart → query recent observations → format → inject as additionalContext
PreCompact   → query key observations → return as additionalContext
MCP Server   → expose memory_search / memory_recent / memory_stats tools
```

### 5.2 新增文件清单

所有文件位于：`~/.npm-global/lib/node_modules/oh-my-claude-sisyphus/scripts/`

#### 核心模块 (scripts/lib/)

| 文件 | 功能 |
|------|------|
| `lib/memory-db.mjs` | SQLite 持久层（better-sqlite3, WAL, FTS5） |
| `lib/memory-capture.mjs` | 工具数据提取（过滤高信号工具，跳过噪声） |
| `lib/memory-batch.mjs` | 文件系统 batch 缓冲（JSON 文件） |
| `lib/memory-compress.mjs` | GLM API 压缩（调用 Anthropic 兼容接口） |

#### Hook 脚本

| 文件 | 触发事件 | 超时 | 功能 |
|------|----------|------|------|
| `memory-posttool.mjs` | PostToolUse | 3s | 捕获工具数据，累积 batch，达到阈值压缩 |
| `memory-session-start.mjs` | SessionStart | 30s | 读取最近 observations，注入上下文 |
| `memory-precompact.mjs` | PreCompact | 3s | 读取关键 observations，压缩恢复用 |
| `memory-session-end.mjs` | SessionEnd | 60s | 刷新 batch，生成会话总结，清理过期数据 |

#### MCP 服务器

| 文件 | 功能 |
|------|------|
| `memory-mcp-server.mjs` | 独立 MCP 服务器，暴露搜索/统计工具 |

### 5.3 SQLite 数据库

路径：`~/.omc/state/memory.db`

表结构：
- `observations` — 观察记录（session_id, project, type, title, narrative, facts, concepts...）
- `session_summaries` — 会话总结
- `observations_fts` — FTS5 全文搜索虚拟表
- `memory_errors` — 错误日志

### 5.4 Hooks 注册

在 `hooks/hooks.json` 的对应事件中添加：

```json
{
  "SessionStart": [{
    "matcher": "*",
    "hooks": [
      { "type": "command", "command": "node \"$CLAUDE_PLUGIN_ROOT\"/scripts/run.cjs \"$CLAUDE_PLUGIN_ROOT\"/scripts/memory-session-start.mjs", "timeout": 30 }
    ]
  }],
  "PostToolUse": [{
    "matcher": "*",
    "hooks": [
      { "type": "command", "command": "node \"$CLAUDE_PLUGIN_ROOT\"/scripts/run.cjs \"$CLAUDE_PLUGIN_ROOT\"/scripts/memory-posttool.mjs", "timeout": 3 }
    ]
  }],
  "PreCompact": [{
    "matcher": "*",
    "hooks": [
      { "type": "command", "command": "node \"$CLAUDE_PLUGIN_ROOT\"/scripts/run.cjs \"$CLAUDE_PLUGIN_ROOT\"/scripts/memory-precompact.mjs", "timeout": 3 }
    ]
  }],
  "SessionEnd": [{
    "matcher": "*",
    "hooks": [
      { "type": "command", "command": "node \"$CLAUDE_PLUGIN_ROOT\"/scripts/run.cjs \"$CLAUDE_PLUGIN_ROOT\"/scripts/memory-session-end.mjs", "timeout": 60 }
    ]
  }]
}
```

### 5.5 MCP 服务器注册

在 `~/.claude/settings.json` 中添加：

```json
{
  "mcpServers": {
    "omc-memory": {
      "command": "node",
      "args": ["/data/data/com.termux/files/home/.npm-global/lib/node_modules/oh-my-claude-sisyphus/scripts/memory-mcp-server.mjs"]
    }
  }
}
```

### 5.6 关键技术决策

| 决策 | 选择 | 原因 |
|------|------|------|
| SQLite 加载 | `createRequire` + `require('better-sqlite3')` | ESM hook 需要 CJS require |
| Batch 缓冲 | JSON 文件 `.omc/state/` | 每个 hook 是独立进程，无内存共享 |
| API 认证 | `ANTHROPIC_AUTH_TOKEN` 环境变量 | 复用已配置的 token |
| API 基地址 | `https://open.bigmodel.cn/api/anthropic` | 用户的实际 API 端点 |
| 压缩模型 | `glm-5-turbo`（快速便宜） | 提取摘要足够好 |
| FTS5 分词 | `porter unicode61` | 英文/中文词干分析 |
| 数据保留 | 30 天 | 防止数据库无限增长 |

---

## 六、更新持久化（restore.mjs）

### 6.1 问题

`omc update` 会覆盖所有修改过的文件，包括 auto-memory 的 9 个文件和 hooks 配置。

### 6.2 解决方案

创建 `~/.omc/patches/auto-memory/restore.mjs`，在更新后运行一次。

### 6.3 文件列表

restore.mjs 维护以下文件的备份和恢复：

```
scripts/lib/memory-db.mjs
scripts/lib/memory-capture.mjs
scripts/lib/memory-batch.mjs
scripts/lib/memory-compress.mjs
scripts/memory-posttool.mjs
scripts/memory-session-start.mjs
scripts/memory-precompact.mjs
scripts/memory-session-end.mjs
scripts/memory-mcp-server.mjs
scripts/memory-compress-worker.mjs
```

### 6.4 恢复流程

1. 将 patch 目录中的文件复制到 OMC 安装目录
2. 修改 `hooks/hooks.json`，追加 memory hooks（不覆盖其他 hook）
3. 修改 `~/.claude/settings.json`，注册 MCP 服务器

### 6.5 使用

```bash
# omc update 后执行
node ~/.omc/patches/auto-memory/restore.mjs
```

---

## 七、已修复的 Bug

### 7.1 FTS5 JOIN 别名错误

**文件**：`lib/memory-db.mjs`

**问题**：FTS5 content-sync 表不支持 JOIN 别名
```sql
-- 错误：no such column: f
JOIN observations_fts f ON f.rowid = o.id WHERE f MATCH ?

-- 修复：使用子查询
WHERE id IN (SELECT rowid FROM observations_fts WHERE observations_fts MATCH ?)
```

### 7.2 restore.mjs 子串匹配 Bug

**文件**：`~/.omc/patches/auto-memory/restore.mjs`

**问题**：`includes('memory-posttool.mjs')` 会错误匹配 `project-memory-posttool.mjs`

```javascript
// 错误
const alreadyExists = matcher.hooks.some(h => h.command.includes(script));

// 修复：精确文件名匹配
const matchScript = (cmd) => {
  if (!cmd) return false;
  const base = cmd.split('/').pop();
  return base === script;
};
const alreadyExists = matcher.hooks.some(h => matchScript(h.command));
```

---

## 八、settings.json 完整配置参考

`~/.claude/settings.json` 关键配置项（脱敏）：

```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "YOUR_API_TOKEN_HERE",
    "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5-turbo",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.1",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-4.7-flash"
  },
  "permissions": {
    "allow": [
      "Bash(npm *)",
      "Bash(node *)",
      "Bash(ls *)",
      "Bash(cat *)",
      "Bash(git *)",
      "Bash(grep *)",
      "Bash(find *)",
      "Bash(gh *)",
      "Read",
      "Write",
      "Edit"
    ]
  },
  "mcpServers": {
    "omc-memory": {
      "command": "node",
      "args": ["/data/data/com.termux/files/home/.npm-global/lib/node_modules/oh-my-claude-sisyphus/scripts/memory-mcp-server.mjs"]
    }
  }
}
```

---

## 九、性能分析

### 启动延迟实测（claude --dangerously-skip-permissions -c）

| 阶段 | 耗时 | 占比 |
|------|------|------|
| 4 个 SessionStart hooks | ~890ms | 7% |
| MCP 服务器初始化 | ~230ms | 2% |
| Claude Code 自身初始化 | ~11.4s | 91% |
| **总计** | **~12.5s** | |

各 SessionStart hook 单独耗时：
- `session-start.mjs`: ~250ms
- `project-memory-session.mjs`: ~200ms
- `wiki-session-start.mjs`: ~210ms
- `memory-session-start.mjs`: ~210ms

**结论**：启动延迟主要来自 Claude Code 加载会话文件和 API 首响应，OMC 影响可忽略。

### glibc-runner 启动对比

原生二进制通过 glibc-runner 启动比旧 JS 版本（v2.1.112）更快。

---

## 十、故障排除

### Q: claude 命令报 "No such file or directory"

A: 原生二进制的解释器路径 `/lib/ld-linux-aarch64.so.1` 不存在。确认使用了 wrapper 脚本启动：
```bash
cat ~/.npm-global/bin/claude
# 应该是 bash 脚本调用 glibc-runner，不是符号链接
```

### Q: Segmentation fault

A: 两种可能：
1. wrapper 脚本被 npm update 覆盖成了符号链接 → 重新创建 wrapper（步骤 3.3）
2. 使用了 patchelf 修改过的二进制 → 重新下载未修改的原始二进制

### Q: MCP 服务器 omc-memory 不工作

A: 检查：
```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | node ~/.npm-global/lib/node_modules/oh-my-claude-sisyphus/scripts/memory-mcp-server.mjs
# 应返回 JSON 响应
```

### Q: OMC update 后 auto-memory 失效

A: 运行恢复脚本：
```bash
node ~/.omc/patches/auto-memory/restore.mjs
```

### Q: LD_PRELOAD 冲突

A: glibc-runner 会自动处理 `LD_PRELOAD`（unset）。不要手动设置 `LD_PRELOAD` 为 bionic 的 `libtermux-exec-ld-preload.so`。

---

## 十一、参考链接

- OMC 仓库：https://github.com/Yeachan-Heo/oh-my-claudecode
- claude-mem（融合基础）：https://github.com/thedotmack/claude-mem
- Termux glibc 包：https://github.com/termux-pacman/glibc-packages
- 上游 glibc 源码：https://github.com/bminor/glibc
- Claude Code npm 包：https://www.npmjs.com/package/@anthropic-ai/claude-code
- 飞书评测报告：https://www.feishu.cn/docx/CE5Xdc9rOolJO5xCwyectHRRnMd
