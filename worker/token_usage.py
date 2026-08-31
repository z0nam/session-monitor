#!/usr/bin/env python3
"""token_usage.py — 여러 기계의 Claude Code 토큰 사용량을 프로젝트 단위로 집계.

두 가지 모드:
  --local            이 기계의 ~/.claude/projects/**/*.jsonl 에서 메시지별 usage 합산 → JSON 1줄
  (기본) 오케스트레이터  host 목록의 각 기계에 접속해 --local 을 돌리고, 병합·분류해
                      손실 없는 CSV(기계×프로젝트 원자료)와 요약 테이블을 낸다.

원자료(CSV)는 (host, project) 단위라 어떤 재집계도 스프레드시트에서 다시 할 수 있다.
분류 규칙·호스트 목록은 개인정보이므로 레포가 아니라 로컬 config 에서 읽는다.
  기본 경로: ~/.config/smon/token-hosts.tsv , ~/.config/smon/token-rules.tsv
  (SMON_TOKEN_HOSTS / SMON_TOKEN_RULES 로 override; *.example.tsv 참고)

수집 소스: 각 기계의 ~/.claude/projects/<cwd-인코딩>/*.jsonl 안 assistant 메시지의
  message.usage = {input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}.
  총량 대부분은 cache_read(캐시 재사용)라 '실비'가 아니라 구독 사용량 성격.
"""
import os, sys, json, glob, socket, subprocess, csv, re, datetime, fnmatch

# ---------------- local scan (각 기계에서 실행) ----------------

def local_scan():
    root = os.path.expanduser("~/.claude/projects")
    projects = {}
    if os.path.isdir(root):
        for slug in os.listdir(root):
            d = os.path.join(root, slug)
            if not os.path.isdir(d):
                continue
            files = glob.glob(os.path.join(d, "*.jsonl"))
            if not files:
                continue
            a = {"in": 0, "out": 0, "cc": 0, "cr": 0, "msgs": 0,
                 "files": len(files), "cwd": ""}
            # cwd 는 가장 큰 파일 앞부분에서 한 번만 뽑는다
            for fp in sorted(files, key=lambda p: -os.path.getsize(p)):
                try:
                    with open(fp, errors="ignore") as f:
                        for i, ln in enumerate(f):
                            if i > 60:
                                break
                            if '"cwd"' not in ln:
                                continue
                            try:
                                o = json.loads(ln)
                            except Exception:
                                continue
                            if o.get("cwd"):
                                a["cwd"] = o["cwd"]
                                break
                except Exception:
                    pass
                if a["cwd"]:
                    break
            for fp in files:
                try:
                    with open(fp, errors="ignore") as f:
                        for ln in f:
                            if '"usage"' not in ln:
                                continue
                            try:
                                o = json.loads(ln)
                            except Exception:
                                continue
                            u = (o.get("message") or {}).get("usage")
                            if not isinstance(u, dict):
                                continue
                            a["in"]  += u.get("input_tokens", 0) or 0
                            a["out"] += u.get("output_tokens", 0) or 0
                            a["cc"]  += u.get("cache_creation_input_tokens", 0) or 0
                            a["cr"]  += u.get("cache_read_input_tokens", 0) or 0
                            a["msgs"] += 1
                except Exception:
                    pass
            projects[slug] = a
    return {"host": socket.gethostname(), "projects": projects}


# ---------------- 분류 ----------------

def is_home_root(cwd):
    return bool(re.match(r"^(/Users/[^/]+|/home/[^/]+|[A-Za-z]:\\Users\\[^\\]+)$", cwd or ""))

def is_dev_root(cwd):
    c = (cwd or "").rstrip("/\\")
    return c.endswith("/dev") or c.endswith("\\dev") or c.endswith("/projects") or c.endswith("\\projects")

def load_rules(path):
    """규칙: host_glob<TAB>kind<TAB>pattern<TAB>category<TAB>subcategory[<TAB>note].
    kind: cwd|slug (부분일치, 대소문자 무시) / host (호스트 전체) /
          mixed_root (홈·dev 루트) . 위에서부터 첫 매치가 이긴다.
    """
    rules = []
    if not path or not os.path.exists(path):
        return rules
    for ln in open(path, encoding="utf-8"):
        ln = ln.rstrip("\n")
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        p = ln.split("\t")
        if len(p) < 5:
            continue
        rules.append({
            "host": p[0], "kind": p[1], "pat": p[2],
            "cat": p[3], "sub": p[4],
            "note": p[5] if len(p) > 5 else "",
        })
    return rules

def classify(host, slug, cwd, rules):
    cwd_l = (cwd or "").lower()
    slug_l = (slug or "").lower()
    for r in rules:
        if not fnmatch.fnmatch(host, r["host"]):
            continue
        k = r["kind"]; pat = r["pat"]
        if k == "host":
            return r["cat"], r["sub"], r["note"]
        if k == "cwd" and pat.lower() in cwd_l:
            return r["cat"], r["sub"], r["note"]
        if k == "slug" and pat.lower() in slug_l:
            return r["cat"], r["sub"], r["note"]
        if k == "mixed_root" and (is_home_root(cwd) or is_dev_root(cwd)):
            return r["cat"], r["sub"], (r["note"] or "혼합루트")
    return "업무", "업무", ""


# ---------------- 호스트 목록 ----------------

def load_hosts(path):
    """host<TAB>pycmd . pycmd=='local' 이면 이 기계에서 직접 실행.
    없으면 이 기계만 로컬 스캔."""
    hosts = []
    if path and os.path.exists(path):
        for ln in open(path, encoding="utf-8"):
            ln = ln.rstrip("\n")
            if not ln.strip() or ln.lstrip().startswith("#"):
                continue
            p = ln.split("\t")
            if len(p) >= 2 and p[0]:
                hosts.append((p[0], p[1]))
    if not hosts:
        hosts = [(socket.gethostname(), "local")]
    return hosts

