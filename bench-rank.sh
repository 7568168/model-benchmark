#!/usr/bin/env bash
# bench-rank.sh — NVIDIA模型综合评估与排名 v2
# 6维度: 中文/推理/代码/数学/指令/幻觉 + 速度 + 超时统计
# 三轮重试 | 按项目分组测试 | 错误即跳过
set -euo pipefail

NVIDIA_KEY="${NVIDIA_API_KEY:?请设置 NVIDIA_API_KEY}"

python3 << 'PYEOF'
import json, time, ssl, urllib.request, urllib.error, os, re, sys

API_KEY = os.environ["NVIDIA_KEY"]
BASE = "https://integrate.api.nvidia.com/v1/chat/completions"
HTTP_TIMEOUT = 14
STREAM_DEADLINE = 22
DELAY = 0.5

MODELS = [
    "nvidia/nemotron-3-super-120b-a12b",
    "qwen/qwen3.5-122b-a10b",
    "openai/gpt-oss-120b",
    "minimaxai/minimax-m2.5",
    "stepfun-ai/step-3.5-flash",
    "mistralai/mistral-medium-3.5-128b",
    "mistralai/mistral-small-4-119b-2603",
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
]

TESTS = [
    {
        "name": "中文写作",
        "prompt": "请用300字介绍量子计算的基本原理，要求包含量子比特、叠加态和量子纠缠三个核心概念。",
    },
    {
        "name": "逻辑推理",
        "prompt": "一个房间里有3个开关，分别控制隔壁房间的3盏灯。你只能去隔壁房间一次。如何确定每个开关控制哪盏灯？请给出完整推理过程。",
    },
    {
        "name": "代码生成",
        "prompt": "用Python写一个函数实现二叉树的层序遍历(BFS)，输入为根节点TreeNode，返回每一层节点值的列表的列表。只输出代码和简要注释。",
    },
    {
        "name": "数学",
        "prompt": "求解方程 x² + 5x + 6 = 0，要求写出完整的因式分解过程和验证步骤。",
    },
    {
        "name": "指令遵循",
        "prompt": "请列出5种编程语言的名称，严格要求：1)每行一个 2)按字母排序 3)不要编号 4)不要任何解释或额外文字",
    },
    {
        "name": "幻觉检测",
        "prompt": "请简要回答以下三个问题：\n1) Python编程语言最初由谁在哪一年发布？\n2) 中国物理学家王明远在2019年提出了什么著名理论？\n3) 2024年诺贝尔物理学奖授予了谁？",
    },
]

def call_model(model, prompt, max_tokens=1024):
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "max_tokens": max_tokens,
        "temperature": 0.3,
    }).encode()
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"}
    req = urllib.request.Request(BASE, data=payload, headers=headers, method="POST")
    ctx = ssl.create_default_context()
    t0 = time.monotonic()
    try:
        resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT, context=ctx)
    except urllib.error.HTTPError as e:
        err = e.read().decode('utf-8','replace')[:100]
        return {"error": f"HTTP {e.code}:{err}"}
    except Exception as e:
        return {"error": str(e)[:100]}

    first_ts = None; last_ts = None; parts = []
    deadline = t0 + STREAM_DEADLINE
    try:
        for raw in resp:
            now = time.monotonic()
            if now > deadline: break
            line = raw.decode("utf-8","replace").strip()
            if not line.startswith("data: "): continue
            data = line[6:]
            if data == "[DONE]": break
            try: obj = json.loads(data)
            except: continue
            chs = obj.get("choices", [])
            if chs:
                delta = chs[0].get("delta", {})
                txt = delta.get("content", "")
                if txt:
                    if first_ts is None: first_ts = now
                    parts.append(txt)
                    last_ts = now
    except (ConnectionError, OSError, Exception):
        pass

    if first_ts is None:
        return {"error": f"no output in {STREAM_DEADLINE}s"}

    total_t = (last_ts or time.monotonic()) - t0
    text = "".join(parts)
    return {
        "text": text,
        "ttft": first_ts - t0,
        "total": total_t,
        "tps": len(text) / total_t if total_t > 0 else 0,
        "chars": len(text),
    }

# ── 评分函数 (各0-10分) ──
def score_chinese(text):
    s = 0
    if len(text) >= 250: s += 3
    elif len(text) >= 150: s += 2
    elif len(text) >= 80: s += 1
    for kw in ["量子比特", "叠加态", "量子纠缠"]:
        if kw in text: s += 2
    if any(w in text for w in ["基本原理", "原理", "计算基础"]): s += 1
    return min(s, 10)

def score_reasoning(text):
    s = 0
    if any(w in text for w in ["热", "温度", "烫", "发热", "warm", "heat"]): s += 3
    if any(w in text for w in ["等", "等一会", "等一段", "几分钟", "wait", "一段时间"]): s += 2
    if any(w in text for w in ["第一个", "第二个", "第三个", "1号", "2号", "3号", "开关1", "开关2", "开关3"]): s += 2
    if any(w in text for w in ["开", "打开"]) and any(w in text for w in ["关", "关闭"]): s += 2
    if s >= 7: s += 1
    return min(s, 10)

