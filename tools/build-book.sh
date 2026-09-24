#!/usr/bin/env bash
# 从 chapters/ 重新生成两份目录产物：
#   1. BOOK.md            —— 单文件全书，开头带可点击目录（GitHub 上直接读）
#   2. chapters/SUMMARY.md —— mdBook 的目录文件
# 改动任何章节后重跑本脚本即可。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=/opt/anaconda3/bin/python3

cd "$REPO"
"$PY" - "$REPO" <<'PYCODE'
# -*- coding: utf-8 -*-
import re, sys, pathlib

repo = pathlib.Path(sys.argv[1])
ch = repo / 'chapters'

BOOK_TITLE = '从零讲透 Kubernetes'
BOOK_SUB = '从一次凌晨故障到一套生产级集群'

PARTS = [
    ('第一篇　原理基础', ['01-why-k8s.md', '02-pod.md', '03-cluster-anatomy.md',
                          '04-declarative-controller.md']),
    ('第二篇　部署与网络', ['05-deployment.md', '06-service-network.md', '07-ingress.md']),
    ('第三篇　配置、存储与调度', ['08-configmap-secret.md', '09-storage.md', '10-scheduling.md']),
    ('第四篇　稳定性与弹性', ['11-self-healing.md', '12-autoscaling.md', '13-workloads.md']),
    ('第五篇　实战与生产', ['14-capstone.md', '15-production.md']),
    ('附录', ['appendix-cheatsheet.md']),
]

# mdBook 侧边栏用的短标题。
# 原因：mdBook 会自动给每章编号，正文标题里的「第 N 章」会造成 "1. 第 1 章 …" 的重复，
# 且完整副标题在 300px 宽的侧边栏里要折三行。BOOK.md 的目录仍用完整标题。
SIDEBAR = {
    '01-why-k8s.md': '为什么需要 Kubernetes',
    '02-pod.md': '容器与 Pod',
    '03-cluster-anatomy.md': '集群的解剖学',
    '04-declarative-controller.md': '声明式 API 与控制器模式',
    '05-deployment.md': 'Deployment 与滚动更新',
    '06-service-network.md': 'Service、DNS 与数据面',
    '07-ingress.md': 'Ingress 与南北向流量',
    '08-configmap-secret.md': 'ConfigMap 与 Secret',
    '09-storage.md': 'Volume、PV、PVC 与 StorageClass',
    '10-scheduling.md': '调度与资源管理',
    '11-self-healing.md': '探针与故障恢复',
    '12-autoscaling.md': '弹性伸缩',
    '13-workloads.md': '工作负载全景',
    '14-capstone.md': '实战总演习：CloudNote 从 0 到 1',
    '15-production.md': '生产实践与排错手册',
    'appendix-cheatsheet.md': '附录　命令速查与术语对照',
}


def anchor_chapter(fname):
    """显式锚点 id：不依赖 GitHub 的 slug 推导，避免中文标题与全角空格带来的不确定性。"""
    return 'ch-' + fname.replace('.md', '').replace('.', '-')


def anchor_section(fname, no):
    return 'sec-' + fname[:2] + '-' + no.replace('.', '-')


def split_fences(lines):
    inside, flags = False, []
    for l in lines:
        if l.lstrip().startswith('```'):
            flags.append(True); inside = not inside; continue
        flags.append(inside)
    return flags


def read_chapter(fname):
    """返回 (章标题, 小节列表[(编号, 标题)], 正文行(H1 已剥离))"""
    lines = (ch / fname).read_text(encoding='utf-8').split('\n')
    flags = split_fences(lines)
    title = lines[0].lstrip('# ').strip()
    secs = []
    for i, l in enumerate(lines):
        if flags[i]:
            continue
        m = re.match(r'^###\s+(\d+\.\d+)\s+(.*)$', l)
        if m:
            secs.append((m.group(1), m.group(2).strip()))
    return title, secs, lines[1:], flags[1:]


# ---------- 1) BOOK.md ----------
toc = ['## 目录', '', '- [前言](#preface)']
body = []

