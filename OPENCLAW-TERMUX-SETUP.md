# OpenClaw on Termux 完整优化指南

> 涵盖 Workspace 深度优化、问题排查、子 Agent 配置、插件管理

---

## 一、环境信息

| 组件 | 版本/路径 |
|------|-----------|
| OpenClaw | 2026.5.5 / 2026.5.6 |
| 运行环境 | Termux on Android (aarch64) |
| 主模型 | glm-5.1 |
| 子 Agent 模型 | glm-5-turbo → glm-4.7 → glm-4.6v-flash → NVIDIA 轮询 |
| 配置文件 | `~/.openclaw/openclaw.json` |
| Workspace | `~/.openclaw/workspace/` |
| 会话目录 | `~/.openclaw/agents/main/sessions/` |

---

## 二、System Prompt 加载机制

### 8 个硬编码文件加载顺序

OpenClaw 启动时按固定顺序加载 workspace 下的 8 个文件：

| 顺序 | 文件 | 作用 |
|------|------|------|
| 1 | `SOUL.md` | 核心身份与人格定义 |
| 2 | `IDENTITY.md` | 角色定位 |
| 3 | `AGENTS.md` | Agent 配置与编排规则 |
| 4 | `TOOLS.md` | 工具使用规则 |
| 5 | `PROTOCOLS.md` | 协议与流程 |
| 6 | `MEMORY.md` | 记忆管理 |
| 7 | `HEARTBEAT.md` | 心跳与状态 |
| 8 | `USER.md` | 用户偏好 |

**关键规则**：
- 只有这 8 个文件会被自动注入 system prompt
- 其他文件（如 `lib/` 目录）不会被自动加载
- `BOOT.md` 可作为启动检查项，但不在硬编码列表中
- 加载优先级：硬编码文件 > workspace 其他文件 > 条件注入内容

---

## 三、Workspace 深度优化

### 3.1 优化目标

一切优化围绕"提升回答质量与准确性"展开，同时减少 token 消耗、提升效率。

### 3.2 前期研究（多轮联网分析）

分析过的 GitHub 项目（全分支源码分析）：

| 项目 | 提炼的优化思路 |
|------|----------------|
| openclaw/openclaw | 8 文件注入机制、system prompt 组装逻辑 |
| CherryHQ/cherry-studio | 回答质量提升工具对比 |
| code-yeongyu/oh-my-openagent | 多 Agent 编排方案 |
| code-yeongyu/oh-my-opencode | Workspace 编排参考 |
| happycastle114/oh-my-openclaw | 11 Agent + 5 层防护（后卸载） |
| NousResearch/hermes-agent | Hermes vs OpenClaw 功能对比 |
| phodal/build-agent-context-engineering | 上下文工程方法论 |
| MuhammadUsmanGM/claude-code-best-practices | 最佳实践参考 |
| brexhq/prompt-engineering | 提示工程技巧 |
| LouisShark/chatgpt_system_prompt | 系统 prompt 参考 |
| madaan/self-refine | 自我优化方法论 |
| e2b-dev/awesome-ai-agents | Agent 生态对比 |

参考的知乎文章：
- `zhihu.com/tardis/zm/art/675509396` — 提升回答质量
- `zhihu.com/p/25771359587` — GitHub 项目配合提升生成质量
- `zhihu.com/p/2014047512374298485` — 补充优化
- `zhihu.com/p/682606003` — 补充优化
- `zhihu.com/p/1967972169804944928` — 补充优化
- `zhihu.com/p/1971516988183511610` — 补充优化
- `zhihu.com/question/1992268656592299582` — 提问优化

### 3.3 条件注入（函数封装模式）

**原理**：将 workspace 中的长段落内容封装到独立文件，通过 system prompt 中的条件判断决定是否注入，类似编程语言的"函数封装"或"库调用"。

**实现方式**：
1. 将可条件加载的内容存入 `workspace/lib/` 目录（不会被自动注入）
2. 在 8 个硬编码文件中用简短引用指令替代长段落
3. OpenClaw 需要时自动从 lib/ 加载对应内容

