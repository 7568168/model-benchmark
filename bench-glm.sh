#!/usr/bin/env bash
# bench-glm.sh — GLM模型综合评估 v2
# 优化: 历史分数回退 | 快速跳过连续失败 | Round2/3缩短超时
set -euo pipefail

API_KEY="${GLM_API_KEY:-YOUR_GLM_API_KEY_HERE}"
BASE="https://open.bigmodel.cn/api/paas/v4/chat/completions"

python3 << 'PYEOF'
import json, time, ssl, urllib.request, urllib.error, os, re, sys, glob
sys.stdout = os.fdopen(sys.stdout.fileno(), 'w', buffering=1)

API_KEY = os.environ["API_KEY"]
BASE = os.environ["BASE"]
HTTP_TIMEOUT = 25
STREAM_DEADLINE_R1 = 40
STREAM_DEADLINE_R2 = 20
DELAY = 0.2

MODELS = [
    "glm-5.1",
    "glm-5",
    "glm-5-turbo",
    "glm-4.7",
    "glm-4.7-flash",
    "glm-4.7-flashx",
    "glm-4.6",
    "glm-4.6v-flash",
]

TESTS = [
    {"name": "中文写作", "prompt": "请用300字介绍量子计算的基本原理，要求包含量子比特、叠加态和量子纠缠三个核心概念。"},
    {"name": "逻辑推理", "prompt": "一个房间里有3个开关，分别控制隔壁房间的3盏灯。你只能去隔壁房间一次。如何确定每个开关控制哪盏灯？请给出完整推理过程。"},
    {"name": "代码生成", "prompt": "用Python写一个函数实现二叉树的层序遍历(BFS)，输入为根节点TreeNode，返回每一层节点值的列表的列表。只输出代码和简要注释。"},
    {"name": "数学", "prompt": "求解方程 x² + 5x + 6 = 0，要求写出完整的因式分解过程和验证步骤。"},
    {"name": "指令遵循", "prompt": "请列出5种编程语言的名称，严格要求：1)每行一个 2)按字母排序 3)不要编号 4)不要任何解释或额外文字"},
    {"name": "幻觉检测", "prompt": "请简要回答以下三个问题：\n1) Python编程语言最初由谁在哪一年发布？\n2) 中国物理学家王明远在2019年提出了什么著名理论？\n3) 2024年诺贝尔物理学奖授予了谁？"},
]

def call_model(model, prompt, max_tokens=1024, deadline=STREAM_DEADLINE_R1):
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
        err = e.read().decode('utf-8','replace')[:200]
        return {"error": f"HTTP {e.code}:{err}"}
    except Exception as e:
        return {"error": str(e)[:200]}
    first_ts = None; last_ts = None; parts = []
    dl = t0 + deadline
    try:
        for raw in resp:
            now = time.monotonic()
            if now > dl: break
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
    except Exception:
        pass
    if first_ts is None:
        return {"error": f"no output in {deadline}s"}
    total_t = (last_ts or time.monotonic()) - t0
    text = "".join(parts)
    return {"text": text, "ttft": first_ts - t0, "total": total_t,
            "tps": len(text) / total_t if total_t > 0 else 0, "chars": len(text)}

def score_chinese(t):
    s=0
    if len(t)>=250: s+=3
    elif len(t)>=150: s+=2
    elif len(t)>=80: s+=1
    for k in ["量子比特","叠加态","量子纠缠"]:
        if k in t: s+=2
    if any(w in t for w in ["基本原理","原理","计算基础"]): s+=1
    return min(s,10)

def score_reasoning(t):
    s=0
    if any(w in t for w in ["热","温度","烫","发热","warm","heat"]): s+=3
    if any(w in t for w in ["等","等一会","等一段","几分钟","wait","一段时间"]): s+=2
    if any(w in t for w in ["第一个","第二个","第三个","1号","2号","3号","开关1","开关2","开关3"]): s+=2
    if any(w in t for w in ["开","打开"]) and any(w in t for w in ["关","关闭"]): s+=2
    if s>=7: s+=1
    return min(s,10)

