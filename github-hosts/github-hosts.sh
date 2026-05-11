#!/usr/bin/env bash
set -euo pipefail

# GitHub Hosts 本地获取脚本
# 结合 ineo6/hosts (多 DoH + TCP 测速) 和 FoxNick/fast-github-access (简洁轻量) 的优点

VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"

# === 默认配置 ===
OUTPUT_FILE="$HOME/github-hosts.txt"
TCP_TIMEOUT=5
PARALLEL=8
MODE="full"

# === DoH 服务器 (中国可达) ===
# json=JSON API(?name=&type=A), wire=RFC 8484(?dns=base64)
DOH_SERVERS=(
  "https://doh.pub/dns-query|json"
  "https://dns.alidns.com/dns-query|wire"
)

# === GitHub 域名列表 (合并 ineo6 + FoxNick) ===
DOMAINS=(
  github.githubassets.com
  central.github.com
  desktop.githubusercontent.com
  assets-cdn.github.com
  camo.githubusercontent.com
  github.map.fastly.net
  github.global.ssl.fastly.net
  gist.github.com
  github.io
  github.com
  api.github.com
  raw.githubusercontent.com
  user-images.githubusercontent.com
  favicons.githubusercontent.com
  avatars5.githubusercontent.com
  avatars4.githubusercontent.com
  avatars3.githubusercontent.com
  avatars2.githubusercontent.com
  avatars1.githubusercontent.com
  avatars0.githubusercontent.com
  avatars.githubusercontent.com
  codeload.github.com
  github-cloud.s3.amazonaws.com
  github-com.s3.amazonaws.com
  github-production-release-asset-2e65be.s3.amazonaws.com
  github-production-user-asset-6210df.s3.amazonaws.com
  github-production-repository-file-5c1aeb.s3.amazonaws.com
  githubstatus.com
  github.community
  media.githubusercontent.com
  objects.githubusercontent.com
  raw.github.com
  copilot-proxy.githubusercontent.com
)

