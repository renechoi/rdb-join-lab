#!/usr/bin/env python3
"""Corpus study for the rdb-join measurement paper.

Question: where do the measured degradation thresholds land relative to code that
people actually ship?

Design constraint: never keep a repository on disk. Each repository is fetched as a
tarball, streamed into a temporary directory, analysed, and deleted before the next
one starts. Peak disk use is one repository.

Outputs one JSON object per repository to corpus/data/repos.jsonl (append-only, so
the run is resumable: repositories already present are skipped).
"""
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
REPOS_JSONL = os.path.join(OUT_DIR, "repos.jsonl")
FRAME_JSON = os.path.join(OUT_DIR, "frame.json")

TOKEN = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.github+json",
    "User-Agent": "rdb-join-corpus",
}


def api(path, params=None, accept=None, raw=False):
    url = "https://api.github.com" + path
    if params:
        from urllib.parse import urlencode
        url += "?" + urlencode(params)
    req = urllib.request.Request(url, headers=dict(HEADERS))
    if accept:
        req.add_header("Accept", accept)
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read() if raw else json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):
                # secondary rate limit or search throttle
                wait = int(e.headers.get("Retry-After", 0)) or (20 * (attempt + 1))
                sys.stderr.write(f"  throttled ({e.code}), sleeping {wait}s\n")
                time.sleep(wait)
                continue
            if e.code in (404, 451, 409):
                return None
            raise
        except Exception as e:
            sys.stderr.write(f"  transient {type(e).__name__}, retry\n")
            time.sleep(5 * (attempt + 1))
    return None


# --------------------------------------------------------------------------- frame

# Stratified so that the 1000-result cap of any single code-search query does not
# define the sample. Each stratum is a different build file and a different size band.
SEARCH_QUERIES = [
    'spring-boot-starter-data-jpa filename:pom.xml',
    'spring-boot-starter-data-jpa filename:build.gradle',
    'spring-boot-starter-data-jpa filename:build.gradle.kts',
    'hibernate-core filename:pom.xml',
    'spring-boot-starter-data-jpa filename:pom.xml size:>4000',
    'spring-boot-starter-data-jpa filename:build.gradle size:>2000',
]


def build_frame(target):
    seen = {}
    for q in SEARCH_QUERIES:
        page = 1
        while len(seen) < target and page <= 10:
            res = api("/search/code", {"q": q, "per_page": 100, "page": page})
            if not res or not res.get("items"):
                break
            for it in res["items"]:
                r = it["repository"]
                if r["full_name"] not in seen:
                    seen[r["full_name"]] = {
                        "full_name": r["full_name"],
                        "fork": r.get("fork", False),
                        "query": q,
                    }
            page += 1
            time.sleep(7)  # code search is 10 req/min
        sys.stderr.write(f"frame after {q!r}: {len(seen)}\n")
        if len(seen) >= target:
            break
    return list(seen.values())


# ------------------------------------------------------------------------ analysis

ENTITY_RE = re.compile(r"@Entity\b")
ASSOC_RE = {
    "many_to_one": re.compile(r"@ManyToOne\b"),
    "one_to_many": re.compile(r"@OneToMany\b"),
    "many_to_many": re.compile(r"@ManyToMany\b"),
    "one_to_one": re.compile(r"@OneToOne\b"),
}
# a plain identifier reference field inside an entity: "private Long authorId;"
IDREF_RE = re.compile(r"\bprivate\s+(?:Long|Integer|UUID|String)\s+\w*[Ii]d\s*;")
LAZY_RE = re.compile(r"FetchType\.LAZY")
JOINFETCH_RE = re.compile(r"(?i)join\s+fetch\b")
ENTITYGRAPH_RE = re.compile(r"@EntityGraph\b")

# iteration constructs whose body we scan for a repository call
LOOP_HEAD_RE = re.compile(r"\b(for\s*\(|while\s*\(|\.forEach\s*\(|\.stream\s*\(\s*\)\s*\.map\s*\(|\.map\s*\()")
REPO_CALL_RE = re.compile(r"\.(find(?:ById|One|All)?[A-Za-z]*|get(?:ById|One)[A-Za-z]*|query[A-Za-z]*|select[A-Za-z]*)\s*\(")

BATCH_FETCH_RE = re.compile(r"default[_-]batch[_-]fetch[_-]size")
AUTOCOMMIT_OFF_RE = re.compile(r"auto[-_]commit\s*[:=]\s*false")
PROVIDER_DISABLES_RE = re.compile(r"provider_disables_autocommit")
BATCH_SIZE_VAL_RE = re.compile(r"default[_-]batch[_-]fetch[_-]size\s*[:=]\s*[\"']?(\d+)")