**适用场景**：
- Sub-Agent 调度逻辑（仅触发子 agent 时加载）
- 反幻觉检测规则（复杂任务时加载）
- 代码审查检查清单（涉及代码时加载）
- 特定领域知识（相关任务时加载）

**Token 节省量化**：

| 方案 | 每轮注入量 | 节省 |
|------|-----------|------|
| 原始（全量注入） | ~8,700B (~2,175 token) | 基准 |
| 条件注入（首次方案） | ~4,200B (~1,050 token) | ~1,125 token/轮 |
| 函数封装（优化方案） | ~4,800B (~1,200 token) | ~975 token/轮 |
| 函数封装 + 紧凑标记 | ~3,100B (~775 token) | ~1,400 token/轮 |

### 3.4 紧凑标记

**原理**：去除 Markdown 格式噪音（`##`、`---`、列表缩进等），用纯语义表达。

**示例对比**：

```
# 常规 MD（~600B）
## 🤔 苏格拉底自问（Think² Lite）
M+ 复杂度任务启用，每步推理后自问：
1. "这步逻辑成立吗？"
2. "反过来也成立吗？"
3. "什么能推翻这个结论？"

# 紧凑标记（~200B）
苏格拉底自问|Think²Lite|M+任务启用|每步推理后自问:逻辑成立?反例?推翻?
C任务额外启用:验证步骤|不跳步骤
```

**规则**：
- 用 `|` 分隔项
- 去掉 `#`、`-`、`>` 等格式符号
- 保留关键语义词，去除填充词
- 去掉 emoji

### 3.5 oh-my-openclaw 分析与卸载

**分析结论**：
- npm 上 `minpeter/oh-my-openclaw` 是 CLI 预设工具（非多 Agent 编排）
- `happycastle114/oh-my-openclaw` 是多 Agent 编排插件（11 Agent + 5 层防护）
- 与 workspace 优化内容有大量重复/冲突
- `session-sync.ts` 覆盖机制会与 workspace 手动配置冲突

**卸载原因**：
- 与 workspace 优化方案重复
- 增加 system prompt token 开销
- 部分功能（反幻觉、注水检测）可移植到 workspace

**已提取可用功能**：
- comment-checker AI 注水检测代码（可独立使用）

### 3.6 Hermes vs OpenClaw 对比

**全分支源码分析结论**：

| 能力 | Hermes | OpenClaw (via workspace) |
|------|--------|--------------------------|
| 多 Agent 编排 | 原生支持 | 通过 workspace 可实现 |
| 自我优化 | 内置 | 需手动配置 |
| 工具调用 | 丰富 | 丰富 |
| 上下文管理 | 自动压缩 | 需配置 compaction |
| workspace 可补足 | — | 约 60-70% 的独有功能 |

---

## 四、Block Streaming 修复

### 问题
OpenClaw 发送到微信/飞书等渠道时，响应被分块截断导致文本丢失。

### 三个 Workaround

**方案 A（最稳定）**：禁用 block streaming
```json
// ~/.openclaw/openclaw.json → agents.defaults
{
  "blockStreamingDefault": "off"
}
```

**方案 B**：改用 message_end 边界
```json
{
  "blockStreamingBreak": "message_end"
}
```

**方案 C**：增加 coalescing 延迟
```json
{
  "blockStreamingCoalesce": {
    "idleMs": 3000,
    "maxChars": 2000
  }
}
```

**注意**：方案 A 在某些版本下无效，需结合版本测试。

---

## 五、子 Agent 配置

### 5.1 模型分配策略

以 5 个子 agent 为例，按 API key 负载均衡：

| 优先级 | 模型 | 来源 | 状态 |
|--------|------|------|------|
| 1 | glm-5-turbo | GLM API | 稳定 |
| 2 | glm-4.7 | GLM API | 稳定 |
| 3 | glm-4.6v-flash | GLM API（免费） | 稳定 |
| 4-5 | NVIDIA 模型轮询 | NVIDIA API | 部分稳定 |

