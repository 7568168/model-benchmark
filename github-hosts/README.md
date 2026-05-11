# GitHub Hosts 本地加速

从本地网络环境获取最优 GitHub hosts，加速中国大陆访问。纯 bash 脚本，无需 jq/nc/dig 等额外工具。

结合 [ineo6/hosts](https://github.com/ineo6/hosts)（多源 DNS + TCP 测速）和 [FoxNick/fast-github-access](https://github.com/FoxNick/fast-github-access)（简洁轻量）的优点，在中国网络环境下本地运行，结果比 CI runner 生成的更适合实际使用。

> 环境要求：Termux（或 Linux） | curl | python3 | bash 5+

---

## 快速使用

```bash
# 完整模式（推荐）：多源 DoH + TCP 测速选最优 IP
bash github-hosts.sh

# 快速模式：仅系统 DNS 解析，几秒完成
bash github-hosts.sh -f

# 远程模式：直接下载 ineo6 预生成 hosts
bash github-hosts.sh -r

# 指定输出文件
bash github-hosts.sh -o ~/hosts

# 输出到终端预览
bash github-hosts.sh -o /dev/stdout
```

输出示例：
```
# GitHub Host Start
# Update at: 2026-05-11 04:48:22 (CST)
# Source: Local DoH + TCP speed test
185.199.111.215                github.githubassets.com
140.82.114.21                  central.github.com
20.205.243.166                 github.com
...
# GitHub Host End
```

---

## 工作原理

### IP 来源（5 路并行查询）

每个域名并行查询以下来源，合并去重后进入测速：

```
                         ┌─ DoH: doh.pub (腾讯, JSON API)
                         ├─ DoH: dns.alidns.com (阿里, RFC 8484)
  resolve_domain() ──────├─ ipaddress.com 网页抓取（绕 DNS 污染）
                         ├─ UDP 直查 114/阿里/DNSPod（绕 /etc/hosts）
                         └─ GitHub meta API（官方 IP 列表）
```

| 来源 | 原理 | 特点 |
|------|------|------|
| **doh.pub** | curl 请求 DNS-over-HTTPS JSON API | 腾讯提供，国内可达 |
| **dns.alidns.com** | Python 构造 DNS 报文，RFC 8484 编码请求 | 阿里提供，独立于 curl |
| **ipaddress.com** | 抓取网页 HTML，正则提取 IP | 绕过 DNS 污染，但有 Cloudflare 人机验证 |
| **UDP 直查** | Python 构造原始 DNS 报文，UDP 发到国内 DNS | 绕过系统 hosts 文件干扰 |
| **GitHub meta API** | `api.github.com/meta` 返回官方 IP 范围 | 最权威，逐个验证可用性 |

### 选 IP 流程

```
候选 IP 池（去重后）
    ↓
pick_fastest(): 并行 HTTPS/TCP 测速 → 选最快
    ↓ 全失败
dns_fallback(): UDP 查国内 DNS + HTTPS 验证
    ↓ 全失败
meta_fallback(): GitHub 官方 IP 逐个 HTTPS 验证
    ↓ 全失败
取第一个候选 IP（未验证，宁可慢不可缺）
```

测速方式按域名类型区分：

- **普通域名**：完整 HTTPS 请求，测量 `%{time_total}`（总耗时）
- **CDN 基础设施域名**（`*.fastly.net`）：仅 TCP 握手，测量 `%{time_connect}`（这些域名不提供 HTTPS）

### 后验证

生成 hosts 后逐条 HTTPS 检测，不可达的尝试替换。替换也失败的保留原 IP（宁可慢不可缺）。

---

## 域名列表

33 个 GitHub 相关域名，合并自 ineo6/hosts 和 FoxNick/fast-github-access：

**GitHub 自有域名（23 个）**

| 域名 | 用途 |
|------|------|
| github.com | 主站 |
| api.github.com | API |
| gist.github.com | Gist |
| github.io | GitHub Pages |
| raw.githubusercontent.com | 原始文件 |
| raw.github.com | 原始文件（短域名） |
| github.githubassets.com | 静态资源 |
| assets-cdn.github.com | CDN（已废弃） |
| camo.githubusercontent.com | Camo 图片代理 |
| desktop.githubusercontent.com | Desktop |
| user-images.githubusercontent.com | 用户上传图片 |
| media.githubusercontent.com | 媒体文件 |
| objects.githubusercontent.com | 对象存储 |
| favicons.githubusercontent.com | Favicon |
| avatars.githubusercontent.com | 头像 |
| avatars0-5.githubusercontent.com | 头像（CDN 节点） |
| codeload.github.com | 代码下载 |
| central.github.com | 中央服务 |
| copilot-proxy.githubusercontent.com | Copilot 代理 |
| githubstatus.com | 状态页 |
| github.community | 社区 |

**Fastly CDN（2 个）**

| 域名 | 用途 |
|------|------|
| github.map.fastly.net | Fastly 映射 |
| github.global.ssl.fastly.net | Fastly SSL |

**AWS S3（5 个）**

| 域名 | 用途 |
|------|------|
| github-cloud.s3.amazonaws.com | 云存储 |
| github-com.s3.amazonaws.com | 仓库数据 |
| github-production-release-asset-2e65be.s3.amazonaws.com | Release 资源 |
| github-production-user-asset-6210df.s3.amazonaws.com | 用户资源 |
| github-production-repository-file-5c1aeb.s3.amazonaws.com | 仓库文件 |

---

## 命令行参数

```
Usage: github-hosts.sh [OPTION]

模式:
  (默认)    完整模式: 多源 DoH 查询 + TCP 测速选最优 IP
  -f        快速模式: 仅系统 DNS, 不测速
  -r        远程模式: 下载 ineo6/hosts 预生成文件

选项:
  -o FILE   输出文件 (默认: ~/github-hosts.txt)
  -t SEC    TCP 测速超时秒数 (默认: 5)
  -p N      并发连接数 (默认: 8)
  -h        显示帮助
```

---

## 已知限制

| 问题 | 原因 | 影响 |
|------|------|------|
| `assets-cdn.github.com` 无 IP | 域名已废弃，全球无 DNS 记录 | 跳过，不影响使用 |
| `gist.github.com` IP 未验证 | GFW 在 TLS 层阻断（DNS + SNI 双重干扰） | 输出未验证 IP，需代理访问 |
| CDN IP 测速波动 | GitHub CDN 节点负载不均 | 每次运行结果可能不同 |
| ipaddress.com 抓取失败 | Cloudflare 人机验证拦截自动化请求 | 依赖其他 4 个来源补充 |

---

## 参考项目

- [ineo6/hosts](https://github.com/ineo6/hosts) — GitHub hosts 定时更新，多 DNS + TCP 测速
- [FoxNick/fast-github-access](https://github.com/FoxNick/fast-github-access) — 轻量级 GitHub 加速工具