PAGEABLE_DEFAULT_RE = re.compile(r"@PageableDefault\s*\([^)]*size\s*=\s*(\d+)")
PAGEREQUEST_RE = re.compile(r"PageRequest\.of\s*\(\s*\w+\s*,\s*(\d+)")
MAXRESULTS_RE = re.compile(r"setMaxResults\s*\(\s*(\d+)\s*\)")
DEFAULT_PAGE_SIZE_RE = re.compile(r"default-page-size\s*[:=]\s*(\d+)")

# Repository methods that return a collection with no Pageable and no limit are the
# sites where the result-set size is not chosen by the developer at all. Those, not
# the paginated endpoints, are where N is free to grow past the measured cliff.
REPO_IFACE_RE = re.compile(r"interface\s+\w+\s+extends\s+[\w<>,\s\.]*Repository\b")
LIST_METHOD_RE = re.compile(r"\b(?:List|Set|Collection|Stream)\s*<[^>]+>\s+(\w+)\s*\(([^)]*)\)\s*;")
PAGEABLE_PARAM_RE = re.compile(r"\bPageable\b|\bLimit\b|\bTop\d+\b|\bFirst\d+\b")
FINDALL_CALL_RE = re.compile(r"\.findAll\s*\(\s*\)")

JAVA_EXT = (".java",)
CONF_EXT = (".yml", ".yaml", ".properties")