**配置位置**：`~/.openclaw/openclaw.json` → `agents.defaults.models` + `fallbacks`

### 5.2 已移除的模型

| 模型 | 移除原因 |
|------|----------|
| glm-4.7-flash | 超时率 >20%，总分 10/60 |
| glm-4.7-flashx | 超时率 >20%，总分 14/60 |
| glm-4.6 | 超时率高，总分 30/60 |
| nvidia/nemotron-3-nano | 中文写作 0 分，6 次超时 |
| nvidia/nemotron-3-super | 中文写作 0 分，8 次超时 |

### 5.3 子 Agent 未触发问题

**根因**：紧凑标记 + 条件注入后，system prompt 中的子 agent 触发指令被压缩移除。

**解决方案**：
1. 在 `PROTOCOLS.md` 中加强子 agent 触发规则
2. 在 `AGENTS.md` 中添加子 agent 兜底检查
3. 两个方案可同时使用

**注意**：已有会话重启后不会加载新规则，需新建会话。

---

## 六、会话文件管理

### 问题
`.openclaw/agents/main/sessions/` 目录下的 JSONL 文件体积增长快，内容大量重复。

### 原因
- 上下文溢出压缩导致摘要重复
- 子 agent 结果注入父会话后叠加
- web_fetch 等操作导致上下文暴涨（50-63K tokens）

### 优化配置

通过环境变量控制（`~/.openclaw/openclaw.json` 中没有对应配置项）：

```bash
# 在 OpenClaw 启动环境或 gateway 配置中设置
# 具体变量名需查看 OpenClaw 文档
```

### 清理方法
```bash
# 清理旧会话文件（保留最近的）
cd ~/.openclaw/agents/main/sessions/
ls -lt *.jsonl | tail -n +20 | awk '{print $NF}' | xargs rm -f

# 修复权限
chmod 600 *.jsonl
```

---

## 七、权限错误修复

### 问题
```
Error: EACCES: permission denied, link '.../.usage-cost-cache.json.lock.xxx.tmp' -> '.../.usage-cost-cache.json.lock'
```

### 原因
会话目录权限不一致，lock 文件创建失败。

### 修复
```bash
# 修复会话目录权限
chmod 755 ~/.openclaw/agents/main/sessions/
chmod 600 ~/.openclaw/agents/main/sessions/*.jsonl 2>/dev/null

# 清理残留 lock 文件
rm -f ~/.openclaw/agents/main/sessions/*.tmp
rm -f ~/.openclaw/agents/main/sessions/*.lock.*
```

---

## 八、微信插件问题

### 版本兼容性

| OpenClaw 版本 | 微信状态 | 备注 |
|---------------|----------|------|
| 2026.5.5 | 不可用 | fetch failed / runtime timeout |
| 2026.5.6 | 部分可用 | getUpdates 偶发 fetch failed，不影响正常使用 |
| 降级版本 | 可用 | 偶发 fetch failed 警告 |

### 插件位置变更
- 旧版：`~/.openclaw/extensions/openclaw-weixin`
- 新版：`~/.openclaw/npm/node_modules/@tencent-weixin/openclaw-weixin`

### 清理 npx 安装残留
```bash
# npx -y @tencent-weixin/openclaw-weixin-cli install 会产生缓存
npm cache clean --force
rm -rf ~/.npm/_npx/
```

### 插件加载警告
```
plugins.allow is empty; discovered non-bundled plugins may auto-load
```
可在 `openclaw.json` 的 `plugins.allow` 中添加信任 ID 消除警告。

---

## 九、Rate Limit 处理

### 问题
```
API rate limit reached. Please try again later. rawError=429
该模型当前访问量过大，请您稍后再试
```

### 分析
- GLM API 对 glm-5.1 有请求频率限制
- 子 agent 并发启动时容易触发
- NVIDIA API 限制为 40RPM

### 优化
1. 子 agent 模型分配错开 API key（见第五章）
2. GLM 模型评测中：超时率高（>20%）的模型直接从配置移除
3. 评测脚本增加三轮重试 + 历史分数回退机制