preface = (ch / 'preface.md').read_text(encoding='utf-8').split('\n')
body.append('# <a id="preface"></a>前言')
body.extend(preface[1:])

for pi, (part, files) in enumerate(PARTS, 1):
    part_id = f'part-{pi}'
    toc.append(f'- **[{part}](#{part_id})**')
    body.append('')
    body.append('---')
    body.append('')
    body.append(f'# <a id="{part_id}"></a>{part}')
    for f in files:
        title, secs, rest, flags = read_chapter(f)
        cid = anchor_chapter(f)
        toc.append(f'  - [{title}](#{cid})')
        body.append('')
        body.append('---')
        body.append('')
        body.append(f'## <a id="{cid}"></a>{title}')
        for i, l in enumerate(rest):
            m = None if flags[i] else re.match(r'^###\s+(\d+\.\d+)\s+(.*)$', l)
            if m:
                sid = anchor_section(f, m.group(1))
                body.append(f'### <a id="{sid}"></a>{m.group(1)} {m.group(2).strip()}')
            else:
                body.append(l)
        for no, st in secs:
            toc.append(f'    - [{no} {st}](#{anchor_section(f, no)})')

head = [
    f'# {BOOK_TITLE}',
    '',
    f'*{BOOK_SUB}*',
    '',
    '> 本文件由 `tools/build-book.sh` 从 `chapters/` 自动合并生成，请勿直接编辑。',
    '> 需要修改内容请改对应章节文件后重新运行该脚本。',
    '',
]
out = '\n'.join(head + toc + [''] + body)
out = re.sub(r'\n{4,}', '\n\n\n', out).rstrip() + '\n'
(repo / 'BOOK.md').write_text(out, encoding='utf-8')

# ---------- 2) chapters/SUMMARY.md ----------
s = ['# 目录', '', '[前言](preface.md)', '']
for part, files in PARTS:
    if part == '附录':
        # 放在列表之外，mdBook 就不会给它编号（否则会显示成 "16. 附录"）
        s.append('---')
        s.append('')
        for f in files:
            s.append(f'[{SIDEBAR[f]}]({f})')
        s.append('')
        continue
    s.append(f'# {part}')
    s.append('')
    for f in files:
        # mdBook 的 SUMMARY 每章一行（同一文件不可重复出现，故不在此展开小节），
        # 章内小节导航由 theme/pagetoc.js 在页面顶部生成
        s.append(f'- [{SIDEBAR[f]}]({f})')
    s.append('')
(ch / 'SUMMARY.md').write_text('\n'.join(s).rstrip() + '\n', encoding='utf-8')

# ---------- 3) 自检：目录链接与锚点必须一一对应 ----------
txt = (repo / 'BOOK.md').read_text(encoding='utf-8')
ids = set(re.findall(r'<a id="([^"]+)"></a>', txt))
links = re.findall(r'\]\(#([^)]+)\)', txt)

PUNCT = re.compile(r'[!-/:-@\[-`{-~\u00b7\u2010-\u2027\u3001-\u3003\u3008-\u301f'
                   r'\uff01-\uff0f\uff1a-\uff20\uff3b-\uff40\uff5b-\uff65]')


def gh_slug(text):
    """GitHub 标题锚点：转小写 → 去标点 → 空格换连字符（用于校验章内自引用）。"""
    t = re.sub(r'<a id="[^"]+"></a>', '', text).strip().lower()
    t = re.sub(r'`([^`]*)`', r'\1', t)
    t = re.sub(r'\*+', '', t)
    return PUNCT.sub('', t).replace(' ', '-')


slugs = {gh_slug(l.lstrip('#').strip())
         for l in txt.split('\n') if re.match(r'^#{1,6} ', l)}
bad = [l for l in links if l not in ids and l not in slugs]
print(f'BOOK.md            {len(txt.splitlines())} 行，链接 {len(links)} 条，显式锚点 {len(ids)} 个')
print(f'chapters/SUMMARY.md 已生成，收录 {sum(len(f) for _, f in PARTS)} 章 + 前言')
if bad:
    print('链接指向不存在的锚点：', bad)
    sys.exit(1)
print('目录与章内链接自检：全部命中')
PYCODE