def loop_body_repo_calls(src):
    """Count repository-style invocations that occur inside an iteration construct.

    Brace-matched scan from each loop head. This over-approximates the N+1 shape
    (a repository call may be guarded, cached, or hit a collection already loaded),
    so the number is reported as an upper bound and a random subsample is validated
    by hand. It is a syntactic signal, not a semantic verdict.
    """
    hits = 0
    sites = []
    for m in LOOP_HEAD_RE.finditer(src):
        # find the block that follows: skip to the first '{' after the loop head
        i = src.find("{", m.end() - 1)
        if i == -1 or i - m.end() > 400:
            continue
        depth = 0
        j = i
        n = len(src)
        while j < n:
            c = src[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
            if j - i > 8000:  # runaway guard
                break
        body = src[i:j]
        found = REPO_CALL_RE.findall(body)
        if found:
            hits += len(found)
            line = src.count("\n", 0, m.start()) + 1
            sites.append({"line": line, "calls": found[:3]})
    return hits, sites[:5]


def analyse_tree(root):
    r = {
        "java_files": 0, "entity_files": 0, "entity_annotations": 0,
        "many_to_one": 0, "one_to_many": 0, "many_to_many": 0, "one_to_one": 0,
        "idref_fields_in_entities": 0,
        "lazy": 0, "join_fetch": 0, "entity_graph": 0,
        "loop_repo_calls": 0, "loop_repo_sites": [],
        "has_batch_fetch_size": False, "batch_fetch_size_values": [],
        "has_autocommit_false": False, "has_provider_disables_autocommit": False,
        "page_sizes": [], "conf_files": 0,
        "repo_interfaces": 0, "unbounded_list_methods": 0, "bounded_list_methods": 0,
        "findall_noarg_calls": 0,
    }
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", "build", "target", ".gradle")]
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            try:
                if fn.endswith(JAVA_EXT):
                    if os.path.getsize(fp) > 2_000_000:
                        continue
                    src = io.open(fp, encoding="utf-8", errors="replace").read()
                    r["java_files"] += 1
                    ents = len(ENTITY_RE.findall(src))
                    if ents:
                        r["entity_files"] += 1
                        r["entity_annotations"] += ents
                        r["idref_fields_in_entities"] += len(IDREF_RE.findall(src))
                        for k, rx in ASSOC_RE.items():
                            r[k] += len(rx.findall(src))
                    r["lazy"] += len(LAZY_RE.findall(src))
                    r["join_fetch"] += len(JOINFETCH_RE.findall(src))
                    r["entity_graph"] += len(ENTITYGRAPH_RE.findall(src))
                    if REPO_IFACE_RE.search(src):
                        r["repo_interfaces"] += len(REPO_IFACE_RE.findall(src))
                        for name, params in LIST_METHOD_RE.findall(src):
                            if PAGEABLE_PARAM_RE.search(params) or PAGEABLE_PARAM_RE.search(name):
                                r["bounded_list_methods"] += 1
                            else:
                                r["unbounded_list_methods"] += 1
                    r["findall_noarg_calls"] += len(FINDALL_CALL_RE.findall(src))
                    c, sites = loop_body_repo_calls(src)
                    r["loop_repo_calls"] += c
                    if sites and len(r["loop_repo_sites"]) < 5:
                        rel = os.path.relpath(fp, root)
                        for s in sites[: 5 - len(r["loop_repo_sites"])]:
                            r["loop_repo_sites"].append({"file": rel, **s})
                    for rx, key in ((PAGEABLE_DEFAULT_RE, None), (PAGEREQUEST_RE, None), (MAXRESULTS_RE, None)):
                        for v in rx.findall(src):
                            try:
                                r["page_sizes"].append(int(v))
                            except ValueError:
                                pass
                elif fn.endswith(CONF_EXT):
                    if os.path.getsize(fp) > 500_000:
                        continue
                    src = io.open(fp, encoding="utf-8", errors="replace").read()
                    r["conf_files"] += 1
                    if BATCH_FETCH_RE.search(src):
                        r["has_batch_fetch_size"] = True
                        r["batch_fetch_size_values"] += [int(v) for v in BATCH_SIZE_VAL_RE.findall(src)]
                    if AUTOCOMMIT_OFF_RE.search(src):
                        r["has_autocommit_false"] = True
                    if PROVIDER_DISABLES_RE.search(src):
                        r["has_provider_disables_autocommit"] = True
                    for v in DEFAULT_PAGE_SIZE_RE.findall(src):
                        r["page_sizes"].append(int(v))
            except Exception:
                continue
    r["page_sizes"] = r["page_sizes"][:400]
    return r


def process(full_name):
    meta = api(f"/repos/{full_name}")
    if not meta or meta.get("archived"):
        return None
    rec = {
        "full_name": full_name,
        "stars": meta.get("stargazers_count", 0),
        "size_kb": meta.get("size", 0),
        "pushed_at": meta.get("pushed_at"),
        "fork": meta.get("fork", False),
        "language": meta.get("language"),
        "default_branch": meta.get("default_branch"),
    }
    if rec["size_kb"] > 300_000:  # 300 MB, skip monsters
        rec["skipped"] = "too_large"
        return rec
    blob = api(f"/repos/{full_name}/tarball/{rec['default_branch']}", raw=True)
    if not blob:
        rec["skipped"] = "tarball_unavailable"
        return rec
    tmp = tempfile.mkdtemp(prefix="corpus-")
    try:
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
            members = [
                m for m in tf.getmembers()
                if m.isfile() and m.name.endswith(JAVA_EXT + CONF_EXT) and m.size < 2_000_000
            ]
            for m in members:
                m.name = m.name.replace("..", "_")
            tf.extractall(tmp, members=members)
        rec.update(analyse_tree(tmp))
    except Exception as e:
        rec["skipped"] = f"extract_error:{type(e).__name__}"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return rec


def main():
    target = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    os.makedirs(OUT_DIR, exist_ok=True)

    if os.path.exists(FRAME_JSON):
        frame = json.load(open(FRAME_JSON))
    else:
        frame = build_frame(target * 2)
        json.dump(frame, open(FRAME_JSON, "w"), indent=1)
    sys.stderr.write(f"frame size: {len(frame)}\n")

    done = set()
    if os.path.exists(REPOS_JSONL):
        for line in io.open(REPOS_JSONL, encoding="utf-8"):
            try:
                done.add(json.loads(line)["full_name"])
            except Exception:
                pass
    sys.stderr.write(f"already done: {len(done)}\n")

    out = io.open(REPOS_JSONL, "a", encoding="utf-8")
    n = len(done)
    for f in frame:
        if n >= target:
            break
        fn = f["full_name"]
        if fn in done or f.get("fork"):
            continue
        try:
            rec = process(fn)
        except Exception as e:
            sys.stderr.write(f"  {fn}: hard error {type(e).__name__}\n")
            continue
        if rec is None:
            continue
        rec["frame_query"] = f["query"]
        out.write(json.dumps(rec, ensure_ascii=False) + "\n")
        out.flush()
        n += 1
        sys.stderr.write(f"[{n}/{target}] {fn} java={rec.get('java_files',0)} ent={rec.get('entity_files',0)} loopcalls={rec.get('loop_repo_calls',0)} batch={rec.get('has_batch_fetch_size')}\n")
    out.close()
    sys.stderr.write("done\n")


if __name__ == "__main__":
    main()