---

## 十、上下文压缩与版本管理

### 10.1 Compaction 配置

OpenClaw 上下文溢出时自动压缩，配置位于 `openclaw.json` → `agents.defaults.compaction`。

**常见问题**：
- web_fetch 后上下文暴涨（50-63K tokens）触发压缩，之前研究内容被摘要覆盖
- 子 agent 结果注入父会话后上下文达 53K+ tokens，4 个模型连续 120s 超时
- 紧凑标记 + 条件注入可能导致子 agent 触发指令被压缩移除

**优化建议**：
- 关键触发规则放在 8 个硬编码文件中（不会被压缩移除）
- compaction 阈值适当调高，避免过早压缩
- 大型任务拆分为多个子 agent，每个子 agent 独立上下文

### 10.2 版本降级

当新版出现兼容问题时可降级：

```bash
# 查看可用版本
npm view openclaw versions --json

# 安装指定版本
npm install -g openclaw@2026.5.5

# 降级后需重启网关
```

**版本兼容性记录**：

| 版本 | 微信 | 稳定性 | 备注 |
|------|------|--------|------|
| 2026.5.5 | 不可用 | 中 | block streaming 问题 |
| 2026.5.6 | 偶发 fetch failed | 较好 | 推荐版本 |

### 10.3 npm update 注意事项

```bash
# npm update 会覆盖以下内容：
# - openclaw.json 中的部分配置（需备份）
# - 微信插件可能需要重新安装

# 更新前备份
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak

# 更新后对比
diff ~/.openclaw/openclaw.json.bak ~/.openclaw/openclaw.json
```

---

## 十二、优化矩阵（按重要性排序）

| 优先级 | 维度 | 优化项 | 状态 | 效果 |
|--------|------|--------|------|------|
| P0 | 回答质量 | 条件注入（函数封装） | 已实施 | 每轮节省 ~975 token，按需加载提升精准度 |
| P0 | 回答质量 | 紧凑标记 | 已实施 | 每轮额外节省 ~425 token |
| P0 | 稳定性 | Block streaming 修复 | 已实施 | 解决消息截断（影响所有渠道） |
| P0 | 子 Agent | 模型负载均衡 | 已实施 | 避免 rate limit，保证子 agent 可用 |
| P1 | 子 Agent | 触发规则加强 | 已实施 | 修复紧凑标记导致的未触发问题 |
| P1 | 回答质量 | 苏格拉底自问 | 已实施 | 推理准确度提升 |
| P1 | 回答质量 | 反幻觉检测 | 已实施 | 减少 AI 编造 |
| P1 | 回答质量 | 交叉验证 | 已实施 | 多角度确认结论 |
| P2 | 稳定性 | 权限修复 | 已实施 | 解决 EACCES lock 错误 |
| P2 | 效率 | 会话文件清理 | 已实施 | 控制体积增长，减少磁盘占用 |
| P2 | 效率 | Compaction 配置优化 | 已实施 | 避免过早压缩丢失关键内容 |

---

## 十三、参考链接

### GitHub 项目
- OpenClaw 主仓库：https://github.com/openclaw/openclaw
- Hermes 对比：https://github.com/NousResearch/hermes-agent
- claude-mem：https://github.com/thedotmack/claude-mem
- oh-my-openclaw（已卸载）：https://github.com/happycastle114/oh-my-openclaw
- oh-my-opencode：https://github.com/code-yeongyu/oh-my-opencode
- Cherry Studio：https://github.com/CherryHQ/cherry-studio
- Context Engineering：https://github.com/phodal/build-agent-context-engineering

### 飞书文档
- OpenClaw 优化完整文档：https://www.feishu.cn/docx/FKWddJw2uopZ38xOFr8cE5rUn0f

### OpenClaw Issues
- Block streaming 截断：https://github.com/openclaw/openclaw/issues/76477
- 消息丢失：https://github.com/openclaw/openclaw/issues/76568