def score_coding(t):
    s=0
    if "def " in t: s+=1
    if any(w in t for w in ["queue","Queue","deque","collections"]): s+=2
    if any(w in t.lower() for w in ["bfs","level","层序"]): s+=1
    if "append" in t: s+=1
    if "pop" in t or "popleft" in t: s+=1
    if any(w in t.lower() for w in ["result","res","levels","ans"]): s+=1
    if "while" in t and any(w in t.lower() for w in ["queue","q"]): s+=2
    if "for" in t and "range" in t: s+=1
    return min(s,10)

def score_math(t):
    s=0
    if "-2" in t and "-3" in t: s+=3
    elif "-2" in t or "-3" in t: s+=1
    for p in ["(x+2)","（x+2）","x + 2","x+2"]:
        if p in t: s+=2; break
    for p in ["(x+3)","（x+3）","x + 3","x+3"]:
        if p in t: s+=2; break
    if any(w in t for w in ["因式分解","分解","factor"]): s+=1
    if any(w in t for w in ["验证","代入","检验","verify"]): s+=1
    return min(s,10)

def score_instruction(t):
    s=0
    lines = [l.strip() for l in t.strip().split("\n") if l.strip()]
    clean = [re.sub(r'^[\d]+[.、)\]]\s*','',l).strip() for l in lines]
    clean = [c for c in clean if c]
    if len(clean)==5: s+=3
    elif len(clean)>=4: s+=2
    elif len(clean)>=3: s+=1
    has_num = any(re.match(r'^[\d]+[.、)\]]', l) for l in lines[:10])
    if not has_num: s+=2
    if len(clean)>=2:
        if all(clean[i].lower()<=clean[i+1].lower() for i in range(len(clean)-1)): s+=3
    if len(lines)<=6: s+=2
    elif len(lines)<=8: s+=1
    return min(s,10)

def score_hallucination(t):
    s=0
    if any(w in t.lower() for w in ["guido","van rossum","范罗苏姆"]): s+=2
    if any(y in t for y in ["1991","1990"]): s+=1
    if any(w in t for w in ["不存在","无法确认","没有找到","没有记录","不知道","未找到","查无此人","没有相关","无法回答","not found","unknown","无法核实","无法验证","虚构","杜撰","没有名为","没有叫","找不到","并无此人","不认识"]): s+=4
    if any(w in t.lower() for w in ["hopfield","hinton","霍普菲尔德","辛顿"]): s+=3
    return min(s,10)

SCORERS = {"中文写作":score_chinese,"逻辑推理":score_reasoning,"代码生成":score_coding,"数学":score_math,"指令遵循":score_instruction,"幻觉检测":score_hallucination}

# ── Load historical GLM scores ──
hist_dir = os.environ.get("HOME", "/tmp")
hist_files = sorted(glob.glob(os.path.join(hist_dir, "bench-rank-glm-*.json")), reverse=True)
hist_scores = {}
for hf in hist_files:
    try:
        with open(hf) as f:
            hd = json.load(f)
        for r in hd.get("rankings", []):
            m = r["model"]
            if m not in hist_scores:
                hist_scores[m] = r.get("scores", {})
        print(f"  📂 加载历史: {os.path.basename(hf)}")
    except:
        pass
if hist_scores:
    print(f"  📊 历史分数覆盖: {len(hist_scores)} 个模型")
    for m, sc in hist_scores.items():
        print(f"     {m}: {sc}")

# ── Main ──
print()
print("=" * 100)
print(f"  GLM 模型综合评估 v2 | {time.strftime('%m-%d %H:%M')} | 历史回退+快速跳过")
print("=" * 100)

all_results = {m:{} for m in MODELS}
timeout_counts = {m:0 for m in MODELS}
total_tests = len(MODELS) * len(TESTS)
done = 0
phase_times = {"R1": 0, "R2": 0, "R3": 0}
fallback_used = []

def do_test(model, test, deadline=STREAM_DEADLINE_R1):
    global done
    r = call_model(model, test["prompt"], deadline=deadline)
    done += 1
    if "error" in r:
        return False
    score = SCORERS[test["name"]](r["text"])
    all_results[model][test["name"]] = {"score":score,"ttft":r["ttft"],"tps":r["tps"],"total":r["total"],"chars":r["chars"]}
    return True

