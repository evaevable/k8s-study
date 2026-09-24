#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把对话讲义形态的 chapters/*.md 机械转换成书稿形态。"""
import re, sys, pathlib

# 每章保留的引用块（按原始行号），其余全部降级为正文
KEEP = {
    '01-why-k8s.md': {182, 215},
    '02-pod.md': {63, 275},
    '03-cluster-anatomy.md': {245, 468},
    '04-declarative-controller.md': {124, 336},
    '05-deployment.md': {48, 217, 478},
    '06-service-network.md': {58, 397},
    '07-ingress.md': {81, 429},
    '08-configmap-secret.md': {36, 145, 169},
    '09-storage.md': {259, 429},
    '10-scheduling.md': {16, 107, 201},
    '11-self-healing.md': {18, 443},
    '12-autoscaling.md': {86, 138},
    '13-workloads.md': {396, 516},
    '14-capstone.md': {16, 26},
    '15-production.md': {31, 350},
    'appendix-cheatsheet.md': set(),
}

SYMBOLS = ['\u26a0\ufe0f', '\u26a0', '\u2705', '\u274c', '\u2713', '\u2b50', '\u2605']

PHRASES = [
    ('答不上来的，回到对应积木块复习。', ''),
    ('答不上来的，回到对应小节复习。', ''),
    ('本课程', '本书'),
    ('这门课的', '本书的'),
    ('这门课', '本书'),
    ('本仓库', '本书配套仓库'),
    ('这份课程的目标', '本书的目标'),
    ('课程正文结束', '正文到此结束'),
]


def fence_map(lines):
    """返回每行是否处于代码围栏内。"""
    inside, out = False, []
    for l in lines:
        if l.lstrip().startswith('```'):
            out.append(True)      # 围栏行本身视作代码
            inside = not inside
            continue
        out.append(inside)
    return out


def scrub(text):
    for s in SYMBOLS:
        text = text.replace(s, '')
    for a, b in PHRASES:
        text = text.replace(a, b)
    # 积木引用 → 小节编号
    text = re.sub(r'（积木\s*[\d]+-[\d]+(?:[、，,]\s*[\d]+-[\d]+)*）', '', text)
    text = re.sub(r'\(积木\s*[\d]+-[\d]+(?:[、，,]\s*[\d]+-[\d]+)*\)', '', text)
    text = re.sub(r'【积木\s*(\d+)-(\d+)】', lambda m: f'第 {m.group(1)}.{m.group(2)} 节', text)
    text = re.sub(r'积木\s*(\d+)-(\d+)\s*~\s*(\d+)-(\d+)',
                  lambda m: f'第 {m.group(1)}.{m.group(2)}~{m.group(3)}.{m.group(4)} 节', text)
    text = re.sub(r'积木\s*(\d+)-(\d+)', lambda m: f'第 {m.group(1)}.{m.group(2)} 节', text)
    text = text.replace('积木块结构', '小节结构')
    text = text.replace('积木块', '小节')
    text = re.sub(r'(第 \d+\.\d+(?:~\d+\.\d+)? 节) (?=[\u4e00-\u9fff])', r'\1', text)
    text = re.sub(r'[ \t]+$', '', text)
    text = re.sub(r'（\s*）', '', text)
    return text


def process(path):
    p = pathlib.Path(path)
    name = p.name
    raw = p.read_text(encoding='utf-8')
    lines = raw.split('\n')
    infence = fence_map(lines)
    keep = KEEP.get(name, set())

    # ① 截断「下一章预告」及其之后的全部内容
    end = len(lines)
    for i, l in enumerate(lines):
        if infence[i]:
            continue
        if re.match(r'^#{2,4}\s*(【下一章预告】|下一章预告)', l):
            end = i
            break
    lines = lines[:end]
    infence = infence[:end]
    # 去掉尾部悬空的分隔线/空行/对话尾注
    while lines and (lines[-1].strip() in ('', '---') or
                     re.match(r'^\*.*(继续|课程结束|课程正文结束|正文到此结束).*\*$', lines[-1].strip())):
        lines.pop(); infence.pop()

    # ② 统计本章积木编号，算出「本章要点 / 练习题」的小节号
    nums = [int(m.group(2)) for l in lines
            for m in [re.match(r'^##\s*【积木\s*(\d+)-(\d+)】', l)] if m]
    chap = None
    m = re.match(r'^#\s*第\s*(\d+)\s*章', lines[0])
    if m:
        chap = int(m.group(1))
    key_no = f'{chap}.{max(nums)+1}' if nums and chap else None
    ex_no = f'{chap}.{max(nums)+2}' if nums and chap else None

    out = []
    in_block = False
    i = 0
    n = len(lines)
    removed_quotes = 0
    while i < n:
        l = lines[i]
        # ③ 删掉「本章导读」引用块
        if not infence[i] and l.startswith('>') and '本章导读' in l:
            while i < n and lines[i].startswith('>'):
                i += 1
            while i < n and lines[i].strip() == '':
                i += 1
            continue
        # ④ 标题改写
        if not infence[i]:
            mm = re.match(r'^##\s*【积木\s*(\d+)-(\d+)】\s*(.*)$', l)
            if mm:
                in_block = True
                out.append(f'### {mm.group(1)}.{mm.group(2)} {mm.group(3).strip()}')
                i += 1
                continue
            if re.match(r'^##\s*【本章小结】\s*$', l):
                in_block = False
                i += 1
                while i < n and lines[i].strip() == '':
                    i += 1
                continue
            if re.match(r'^###\s*[一二三四五六七八九十]+句话总结\s*$', l) and key_no:
                out.append(f'### {key_no} 本章要点')
                i += 1
                continue
            if re.match(r'^###\s*一张图收尾\s*$', l):
                out.append('#### 本章全景图')
                i += 1
                continue
            if re.match(r'^###\s*自测题\s*$', l) and ex_no:
                out.append(f'### {ex_no} 练习题')
                i += 1
                continue
            if l.startswith('## '):
                in_block = False
            elif in_block and re.match(r'^#{3,5} ', l):
                # 原积木内部的子标题整体下沉一级
                out.append('#' + l)
                i += 1
                continue
        # ⑤ 引用块降级
        if not infence[i] and l.startswith('>'):
            start_lineno = i + 1  # 注意：这是截断后的行号，需换算
            block = []
            j = i
            while j < n and lines[j].startswith('>'):
                block.append(lines[j]); j += 1
            if start_lineno in keep:
                out.extend(block)
            else:
                removed_quotes += 1
                for b in block:
                    stripped = re.sub(r'^>\s?', '', b)
                    out.append(stripped)
            i = j
            continue
        out.append(l)
        i += 1

    text = '\n'.join(out)
    text = scrub(text)
    # 降级后可能出现连续 3 个以上空行
    text = re.sub(r'\n{4,}', '\n\n\n', text)
    if not text.endswith('\n'):
        text += '\n'
    p.write_text(text, encoding='utf-8')
    return name, removed_quotes


if __name__ == '__main__':
    for f in sys.argv[1:]:
        print('%-32s 降级引用块 %d' % process(f))
