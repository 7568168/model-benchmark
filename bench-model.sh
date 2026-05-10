#!/usr/bin/env bash
# bench-model.sh — OpenAI 兼容 API 模型性能基准测试
# 参考: github.com/yinxulai/ait
# 指标: TTFT(首字延迟) | 输出TPS(吐字速度) | 吞吐TPS | TPOT
#
# Usage:
#   ./bench-model.sh              # 测全部有key的模型
#   ./bench-model.sh glm          # 测名称含glm的
#   ./bench-model.sh -n 5         # 5轮(默认3)
#   ./bench-model.sh -c 3         # 3并发(默认1)
#   ./bench-model.sh --list       # 列出可用模型
#   NVIDIA_API_KEY=xxx ./bench-model.sh nvidia  # 指定NVIDIA key

set -euo pipefail

COUNT=1; CONCURRENCY=5; TIMEOUT=10; MAX_TOKENS=300
PROMPT="你好，请用200字简要介绍人工智能的发展历史，从图灵测试开始到现代大语言模型。"

GLM_KEY=""
NVIDIA_KEY="${NVIDIA_API_KEY:?请设置 NVIDIA_API_KEY=nvapi_xxx}"

# ── 参数 ──
FILTER=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--count)  COUNT="$2"; shift 2 ;;
    -c|--concur) CONCURRENCY="$2"; shift 2 ;;
    -t|--timeout) TIMEOUT="$2"; shift 2 ;;
    -p|--prompt) PROMPT="$2"; shift 2 ;;
    --list)      FILTER="__LIST__"; shift ;;
    -*)          echo "用法: $0 [-n 轮数] [-c 并发] [-t 超时] [-p prompt] [--list] [模型名|编号]"; exit 1 ;;
    *)           FILTER="$1"; shift ;;
  esac
done

# ── 动态获取 NVIDIA 模型列表 ──
echo "正在获取 NVIDIA 模型列表..."
NVIDIA_MODELS=$(curl -sS --max-time 10 "https://integrate.api.nvidia.com/v1/models" \
  -H "Authorization: Bearer $NVIDIA_API_KEY" \
  -H "Content-Type: application/json" 2>/dev/null)

MODELS=()
while IFS= read -r mid; do
  [[ -z "$mid" ]] && continue
  MODELS+=("$mid|https://integrate.api.nvidia.com/v1|$mid|NVIDIA|")