# Round 1
t_start = time.monotonic()
print(f"\n  ── Round 1 ({total_tests}项, deadline={STREAM_DEADLINE_R1}s) ──")
pending = []
for ti, test in enumerate(TESTS):
    print(f"\n  [{ti+1}/{len(TESTS)}] {test['name']}")
    for model in MODELS:
        ok = do_test(model, test)
        if ok:
            r = all_results[model][test["name"]]
            print(f"    ✅ {model:<24} {r['score']:>2}/10  TTFT={r['ttft']*1000:.0f}ms  {r['chars']}字")
        else:
            timeout_counts[model] += 1
            pending.append((model, test))
            print(f"    ❌ {model:<24} 超时 [{done}/{total_tests}]")
        time.sleep(DELAY)
phase_times["R1"] = time.monotonic() - t_start

# Round 2: shorter deadline, skip if model failed >=4 in R1
fail_counts_r1 = {m: timeout_counts[m] for m in MODELS}
skip_threshold = 4
if pending:
    print(f"\n  ── Round 2 ({len(pending)}项, deadline={STREAM_DEADLINE_R2}s, 跳过R1失败≥{skip_threshold}次的模型) ──")
    t_start = time.monotonic()
    time.sleep(1)
    still = []
    for model, test in pending:
        if fail_counts_r1[model] >= skip_threshold:
            timeout_counts[model] += 1
            print(f"    ⏭️ {model:<24} {test['name']} 跳过(R1失败{fail_counts_r1[model]}次)")
            continue
        ok = do_test(model, test, deadline=STREAM_DEADLINE_R2)
        if ok:
            r = all_results[model][test["name"]]
            print(f"    ✅ {model:<24} {test['name']} {r['score']:>2}/10")
        else:
            timeout_counts[model] += 1
            still.append((model, test))
            print(f"    ❌ {model:<24} {test['name']} 仍失败")
        time.sleep(DELAY)
    pending = still
    phase_times["R2"] = time.monotonic() - t_start

# Round 3: only for models with <4 R1 failures
if pending:
    print(f"\n  ── Round 3 ({len(pending)}项, deadline={STREAM_DEADLINE_R2}s) ──")
    t_start = time.monotonic()
    time.sleep(1)
    for model, test in pending:
        ok = do_test(model, test, deadline=STREAM_DEADLINE_R2)
        if ok:
            r = all_results[model][test["name"]]
            print(f"    ✅ {model:<24} {test['name']} {r['score']:>2}/10")
        else:
            timeout_counts[model] += 1
            print(f"    ❌ {model:<24} {test['name']} 最终失败→查历史")
        time.sleep(DELAY)
    phase_times["R3"] = time.monotonic() - t_start

# ── Apply historical fallback ──
print(f"\n  ── 历史分数回退 ──")
for model in MODELS:
    for test in TESTS:
        tn = test["name"]
        if tn not in all_results[model]:
            hs = hist_scores.get(model, {}).get(tn)
            if hs is not None:
                all_results[model][tn] = {"score": hs, "ttft": 0, "tps": 0, "total": 0, "chars": 0}
                fallback_used.append((model, tn, hs))
                print(f"    📋 {model:<24} {tn} → 历史分 {hs}/10")
            else:
                all_results[model][tn] = {"score": 0, "ttft": 0, "tps": 0, "total": 0, "chars": 0}
                print(f"    ⚠️ {model:<24} {tn} → 无历史, 0分")

# Load previous NVIDIA results
prev_path = os.path.join(os.environ.get("HOME","/tmp"), "bench-rank-20260507-104024.json")
prev_data = None
if os.path.exists(prev_path):
    with open(prev_path) as f:
        prev_data = json.load(f)
    print(f"\n  📊 已加载NVIDIA历史数据: {prev_path}")

# Rankings
print("\n" + "=" * 100)
rankings = []
all_ttft_vals = []
all_tps_vals = []