# === 临时文件 ===
TMPDIR_BASE=""
cleanup() {
  [[ -n "$TMPDIR_BASE" && -d "$TMPDIR_BASE" ]] && rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT
TMPDIR_BASE="$(mktemp -d)"

# === 颜色 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { printf "${CYAN}[INFO]${NC} $1\n" "${@:2}" >&2; }
log_ok()    { printf "${GREEN}[OK]${NC} $1\n" "${@:2}" >&2; }
log_warn()  { printf "${YELLOW}[WARN]${NC} $1\n" "${@:2}" >&2; }
log_err()   { printf "${RED}[ERR]${NC} $1\n" "${@:2}" >&2; }

# === DoH 查询: 返回 IP 列表 (每行一个) ===
doh_query() {
  local domain="$1" entry="$2"
  local server="${entry%%|*}" dohtype="${entry##*|}"

  if [[ "$dohtype" == "json" ]]; then
    curl -sS --connect-timeout 5 --max-time 10 \
      -H "accept: application/dns-json" \
      "${server}?name=${domain}&type=A" 2>/dev/null \
      | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for a in d.get('Answer', []):
        if a.get('type') == 1:
            print(a['data'])
except: pass
" 2>/dev/null
  else
    python3 -c "
import urllib.request, base64, struct, random
domain = '${domain}'
txid = random.randint(0, 65535)
query = struct.pack('!HHHHHH', txid, 0x0100, 1, 0, 0, 0)
for label in domain.split('.'):
    query += bytes([len(label)]) + label.encode()
query += b'\x00' + struct.pack('!HH', 1, 1)
dns_param = base64.urlsafe_b64encode(query).rstrip(b'=').decode()
url = '${server}?dns=' + dns_param
req = urllib.request.Request(url, headers={'Accept': 'application/dns-message'})
try:
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = resp.read()
        ancount = struct.unpack('!H', data[6:8])[0]
        pos = 12
        while data[pos] != 0: pos += data[pos] + 1
        pos += 5
        for _ in range(ancount):
            if data[pos] & 0xC0 == 0xC0: pos += 2
            else:
                while data[pos] != 0: pos += data[pos] + 1
                pos += 1
            rtype = struct.unpack('!H', data[pos:pos+2])[0]
            pos += 8
            rdlen = struct.unpack('!H', data[pos:pos+2])[0]
            pos += 2
            if rtype == 1 and rdlen == 4:
                ip = '.'.join(str(b) for b in data[pos:pos+4])
                print(ip)
            pos += rdlen
except: pass
" 2>/dev/null
  fi
}

# === ipaddress.com 抓取: 绕过 DNS 污染 (ineo6 方案) ===
scrape_ipaddress() {
  local domain="$1"
  curl -sS --connect-timeout 5 --max-time 10 \
    -H "User-Agent: Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36" \
    "https://www.ipaddress.com/site/${domain}" 2>/dev/null \
    | python3 -c "
import sys, re
try:
    html = sys.stdin.read()
    # 提取 DNS 表格中的 A 记录
    ips = set()
    for m in re.finditer(r'>(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})<', html):
        ips.add(m.group(1))
    for ip in sorted(ips):
        print(ip)
except: pass
" 2>/dev/null
}

# === CDN 基础设施域名: 不提供 HTTPS, 需用 TCP 验证 ===
is_infra_domain() {
  [[ "$1" == *"fastly.net"* ]]
}

# === 系统DNS解析 (FoxNick 方式) ===
dns_fallback() {
  local domain="$1"
  # 直接 UDP 查询 DNS 服务器, 绕过 /system/etc/hosts
  python3 -c "
import socket, struct, random
domain = '${domain}'
# 依次尝试 114 DNS, AliDNS, DNSPod
servers = ['114.114.114.114', '223.5.5.5', '119.29.29.29']
for ns in servers:
    try:
        txid = random.randint(0, 65535)
        query = struct.pack('!HHHHHH', txid, 0x0100, 1, 0, 0, 0)
        for label in domain.split('.'):
            query += bytes([len(label)]) + label.encode()
        query += b'\x00' + struct.pack('!HH', 1, 1)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(3)
        sock.sendto(query, (ns, 53))
        data, _ = sock.recvfrom(512)
        sock.close()
        ancount = struct.unpack('!H', data[6:8])[0]
        pos = 12
        while data[pos] != 0: pos += data[pos] + 1
        pos += 5
        for _ in range(ancount):
            if data[pos] & 0xC0 == 0xC0: pos += 2
            else:
                while data[pos] != 0: pos += data[pos] + 1
                pos += 1
            rtype = struct.unpack('!H', data[pos:pos+2])[0]
            pos += 8
            rdlen = struct.unpack('!H', data[pos:pos+2])[0]
            pos += 2
            if rtype == 1 and rdlen == 4:
                ip = '.'.join(str(b) for b in data[pos:pos+4])
                print(ip)
            pos += rdlen
        break
    except: continue
" 2>/dev/null
}

# === 可达验证: 返回 0=可达 1=不可达 ===
https_verify() {
  local domain="$1" ip="$2"
  if is_infra_domain "$domain"; then
    # CDN 基础设施域名: 只验证 TCP 连通 (不提供 HTTPS)
    local result
    result="$(curl -so /dev/null -w '%{time_connect}' \
      --connect-timeout "$TCP_TIMEOUT" --max-time $((TCP_TIMEOUT + 2)) \
      --resolve "${domain}:443:${ip}" \
      "https://${domain}/" 2>/dev/null || true)"
    [[ -n "$result" && "$result" != "0.000000" ]]
  else
    # 普通域名: 验证完整 HTTPS
    local code
    code="$(curl -so /dev/null -w '%{http_code}' \
      --connect-timeout "$TCP_TIMEOUT" --max-time $((TCP_TIMEOUT + 2)) \
      --resolve "${domain}:443:${ip}" \
      "https://${domain}/" 2>/dev/null || true)"
    [[ -n "$code" && "$code" != "000" ]]
  fi
}

# === 测速: 验证 + 返回 "耗时_ms" 或空 ===
speed_test() {
  local domain="$1" ip="$2"
  if is_infra_domain "$domain"; then
    # CDN 基础设施域名: 只测 TCP 连通, 不管 curl 退出码 (TLS 会失败)
    local result
    result="$(curl -so /dev/null -w '%{time_connect}' \
      --connect-timeout "$TCP_TIMEOUT" --max-time $((TCP_TIMEOUT + 2)) \
      --resolve "${domain}:443:${ip}" \
      "https://${domain}/" 2>/dev/null || true)"
    [[ -z "$result" || "$result" == "0.000000" ]] && return 0
    python3 -c "print(f'{float(\"${result}\") * 1000:.0f}')" 2>/dev/null
  else
    # 普通域名: 完整 HTTPS 验证
    local result
    result="$(curl -so /dev/null -w '%{http_code} %{time_total}' \
      --connect-timeout "$TCP_TIMEOUT" --max-time $((TCP_TIMEOUT + 2)) \
      --resolve "${domain}:443:${ip}" \
      "https://${domain}/" 2>/dev/null || true)"
    [[ -z "$result" ]] && return 0
    local http_code="${result%% *}"
    local time_sec="${result##* }"
    [[ "$http_code" == "000" ]] && return 0
    python3 -c "print(f'{float(\"${time_sec}\") * 1000:.0f}')" 2>/dev/null
  fi
}

# === 解析域名: 并行查所有 DoH + ipaddress.com + UDP DNS, 去重 ===
resolve_domain() {
  local domain="$1"
  local tmpfile="${TMPDIR_BASE}/resolve_${domain//./_}"
  : > "$tmpfile"

  # 并行查询: DoH + ipaddress.com + UDP DNS
  local pids=()

  # DoH 查询
  for server in "${DOH_SERVERS[@]}"; do
    (
      ips="$(doh_query "$domain" "$server")"
      [[ -n "$ips" ]] && echo "$ips" >> "$tmpfile"
    ) &
    pids+=($!)
  done

  # ipaddress.com 抓取 (绕过 DNS 污染, 但可能被 Cloudflare 拦截)
  (
    local scraped
    scraped="$(scrape_ipaddress "$domain")" || true
    [[ -n "$scraped" ]] && echo "$scraped" >> "$tmpfile"
  ) &
  pids+=($!)

  # UDP 直查 DNS (国内 DNS 对部分域名比 DoH 更准确)
  (
    local udps
    udps="$(dns_fallback "$domain")" || true
    [[ -n "$udps" ]] && echo "$udps" >> "$tmpfile"
  ) &
  pids+=($!)

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # 去重
  if [[ -s "$tmpfile" ]]; then
    sort -u "$tmpfile" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  fi
}

# === 选最快 IP: 并行测速所有候选 IP ===
pick_fastest() {
  local domain="$1"
  shift
  local ips=("$@")
  [[ ${#ips[@]} -eq 0 ]] && return 1

  # 1 个 IP 直接返回
  [[ ${#ips[@]} -eq 1 ]] && { echo "${ips[0]} 0"; return 0; }

  local result_dir="${TMPDIR_BASE}/speed_${domain//./_}"
  mkdir -p "$result_dir"

  # 并行测速
  local pids=()
  for ip in "${ips[@]}"; do
    (
      ms="$(speed_test "$domain" "$ip")"
      if [[ -n "$ms" ]]; then
        echo "${ip} ${ms}" > "${result_dir}/${ip//./_}"
      fi
    ) &
    pids+=($!)
    # 控制并发
    if [[ ${#pids[@]} -ge $PARALLEL ]]; then
      for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
      pids=()
    fi
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  # 选最快的
  local best_ip="" best_ms=999999
  for f in "$result_dir"/*; do
    [[ -f "$f" ]] || continue
    local line
    line="$(cat "$f")"
    local ip="${line%% *}"
    local ms="${line##* }"
    if [[ "$ms" -lt "$best_ms" ]] 2>/dev/null; then
      best_ms="$ms"
      best_ip="$ip"
    fi
  done

  if [[ -n "$best_ip" ]]; then
    echo "${best_ip} ${best_ms}"
  else
    return 1
  fi
}

# === 远程获取 ineo6 hosts ===
remote_fetch() {
  local tmpfile="${TMPDIR_BASE}/remote_hosts"
  log_info "正在下载 ineo6/hosts ..."
  if curl -sSL --connect-timeout 10 --max-time 30 \
    "https://raw.githubusercontent.com/ineo6/hosts/master/hosts" \
    -o "$tmpfile" 2>/dev/null; then
    if grep -q "GitHub Host Start" "$tmpfile"; then
      cat "$tmpfile"
      return 0
    fi
  fi
  # 尝试 GitLab 镜像
  log_info "GitHub 失败, 尝试 GitLab 镜像 ..."
  if curl -sSL --connect-timeout 10 --max-time 30 \
    "https://gitlab.com/ineo6/hosts/-/raw/master/hosts" \
    -o "$tmpfile" 2>/dev/null; then
    if grep -q "GitHub Host Start" "$tmpfile"; then
      cat "$tmpfile"
      return 0
    fi
  fi
  log_err "远程下载失败"
  return 1
}

# === GitHub meta API 兜底 (官方 IP, 绕过所有 DNS 污染) ===
META_JSON=""

meta_fallback() {
  local domain="$1"
  # 非 GitHub 域名无法通过 meta API 解析
  case "$domain" in
    *.s3.amazonaws.com|*.fastly.net|assets-cdn.github.com) return 1 ;;
  esac

  # 获取并缓存 meta API (每次运行只请求一次)
  if [[ -z "$META_JSON" ]]; then
    META_JSON="$(curl -sS --connect-timeout 5 --max-time 10 \
      "https://api.github.com/meta" 2>/dev/null)" || true
  fi
  [[ -z "$META_JSON" ]] && return 1

  # 按域名选类别
  local category="web"
  case "$domain" in
    api.github.com) category="api" ;;
    codeload.github.com) category="git" ;;
    github.io) category="pages" ;;
  esac

  # 提取 /32 单播 IP
  local ips
  ips="$(echo "$META_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for ip in d.get('${category}', []):
        if ip.endswith('/32'):
            print(ip.replace('/32', ''))
except: pass
" 2>/dev/null)" || true
  [[ -z "$ips" ]] && return 1

  # 并行验证, 返回第一个可达 IP
  local result_dir="${TMPDIR_BASE}/meta_${domain//./_}"
  rm -rf "$result_dir" 2>/dev/null; mkdir -p "$result_dir"
  local pids=()
  while IFS= read -r ip; do
    (
      if https_verify "$domain" "$ip"; then
        echo "$ip" > "${result_dir}/ok"
      fi
    ) &
    pids+=($!)
    if [[ ${#pids[@]} -ge $PARALLEL ]]; then
      for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
      pids=()
      [[ -f "${result_dir}/ok" ]] && { cat "${result_dir}/ok"; return 0; }
    fi
  done <<< "$ips"
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  [[ -f "${result_dir}/ok" ]] && { cat "${result_dir}/ok"; return 0; }
  return 1
}

# === 生成 hosts (主流程) ===
generate_hosts() {
  local total=${#DOMAINS[@]}
  local current=0
  local ok=0 fail=0

  printf "# GitHub Host Start\n"
  printf "# Update at: %s\n" "$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S (%Z)')"
  printf "# Source: Local DoH + TCP speed test\n"

  for domain in "${DOMAINS[@]}"; do
    current=$((current + 1))
    if [[ "$MODE" == "fast" ]]; then
      # 快速模式: 系统 DNS
      local ip
      ip="$(dns_fallback "$domain")" || true
      if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf "%-30s %s\n" "$ip" "$domain"
        ok=$((ok + 1))
        log_ok "[%d/%d] %s → %s" "$current" "$total" "$domain" "$ip"
      else
        fail=$((fail + 1))
        log_warn "[%d/%d] %s → 解析失败" "$current" "$total" "$domain"
      fi
    else
      # 完整模式: DoH + 测速 + 多重回退
      log_info "[%d/%d] %s — 查询 DoH ..." "$current" "$total" "$domain"
      local ips
      ips="$(resolve_domain "$domain")" || true

      local best_ip="" method=""

      # Step 1: 候选 IP 测速
      if [[ -n "$ips" ]]; then
        local ip_array
        mapfile -t ip_array <<< "$ips"
        log_info "[%d/%d] %s — %d 个候选 IP, 测速中 ..." "$current" "$total" "$domain" "${#ip_array[@]}"
        local result
        result="$(pick_fastest "$domain" "${ip_array[@]}")" || true
        if [[ -n "$result" ]]; then
          best_ip="${result%% *}"
          method="${result##* }"
        fi
      fi

      # Step 2: 系统 DNS 回退
      if [[ -z "$best_ip" ]]; then
        local ip
        ip="$(dns_fallback "$domain" | head -1)" || true
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && https_verify "$domain" "$ip"; then
          best_ip="$ip"
          method="dns-fallback"
        fi
      fi

      # Step 3: GitHub meta API 回退
      if [[ -z "$best_ip" ]]; then
        local meta_ip
        meta_ip="$(meta_fallback "$domain")" || true
        if [[ -n "$meta_ip" ]]; then
          best_ip="$meta_ip"
          method="meta-api"
        fi
      fi

      # Step 4: 使用任意候选 IP (未验证, 宁可慢不可缺)
      if [[ -z "$best_ip" && -n "$ips" ]]; then
        best_ip="$(echo "$ips" | head -1)"
        method="unverified"
      fi

      # 输出结果
      if [[ -n "$best_ip" ]]; then
        printf "%-30s %s\n" "$best_ip" "$domain"
        ok=$((ok + 1))
        if [[ "$method" == "unverified" ]]; then
          log_warn "[%d/%d] %s → %s (未验证, DNS 可能受污染)" "$current" "$total" "$domain" "$best_ip"
        elif [[ "$method" == "dns-fallback" || "$method" == "meta-api" ]]; then
          log_warn "[%d/%d] %s → %s (%s 回退)" "$current" "$total" "$domain" "$best_ip" "$method"
        else
          log_ok "[%d/%d] %s → %s (%sms)" "$current" "$total" "$domain" "$best_ip" "$method"
        fi
      else
        fail=$((fail + 1))
        log_err "[%d/%d] %s → 全部失败 (无任何 IP)" "$current" "$total" "$domain"
      fi
    fi
  done

  printf "# GitHub Host End\n"
  echo ""
  log_info "完成: %d 成功, %d 失败, 共 %d 个域名" "$ok" "$fail" "$total"
}

# === 后验证: 重新检测所有 IP, 替换失败的 ===
post_verify() {
  local infile="$1" outfile="$2"
  local verified=0 replaced=0 dropped=0

  log_info "后验证: 逐条 HTTPS 检测 ..."
  {
    while IFS= read -r line; do
      # 保留注释和空行
      if [[ "$line" =~ ^# ]] || [[ -z "$line" ]]; then
        echo "$line"
        continue
      fi

      local ip domain
      ip="$(echo "$line" | awk '{print $1}')"
      domain="$(echo "$line" | awk 'NF{print $NF}')"

      if https_verify "$domain" "$ip"; then
        echo "$line"
        verified=$((verified + 1))
      else
        # 首次失败, 重试一次 (排除网络波动)
        if https_verify "$domain" "$ip"; then
          echo "$line"
          verified=$((verified + 1))
          continue
        fi
        # 确认不可达, 尝试 UDP DNS 替换
        local new_ip
        new_ip="$(dns_fallback "$domain" | head -1)" || true
        if [[ -n "$new_ip" && "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && https_verify "$domain" "$new_ip"; then
          printf "%-30s %s\n" "$new_ip" "$domain"
          replaced=$((replaced + 1))
          log_warn "替换 %s: %s → %s (不可达)" "$domain" "$ip" "$new_ip"
        else
          # 替换也失败, 保留原 IP 不移除 (宁可慢不可缺)
          echo "$line"
          dropped=$((dropped + 1))
          log_warn "保留 %s: %s (验证失败但无替代)" "$domain" "$ip"
        fi
      fi
    done
  } < "$infile" > "$outfile"

  log_info "后验证完成: %d 验证通过, %d 替换, %d 移除" "$verified" "$replaced" "$dropped"
}

# === 帮助 ===
show_help() {
  cat <<EOF
GitHub Hosts 本地获取脚本 v${VERSION}

Usage: ${SCRIPT_NAME} [OPTION]

模式:
  (默认)    完整模式: 多个 DoH 查询 + TCP 测速选最优 IP
  -f        快速模式: 仅系统 DNS, 不测速
  -r        远程模式: 下载 ineo6/hosts 预生成文件

选项:
  -o FILE   输出文件 (默认: ~/github-hosts.txt)
  -t SEC    TCP 测速超时秒数 (默认: 5)
  -p N      并发连接数 (默认: 8)
  -h        显示帮助

示例:
  ${SCRIPT_NAME}              # 完整模式
  ${SCRIPT_NAME} -f           # 快速模式
  ${SCRIPT_NAME} -r           # 下载远程 hosts
  ${SCRIPT_NAME} -f -o /etc/hosts  # 指定输出
EOF
}

# === 主入口 ===
main() {
  while getopts "fro:t:p:h" opt; do
    case "$opt" in
      f) MODE="fast" ;;
      r) MODE="remote" ;;
      o) OUTPUT_FILE="$OPTARG" ;;
      t) TCP_TIMEOUT="$OPTARG" ;;
      p) PARALLEL="$OPTARG" ;;
      h) show_help; exit 0 ;;
      *) show_help; exit 1 ;;
    esac
  done

  case "$MODE" in
    remote)
      local content
      content="$(remote_fetch)" || exit 1
      if [[ "$OUTPUT_FILE" == "/dev/stdout" ]]; then
        echo "$content"
      else
        echo "$content" > "$OUTPUT_FILE"
        log_ok "已保存到 %s" "$OUTPUT_FILE"
      fi
      ;;
    fast)
      log_info "快速模式: 系统 DNS (无测速)"
      local raw_file="${TMPDIR_BASE}/hosts_raw.txt"
      generate_hosts > "$raw_file"
      if [[ "$OUTPUT_FILE" == "/dev/stdout" ]]; then
        post_verify "$raw_file" "/dev/stdout"
      else
        post_verify "$raw_file" "$OUTPUT_FILE"
        log_ok "已保存到 %s" "$OUTPUT_FILE"
      fi
      ;;
    full)
      log_info "完整模式: %d 个 DoH + TCP 测速" "${#DOH_SERVERS[@]}"
      local raw_file="${TMPDIR_BASE}/hosts_raw.txt"
      generate_hosts > "$raw_file"
      if [[ "$OUTPUT_FILE" == "/dev/stdout" ]]; then
        post_verify "$raw_file" "/dev/stdout"
      else
        post_verify "$raw_file" "$OUTPUT_FILE"
        log_ok "已保存到 %s" "$OUTPUT_FILE"
      fi
      ;;
  esac
}

main "$@"