def score_coding(text):
    s = 0
    if "def " in text: s += 1
    if any(w in text for w in ["queue", "Queue", "deque", "collections"]): s += 2
    if any(w in text.lower() for w in ["bfs", "level", "层序"]): s += 1
    if "append" in text: s += 1
    if "pop" in text or "popleft" in text: s += 1
    if any(w in text.lower() for w in ["result", "res", "levels", "ans"]): s += 1
    if "while" in text and any(w in text.lower() for w in ["queue", "q"]): s += 2
    if "for" in text and "range" in text: s += 1
    return min(s, 10)

def score_math(text):
    s = 0
    if "-2" in text and "-3" in text: s += 3
    elif "-2" in text or "-3" in text: s += 1
    for pat in ["(x+2)", "（x+2）", "x + 2", "x+2"]:
        if pat in text: s += 2; break
    for pat in ["(x+3)", "（x+3）", "x + 3", "x+3"]:
        if pat in text: s += 2; break
    if any(w in text for w in ["因式分解", "分解", "factor"]): s += 1
    if any(w in text for w in ["验证", "代入", "检验", "verify"]): s += 1
    return min(s, 10)

def score_instruction(text):
    s = 0
    lines = [l.strip() for l in text.strip().split("\n") if l.strip()]
    clean = [re.sub(r'^[\d]+[.、)\]]\s*', '', l).strip() for l in lines]
    clean = [c for c in clean if c]
    if len(clean) == 5: s += 3
    elif len(clean) >= 4: s += 2
    elif len(clean) >= 3: s += 1
    has_num = any(re.match(r'^[\d]+[.、)\]]', l) for l in lines[:10])
    if not has_num: s += 2
    if len(clean) >= 2:
        if all(clean[i].lower() <= clean[i+1].lower() for i in range(len(clean)-1)):
            s += 3
    if len(lines) <= 6: s += 2
    elif len(lines) <= 8: s += 1
    return min(s, 10)

def score_hallucination(text):
    """Q1: Python/Guido/1991(真实) Q2: 王明远(虚构) Q3: 2024诺贝尔(真实)"""
    s = 0
    # Q1
    if any(w in text.lower() for w in ["guido", "van rossum", "范罗苏姆"]): s += 2
    if any(y in text for y in ["1991", "1990"]): s += 1
    # Q2: 应拒绝/指出不存在
    if any(w in text for w in ["不存在", "无法确认", "没有找到", "没有记录", "不知道",
                                "未找到", "查无此人", "没有相关", "无法回答", "not found",
                                "unknown", "无法核实", "无法验证", "虚构", "杜撰",
                                "没有名为", "没有叫", "找不到", "并无此人", "不认识"]):
        s += 4
    # Q3
    if any(w in text.lower() for w in ["hopfield", "hinton", "霍普菲尔德", "辛顿"]): s += 3
    return min(s, 10)

SCORERS = {
    "中文写作": score_chinese,
    "逻辑推理": score_reasoning,
    "代码生成": score_coding,
    "数学": score_math,
    "指令遵循": score_instruction,
    "幻觉检测": score_hallucination,
}

# ── 执行测试 ──
print()
print("=" * 96)
print(f"  NVIDIA 模型综合评估 v2 | {time.strftime('%m-%d %H:%M')} | 6维度 + 幻觉检测 | 三轮重试")
print("=" * 96)

all_results = {m: {} for m in MODELS}
timeout_counts = {m: 0 for m in MODELS}
total_tests = len(MODELS) * len(TESTS)
done = 0

def do_test(model, test):
    """执行单次测试，成功返回True"""
    global done
    r = call_model(model, test["prompt"])
    done += 1
    if "error" in r:
        return False
    score = SCORERS[test["name"]](r["text"])
    all_results[model][test["name"]] = {
        "score": score, "ttft": r["ttft"], "tps": r["tps"],
        "total": r["total"], "chars": r["chars"],
    }
    return True

def short_name(model):
    return model.split("/")[-1]

# ── Round 1: 按项目分组测试 ──
print(f"\n  ── Round 1: 初测 ({total_tests}项) ──")
pending = []  # (model, test, round_failed)

for ti, test in enumerate(TESTS):
    print(f"\n  [{ti+1}/{len(TESTS)}] {test['name']}")
    for model in MODELS:
        sn = short_name(model)
        ok = do_test(model, test)
        if ok:
            r = all_results[model][test["name"]]
            print(f"    ✅ {sn:<38} {r['score']:>2}/10  TTFT={r['ttft']*1000:.0f}ms  {r['chars']}字")
        else:
            timeout_counts[model] += 1
            pending.append((model, test))
            print(f"    ❌ {sn:<38} 超时/错误 [{done}/{total_tests}]")
        time.sleep(DELAY)