for model in MODELS:
    d = all_results[model]
    scores = {}
    ttfts, tpss = [], []
    for test in TESTS:
        tn = test["name"]
        td = d.get(tn)
        if td and "score" in td:
            scores[tn] = td["score"]
            if td["ttft"] > 0:
                ttfts.append(td["ttft"])
                tpss.append(td["tps"])
    total = sum(scores.values())
    avg_ttft = sum(ttfts)/len(ttfts) if ttfts else 0
    avg_tps = sum(tpss)/len(tpss) if tpss else 0
    all_ttft_vals.append(avg_ttft)
    all_tps_vals.append(avg_tps)
    rankings.append({"model":model,"provider":"GLM","scores":scores,"total":total,
                     "avg_ttft":avg_ttft,"avg_tps":avg_tps,"timeouts":timeout_counts[model]})

if prev_data:
    for r in prev_data["rankings"]:
        r["provider"] = "NVIDIA"
        all_ttft_vals.append(r["avg_ttft"])
        all_tps_vals.append(r["avg_tps"])
        rankings.append(r)

min_ttft, max_ttft = min(all_ttft_vals), max(all_ttft_vals)
min_tps, max_tps = min(all_tps_vals), max(all_tps_vals)
ttft_rng = max_ttft - min_ttft or 1
tps_rng = max_tps - min_tps or 1

for r in rankings:
    ttft_s = 10*(1-(r["avg_ttft"]-min_ttft)/ttft_rng) if r["avg_ttft"]>0 else 0
    tps_s = 10*(r["avg_tps"]-min_tps)/tps_rng if r["avg_tps"]>0 else 0
    r["speed"] = round((ttft_s+tps_s)/2, 1)
    quality_norm = r["total"]/60*10
    r["composite"] = round(quality_norm*0.75 + r["speed"]*0.25, 2)

rankings.sort(key=lambda x: x["composite"], reverse=True)

print(f"  综合排名 | GLM+ NVIDIA | 总分=6项之和(满分60) | 综合=质量75%+速度25%")
print()
hdr = f"  {'#':<3} {'提供商':<6} {'模型':<28} {'总分':>4} {'中文':>4} {'推理':>4} {'代码':>4} {'数学':>4} {'指令':>4} {'幻觉':>4} {'超时':>4} {'综合':>5}"
print(hdr)
print("  " + "-" * 100)
for i, r in enumerate(rankings, 1):
    s = r["scores"]
    print(f"  {i:<3} {r['provider']:<6} {r['model']:<28} {r['total']:>4} "
          f"{s['中文写作']:>4} {s['逻辑推理']:>4} {s['代码生成']:>4} "
          f"{s['数学']:>4} {s['指令遵循']:>4} {s['幻觉检测']:>4} "
          f"{r['timeouts']:>4} {r['composite']:>5.1f}")

print()
print(f"  速度指标:")
print(f"  {'提供商':<6} {'模型':<28} {'TTFT':>8} {'TPS':>8} {'速度分':>6}")
print("  " + "-" * 60)
for r in rankings:
    ttft_s = f"{r['avg_ttft']*1000:.0f}ms" if r['avg_ttft']>0 else "-"
    tps_str = f"{r['avg_tps']:.1f}" if r['avg_tps']>0 else "-"
    print(f"  {r['provider']:<6} {r['model']:<28} {ttft_s:>8} {tps_str:>8} {r['speed']:>6.1f}")

# Timing summary
print(f"\n  ⏱️ 耗时统计:")
for phase, secs in phase_times.items():
    print(f"    {phase}: {secs:.0f}s ({secs/60:.1f}min)")
total_time = sum(phase_times.values())
print(f"    总计: {total_time:.0f}s ({total_time/60:.1f}min)")
if fallback_used:
    print(f"\n  📋 历史回退使用: {len(fallback_used)}项")
    for m, t, s in fallback_used:
        print(f"    {m} {t} → {s}/10")

print(f"\n  ✅ 评估完成 | GLM {len(MODELS)}个 + NVIDIA 6个 | 共 {len(rankings)} 个模型")
rp = os.path.join(os.environ.get("HOME","/tmp"), f"bench-rank-glm-{time.strftime('%Y%m%d-%H%M%S')}.json")
with open(rp, "w") as f:
    json.dump({"timestamp":time.strftime("%Y-%m-%dT%H:%M:%S"), "rankings":rankings}, f, indent=2, ensure_ascii=False)
print(f"  📄 报告: {rp}")
PYEOF