done < <(echo "$NVIDIA_MODELS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    models = [m['id'] for m in d.get('data', []) if m.get('object') == 'model']
    # 过滤掉嵌入/视觉/安全等非 chat 模型
    skip = ['embed', 'clip', 'retriever', 'parse', 'safety', 'guard', 'reward', 'glinter', 'video', 'detect', 'translate', 'cosmos']
    chat = [m for m in models if not any(s in m.lower() for s in skip)]
    for m in sorted(chat):
        print(m)
except: pass
" 2>/dev/null)

if [[ ${#MODELS[@]} -eq 0 ]]; then
  echo "无法获取 NVIDIA 模型列表，使用内置列表"
  MODELS=(
    "openai/gpt-oss-120b|https://integrate.api.nvidia.com/v1|openai/gpt-oss-120b|NVIDIA|"
    "qwen/qwen3.5-122b-a10b|https://integrate.api.nvidia.com/v1|qwen/qwen3.5-122b-a10b|NVIDIA|"
    "stepfun-ai/step-3.5-flash|https://integrate.api.nvidia.com/v1|stepfun-ai/step-3.5-flash|NVIDIA|"
    "minimaxai/minimax-m2.5|https://integrate.api.nvidia.com/v1|minimaxai/minimax-m2.5|NVIDIA|"
  )
fi

echo "共 ${#MODELS[@]} 个模型待测"

declare -a M_NAME M_URL M_MID M_KEY M_ST
for i in "${!MODELS[@]}"; do
  IFS='|' read -r n u m k s <<< "${MODELS[$i]}"
  M_NAME[$i]="$n"; M_URL[$i]="$u"; M_MID[$i]="$m"; M_KEY[$i]="$k"; M_ST[$i]="$s"
done

# ── 列表 ──
if [[ "$FILTER" == "__LIST__" ]]; then
  printf "  %-3s %-18s %-35s %-6s %s\n" "#" "名称" "模型ID" "Key" "状态"
  for i in "${!M_NAME[@]}"; do
    ko="✅"
    [[ "${M_KEY[$i]}" == "GLM" && -z "$GLM_KEY" ]] && ko="❌"
    [[ "${M_KEY[$i]}" == "NVIDIA" && -z "$NVIDIA_KEY" ]] && ko="❌"
    printf "  %-3s %-18s %-35s %-6s %s\n" "$((i+1))" "${M_NAME[$i]}" "${M_MID[$i]}" "$ko" "${M_ST[$i]}"
  done
  exit 0
fi

# ── 筛选 ──
shopt -s nocasematch
declare -a IDX=()
for i in "${!M_NAME[@]}"; do
  k="${M_KEY[$i]}"; ok=true
  [[ "$k" == "GLM" && -z "$GLM_KEY" ]] && ok=false
  [[ "$k" == "NVIDIA" && -z "$NVIDIA_KEY" ]] && ok=false
  $ok || continue
  if [[ -z "$FILTER" ]]; then
    IDX+=($i)
  elif [[ "$FILTER" =~ ^[0-9]+$ ]] && (( FILTER == i+1 )); then
    IDX+=($i)
  elif [[ "${M_NAME[$i]}" == *"$FILTER"* ]] || [[ "${M_KEY[$i]}" == *"$FILTER"* ]]; then
    IDX+=($i)
  fi
done

[[ ${#IDX[@]} -eq 0 ]] && { echo "无可测模型"; exit 1; }

# ── 构建 JSON & 运行 python3 ──
MJ="["
for j in "${!IDX[@]}"; do
  i="${IDX[$j]}"; (( j > 0 )) && MJ+=","
  MJ+="{\"name\":\"${M_NAME[$i]}\",\"url\":\"${M_URL[$i]}\",\"mid\":\"${M_MID[$i]}\",\"key\":\"${M_KEY[$i]}\",\"st\":\"${M_ST[$i]}\"}"
done
MJ+="]"

REPORT="$HOME/bench-report-$(date +%Y%m%d-%H%M%S).json"

export _BC _BM _BG _BN _BR
_BC=$(python3 -c "import json;print(json.dumps({'count':$COUNT,'concur':$CONCURRENCY,'timeout':$TIMEOUT,'max_tokens':$MAX_TOKENS,'prompt':$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$PROMPT")}))")
_BM="$MJ"; _BG="$GLM_KEY"; _BN="$NVIDIA_KEY"; _BR="$REPORT"

python3 << 'PYEOF'
import json, time, statistics, ssl, urllib.request, urllib.error, os, concurrent.futures

cfg = json.loads(os.environ["_BC"])
models = json.loads(os.environ["_BM"])
glm_key = os.environ.get("_BG", "")
nv_key = os.environ.get("_BN", "")

def get_key(ke):
    return glm_key if ke == "GLM" else (nv_key if ke == "NVIDIA" else "")

def bench_one(mc):
    url = mc["url"].rstrip("/") + "/chat/completions"
    key = get_key(mc["key"])
    payload = json.dumps({
        "model": mc["mid"],
        "messages": [{"role": "user", "content": cfg["prompt"]}],
        "stream": True,
        "stream_options": {"include_usage": True},
        "max_tokens": cfg["max_tokens"],
        "temperature": 0.7,
    }).encode()
    headers = {"Content-Type": "application/json"}
    if key: headers["Authorization"] = f"Bearer {key}"

    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    ctx = ssl.create_default_context()
    t0 = time.monotonic()
    try:
        resp = urllib.request.urlopen(req, timeout=cfg["timeout"], context=ctx)
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode('utf-8','replace')[:150]}"}
    except Exception as e:
        return {"error": str(e)[:150]}

    first_ts = None; last_ts = None; parts = []; usage = None
    deadline = t0 + 8.0  # 8秒硬超时

    try:
        for raw in resp:
            if time.monotonic() > deadline:
                return {"error": "timeout >8s", "ttft": first_ts - t0 if first_ts else None, "total": time.monotonic() - t0}
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "): continue
            data = line[6:]
            if data == "[DONE]":
                last_ts = last_ts or time.monotonic(); break
            try: obj = json.loads(data)
            except: continue
            chs = obj.get("choices", [])
            if chs:
                delta = chs[0].get("delta", {})
                txt = delta.get("content", "")
                thk = delta.get("reasoning_content")
                if txt or (thk and isinstance(thk, str) and thk):
                    if first_ts is None: first_ts = time.monotonic()
                    if txt: parts.append(txt)
                    last_ts = time.monotonic()
            u = obj.get("usage")
            if u: usage = u
    except (ConnectionError, OSError, Exception) as e:
        if first_ts is None: return {"error": f"conn abort: {str(e)[:80]}"}

    if first_ts is None: return {"error": "no tokens within 8s", "total": time.monotonic() - t0}

    pt = usage.get("prompt_tokens",0) if usage else 0
    ct = usage.get("completion_tokens",0) if usage else 0
    tt = 0
    if usage and usage.get("completion_tokens_details"):
        d = usage["completion_tokens_details"]
        tt = d.get("thinking_tokens",0) or d.get("reasoning_tokens",0)
    if ct == 0: ct = max(1, sum(len(p) for p in parts) // 3)

    total_t = (last_ts or time.monotonic()) - t0
    gen_t = (last_ts or time.monotonic()) - first_ts if first_ts else 0
    return {
        "ttft": first_ts - t0, "total": total_t, "gen": gen_t,
        "pt": pt, "ct": ct, "tt": tt,
        "otps": ct / total_t if total_t > 0 and ct > 0 else 0,
        "ttps": (pt + ct) / total_t if total_t > 0 else 0,
        "tpot": gen_t / max(1, ct - 1) if ct > 1 and gen_t > 0 else 0,
        "reported": usage is not None,
    }

def fmt(s):
    return f"{s*1000:.0f}ms" if s < 1 else f"{s:.2f}s"

def run_model(mc, count, concur):
    name = mc["name"]; res = []; errs = []
    if concur <= 1:
        for i in range(count):
            r = bench_one(mc)
            (res if "ttft" in r else errs).append(r)
            print(f"\r  [{name}] {len(res)+len(errs)}/{count} ok={len(res)}", end="", flush=True)
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=concur) as pool:
            futs = {pool.submit(bench_one, mc): i for i in range(count)}
            for f in concurrent.futures.as_completed(futs):
                r = f.result()
                (res if "ttft" in r else errs).append(r)
                print(f"\r  [{name}] {len(res)+len(errs)}/{count} ok={len(res)}", end="", flush=True)
    print()
    return res, errs

def stats(res):
    if not res: return None
    s = {}
    for k in ["ttft","total","ct","otps","ttps"]:
        vals = [r[k] for r in res if r.get(k) is not None]
        if not vals: continue
        s[f"avg_{k}"] = statistics.mean(vals)
        s[f"min_{k}"] = min(vals)
        s[f"max_{k}"] = max(vals)
        s[f"sd_{k}"] = statistics.stdev(vals) if len(vals) > 1 else 0
    # gen/tpot may be missing from timeout results
    for k in ["gen","tpot"]:
        vals = [r[k] for r in res if k in r]
        if vals:
            s[f"avg_{k}"] = statistics.mean(vals)
        else:
            s[f"avg_{k}"] = 0
    s["avg_pt"] = statistics.mean([r["pt"] for r in res if "pt" in r] or [0])
    s["avg_tt"] = statistics.mean([r.get("tt",0) for r in res])
    return s

# ── Main ──
print()
print("=" * 88)
print(f"  模型基准测试 | {cfg['count']}轮 | 并发{cfg['concur']} | {time.strftime('%m-%d %H:%M')}")
print(f"  Prompt: {cfg['prompt'][:55]}...")
print("=" * 88)
print(f"  {'模型':<18}{'TTFT':>9}{'总耗时':>9}{'输出TPS':>10}{'吞吐TPS':>10}{'输出tok':>9}{'成功率':>7}")
print("-" * 88)

summaries = []
for mc in models:
    label = f"{mc['name']} {mc['st']}".strip()
    res, errs = run_model(mc, cfg["count"], cfg["concur"])
    s = stats(res)
    if not s or "avg_otps" not in s:
        print(f"  {label:<18}❌ {errs[0].get('error',errs[0])[:55] if errs else 'unknown'}")
        print("-" * 88); continue

    print(f"  {label:<18}{fmt(s.get('avg_ttft',0)):>9}{fmt(s.get('avg_total',0)):>9}"
          f"{s.get('avg_otps',0):>9.1f} {s.get('avg_ttps',0):>9.1f} {s.get('avg_ct',0):>8.0f}  {len(res)}/{cfg['count']}")
    for e in errs[:2]:
        msg = e.get("error", str(e)) if isinstance(e, dict) else str(e)
        print(f"  {'':>18}⚠️  {msg[:65]}")
    summaries.append({"name": mc["name"], **s})
    print("-" * 88)

if len(summaries) > 1:
    print(f"\n  📊 TPS 排名:")
    for i, s in enumerate(sorted(summaries, key=lambda x: x.get("avg_otps",0), reverse=True), 1):
        print(f"  {i}. {s['name']:<28} 输出TPS={s.get('avg_otps',0):.1f}  TTFT={fmt(s.get('avg_ttft',0))}  总耗时={fmt(s.get('avg_total',0))}")

print(f"\n  ✅ 完成")

rp = os.environ.get("_BR", "")
if rp and summaries:
    with open(rp, "w") as f:
        json.dump({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"), "config": cfg,
                    "results": [{k: v for k, v in s.items() if not callable(v)} for s in summaries]}, f, indent=2, ensure_ascii=False)
    print(f"  📄 报告: {rp}")
PYEOF