def scan_remote(host, pycmd, src, timeout=40):
    try:
        r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
                            host, pycmd, "-", "--local"],
                           input=src, capture_output=True, text=True, timeout=timeout)
        out = r.stdout.strip()
        # stdout 에 잡음이 섞일 수 있으니 마지막 JSON 줄만
        for line in reversed(out.splitlines()):
            line = line.strip()
            if line.startswith("{"):
                return json.loads(line), ""
        return None, (r.stderr.strip()[:200] or "no-json")
    except Exception as e:
        return None, str(e)[:200]


# ---------------- 메인 ----------------

def hfmt(n):
    for u, d in [("B", 1e9), ("M", 1e6), ("K", 1e3)]:
        if abs(n) >= d:
            return f"{n/d:.2f}{u}"
    return str(int(n))

def short(slug, cwd):
    if cwd:
        base = cwd.rstrip("/\\").replace("\\", "/").split("/")[-1]
        if base:
            return base
    # 홈/dev 접두어(-Users-<user>-dev- / -home-<user>- / C--Users-<user>-)를 일반적으로 제거
    m = re.match(r"^-(?:Users|home)-[^-]+-dev-(.+)$", slug) or \
        re.match(r"^-(?:Users|home)-[^-]+-(.+)$", slug) or \
        re.match(r"^[A-Za-z]--Users-[^-]+-(.+)$", slug)
    return m.group(1) if m else slug

def main():
    if "--local" in sys.argv:
        print(json.dumps(local_scan(), ensure_ascii=True))
        return

    hosts_path = os.environ.get("SMON_TOKEN_HOSTS",
                                os.path.expanduser("~/.config/smon/token-hosts.tsv"))
    rules_path = os.environ.get("SMON_TOKEN_RULES",
                                os.path.expanduser("~/.config/smon/token-rules.tsv"))
    hosts = load_hosts(hosts_path)
    rules = load_rules(rules_path)

    csv_path = None
    if "--csv" in sys.argv:
        i = sys.argv.index("--csv")
        if i + 1 < len(sys.argv):
            csv_path = sys.argv[i + 1]
    if csv_path is None:
        outdir = os.path.expanduser("~/.local/share/smon")
        os.makedirs(outdir, exist_ok=True)
        csv_path = os.path.join(outdir, f"token-usage-{datetime.date.today():%Y%m%d}.csv")

    src = open(os.path.abspath(__file__), encoding="utf-8").read()
    rows = []       # (host, slug, cwd, cat, sub, note, metrics)
    missed = []
    for host, pycmd in hosts:
        if pycmd == "local":
            data = local_scan()
        else:
            sys.stderr.write(f"  … {host} 수집\n")
            data, err = scan_remote(host, pycmd, src)
            if data is None:
                missed.append((host, err)); continue
        seen = set()
        for slug, a in data["projects"].items():
            tot = a["in"] + a["out"] + a["cc"] + a["cr"]
            if tot == 0:
                continue
            key = (a["in"], a["out"], a["cc"], a["cr"], a["msgs"])
            if key in seen:      # 동일 내용 중복 슬러그(경로 이동 등) 제거
                continue
            seen.add(key)
            cat, sub, note = classify(host, slug, a.get("cwd", ""), rules)
            rows.append((host, slug, a.get("cwd", ""), cat, sub, note, a, tot))

    # ---- CSV (손실 없음: 기계×프로젝트 원자료) ----
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["host", "category", "subcategory", "project", "cwd",
                    "total", "input", "output", "cache_creation", "cache_read",
                    "messages", "files", "note"])
        for host, slug, cwd, cat, sub, note, a, tot in sorted(rows, key=lambda r: -r[7]):
            w.writerow([host, cat, sub, short(slug, cwd), cwd, tot,
                        a["in"], a["out"], a["cc"], a["cr"], a["msgs"], a["files"], note])

    # ---- 요약 테이블 ----
    by_host = {}; by_cat = {}; by_sub = {}; grand = 0
    for host, slug, cwd, cat, sub, note, a, tot in rows:
        grand += tot
        by_host.setdefault(host, {}).setdefault(cat, 0)
        by_host[host][cat] += tot
        by_host[host]["_"] = by_host[host].get("_", 0) + tot
        by_cat[cat] = by_cat.get(cat, 0) + tot
        by_sub[(cat, sub)] = by_sub.get((cat, sub), 0) + tot

    print(f"■ 기계별 (6대 대상, 중복 제거)  — 총 {hfmt(grand)}")
    print(f"{'기계':<10}{'총토큰':>10}{'개인':>10}{'업무':>10}")
    for host in sorted(by_host, key=lambda h: -by_host[h]["_"]):
        c = by_host[host]
        print(f"{host:<10}{hfmt(c['_']):>10}{hfmt(c.get('개인',0)):>10}{hfmt(c.get('업무',0)):>10}")
    print("\n■ 용도별")
    for cat in sorted(by_cat, key=lambda c: -by_cat[c]):
        print(f"  {cat:<6} {hfmt(by_cat[cat]):>10}  ({by_cat[cat]/grand*100:.1f}%)")
    print("\n■ 개인 세부")
    for (cat, sub), v in sorted(by_sub.items(), key=lambda x: -x[1]):
        if cat == "개인":
            print(f"  {sub:<22} {hfmt(v):>10}")
    if missed:
        print("\n■ 수집 실패(오프라인 등)")
        for host, err in missed:
            print(f"  {host}: {err}")
    print(f"\nCSV(손실없음) → {csv_path}")

if __name__ == "__main__":
    main()