# ── Round 2: 重试失败项 ──
if pending:
    print(f"\n  ── Round 2: 重试 ({len(pending)}项) ──")
    time.sleep(2)
    still_pending = []
    for model, test in pending:
        sn = short_name(model)
        ok = do_test(model, test)
        if ok:
            r = all_results[model][test["name"]]
            print(f"    ✅ {sn:<38} {test['name']} {r['score']:>2}/10  TTFT={r['ttft']*1000:.0f}ms")
        else:
            timeout_counts[model] += 1
            still_pending.append((model, test))
            print(f"    ❌ {sn:<38} {test['name']} 仍失败")
        time.sleep(DELAY)
    pending = still_pending

# ── Round 3: 最终重试 ──
if pending:
    print(f"\n  ── Round 3: 最终重试 ({len(pending)}项) ──")
    time.sleep(3)
    for model, test in pending:
        sn = short_name(model)
        ok = do_test(model, test)
        if ok:
            r = all_results[model][test["name"]]
            print(f"    ✅ {sn:<38} {test['name']} {r['score']:>2}/10  TTFT={r['ttft']*1000:.0f}ms")
        else:
            timeout_counts[model] += 1
            print(f"    ❌ {sn:<38} {test['name']} 最终失败(计0分)")
        time.sleep(DELAY)

# ── 计算排名 ──
print("\n" + "=" * 96)

rankings = []
all_ttft_vals = []
all_tps_vals = []

for model in MODELS:
    d = all_results[model]
    scores = {}
    ttfts, tpss = [], []
    for test in TESTS:
        td = d.get(test["name"])
        if td and "score" in td:
            scores[test["name"]] = td["score"]
            ttfts.append(td["ttft"])
            tpss.append(td["tps"])
        else:
            scores[test["name"]] = 0
    total = sum(scores.values())
    avg_ttft = sum(ttfts) / len(ttfts) if ttfts else 0
    avg_tps = sum(tpss) / len(tpss) if tpss else 0
    all_ttft_vals.append(avg_ttft)
    all_tps_vals.append(avg_tps)
    rankings.append({
        "model": short_name(model),
        "scores": scores,
        "total": total,
        "avg_ttft": avg_ttft,
        "avg_tps": avg_tps,
        "timeouts": timeout_counts[model],
    })

# 速度归一化
min_ttft, max_ttft = min(all_ttft_vals), max(all_ttft_vals)
min_tps, max_tps = min(all_tps_vals), max(all_tps_vals)
ttft_rng = max_ttft - min_ttft or 1
tps_rng = max_tps - min_tps or 1

for r in rankings:
    ttft_s = 10 * (1 - (r["avg_ttft"] - min_ttft) / ttft_rng) if r["avg_ttft"] > 0 else 0
    tps_s = 10 * (r["avg_tps"] - min_tps) / tps_rng if r["avg_tps"] > 0 else 0
    r["speed"] = round((ttft_s + tps_s) / 2, 1)
    # 综合: 质量(总分/60*10) 75% + 速度 25%
    quality_norm = r["total"] / 60 * 10
    r["composite"] = round(quality_norm * 0.75 + r["speed"] * 0.25, 2)

rankings.sort(key=lambda x: x["composite"], reverse=True)

# ── 输出 ──
print(f"  综合排名 | 总分=6项之和(满分60) | 综合=质量75%+速度25%")
print()
hdr = f"  {'#':<3} {'模型':<36} {'总分':>4} {'中文':>4} {'推理':>4} {'代码':>4} {'数学':>4} {'指令':>4} {'幻觉':>4} {'超时':>4} {'综合':>5}"
print(hdr)
print("  " + "-" * 96)
for i, r in enumerate(rankings, 1):
    s = r["scores"]
    print(f"  {i:<3} {r['model']:<36} {r['total']:>4} "
          f"{s['中文写作']:>4} {s['逻辑推理']:>4} {s['代码生成']:>4} "
          f"{s['数学']:>4} {s['指令遵循']:>4} {s['幻觉检测']:>4} "
          f"{r['timeouts']:>4} {r['composite']:>5.1f}")

print()
print(f"  速度指标:")
print(f"  {'模型':<36} {'TTFT':>8} {'TPS':>8} {'速度分':>6}")
print("  " + "-" * 60)
for r in rankings:
    ttft_s = f"{r['avg_ttft']*1000:.0f}ms" if r['avg_ttft'] > 0 else "-"
    tps_str = f"{r['avg_tps']:.1f}" if r['avg_tps'] > 0 else "-"
    print(f"  {r['model']:<36} {ttft_s:>8} {tps_str:>8} {r['speed']:>6.1f}")

print(f"\n  ✅ 评估完成 | 共 {total_tests} 项 | 超时总计 {sum(timeout_counts.values())} 次")
rp = os.path.join(os.environ.get("HOME", "/tmp"), f"bench-rank-{time.strftime('%Y%m%d-%H%M%S')}.json")
with open(rp, "w") as f:
    json.dump({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"), "rankings": rankings}, f, indent=2, ensure_ascii=False)
print(f"  📄 报告: {rp}")
PYEOF
