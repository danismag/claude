# Инструменты ведущего агента

Код хранится в Markdown, потому что AGENTS.md §2 запрещает скрипты в репозитории. Чтобы запустить, скопируйте блок в файл в своём scratchpad.

## readability.py — проверка читаемости части (AGENTS.md §3.3)

Запуск: `python3 -I readability.py [-v] файл.md …`

```python
#!/usr/bin/env python3
"""Проверка читаемости части по AGENTS.md §3.1, §3.3. usage: readability.py file.md [...]"""
import re, sys
STOP = ["является", "являются", "осуществля", "данный", "данная", "данное",
        "следует отметить", "очень", "производится", "в рамках", "при помощи",
        "в целях", "имеет место", "необходимо отметить"]
EMO = re.compile('[\U0001F300-\U0001FAFF☀-➿\U0001F170-\U0001F1FF⭐]')

def strip_inline(t):
    t = re.sub(r'`[^`]*`', 'X', t)
    t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)
    return re.sub(r'[*_]', '', t)

def sentences(p):
    p = strip_inline(p)
    p = re.sub(r'\b(т\. ?е|т\. ?п|т\. ?д|т\. ?к|и т|др|см|напр|рис|стр|гл)\.', r'\1', p)
    p = re.sub(r'(\d)\.(\d)', r'\1,\2', p)
    return [s for s in re.split(r'(?<=[.!?…])\s+(?=[А-ЯA-Za-z«"(`0-9])', p) if s.strip()]

def words(s): return re.findall(r'[\wА-Яа-яЁё-]+', s)

def check(path):
    L = open(path, encoding='utf-8').read().split('\n')
    out, inc, para, paras = [], False, [], []
    heads, tables, lists, cur_list, quotes = [], [], [], [], []
    theory = True; prev_quote_line = -10; last_kind = None
    total_chars = bold_chars = 0
    def flush():
        nonlocal para
        if para: paras.append((para[0][0], ' '.join(x for _, x in para)))
        para = []
    for i, l in enumerate(L, 1):
        if l.startswith('```'):
            inc = not inc; flush(); last_kind = 'code'; continue
        if inc:
            if len(l) > 100: out.append((i, f'строка кода {len(l)} знаков > 100'))
            continue
        if EMO.search(l): out.append((i, 'значок/эмодзи'))
        m = re.match(r'^(#{1,6}) (.*)', l)
        if m:
            flush()
            lvl = len(m.group(1)); t = m.group(2)
            if t.startswith('Лабораторные работы'): theory = False
            if lvl == 4 and theory: out.append((i, '#### в теории'))
            if last_kind == 'head': out.append((i, 'два заголовка подряд без текста'))
            if heads and lvl > heads[-1][1] + 1: out.append((i, f'пропуск уровня заголовка {heads[-1][1]}→{lvl}'))
            heads.append((i, lvl, t, theory)); last_kind = 'head'; continue
        if not l.strip():
            flush()
            if cur_list: lists.append(cur_list); cur_list = []
            continue
        if l.startswith('|'):
            flush(); tables.append((i, l)); last_kind = 'table'; continue
        if l.startswith('>'):
            flush()
            if i - prev_quote_line == 2 or (last_kind == 'quote' and i - prev_quote_line > 1):
                out.append((i, 'две врезки подряд'))
            prev_quote_line = i; last_kind = 'quote'; continue
        if re.match(r'^\s*([-*]|\d+\.) ', l):
            flush(); cur_list.append((i, l)); last_kind = 'list'
            txt = re.sub(r'^\s*([-*]|\d+\.) ', '', l)
        elif l.lstrip().startswith('<'):
            last_kind = 'html'; continue
        else:
            bare = re.sub(r'[*_]', '', l).strip()
            if len(words(bare)) <= 4 and (bare.endswith(':') or re.fullmatch(r'\*\*[^*]+\*\*\.?', l.strip())):
                flush(); last_kind = 'label'; continue   # служебная подпись: «Результат:», «**Цель.**»
            para.append((i, l)); last_kind = 'text'; txt = l
        total_chars += len(txt)
        bold_chars += sum(len(b) for b in re.findall(r'\*\*([^*]+)\*\*', txt))
        if re.search(r'\*\*\*|\*\*_|_\*\*', txt): out.append((i, 'жирный + курсив'))
        low = txt.lower()
        for w in STOP:
            if re.search(r'(?<![а-яё])' + re.escape(w.strip()), low): out.append((i, f'стоп-слово «{w.strip()}»'))
        for s in sentences(txt):
            if len(re.findall(r'`[^`]+`', s)) > 3: out.append((i, 'больше 3 моноширинных вставок в предложении'))
    flush()
    if cur_list: lists.append(cur_list)
    # предложения и абзацы
    slen = []
    for ln, p in paras:
        ss = sentences(p)
        for s in ss:
            n = len(words(s)); slen.append(n)
            if n > 25: out.append((ln, f'предложение {n} слов: «{s[:60]}…»'))
        if len(ss) > 5: out.append((ln, f'абзац из {len(ss)} предложений'))
    # заголовки: число подразделов в разделе
    for k, (ln, lvl, t, th) in enumerate(heads):
        if lvl == 2 and th:
            subs = 0
            for ln2, lvl2, t2, _ in heads[k+1:]:
                if lvl2 <= 2: break
                if lvl2 == 3: subs += 1
            if subs and not 3 <= subs <= 5: out.append((ln, f'в разделе «{t[:40]}» {subs} подразделов (норма 3–5)'))
    if sum(1 for h in heads if h[1] == 1) != 1: out.append((1, 'не один заголовок #'))
    # списки
    for lst in lists:
        top = [x for x in lst if not x[1].startswith(' ')]
        if len(top) < 2 and lst[0][1].lstrip().startswith(('-','*')): out.append((lst[0][0], 'список из одного пункта'))
        if len(top) > 7: out.append((lst[0][0], f'список из {len(top)} пунктов (норма 3–7)'))
    # таблицы
    for ln, l in tables:
        cells = [c.strip() for c in re.split(r'(?<!\\)\|', l.strip().strip('|'))]
        if len(cells) > 5: out.append((ln, f'таблица {len(cells)} столбцов'))
        if not set(l) <= set('|-: ') and any('`' in c for c in cells[1:]) and len(cells) > 2:
            out.append((ln, 'код в ячейке таблицы (не в первом столбце)'))
        for c in cells:
            if len(words(strip_inline(c))) > 15: out.append((ln, f'ячейка {len(words(c))} слов')); break
    seen = set(); out2 = []
    for ln, msg in sorted(out):
        key = (ln, msg.split(':')[0])
        if key not in seen: seen.add(key); out2.append((ln, msg))
    avg = sum(slen) / len(slen) if slen else 0
    allw = [w for _, p in paras for w in words(strip_inline(p))]
    syl = sum(len(re.findall('[аеёиоуыэюяaeiouy]', w.lower())) or 1 for w in allw)
    fo = 206.836 - 1.3 * avg - 60.1 * (syl / len(allw)) if allw else 0
    short = sum(n < 10 for n in slen)
    bold = 100 * bold_chars / total_chars if total_chars else 0
    print(f'== {path}')
    print(f'   предложений {len(slen)}, средняя длина {avg:.1f} слов (норма 10–15), >25 слов: {sum(n>25 for n in slen)}; '
          f'жирный {bold:.1f}% текста (норма ≤10%)')
    print(f'   короче 10 слов: {100*short/max(len(slen),1):.0f}% предложений; индекс Флеша — Оборневой {fo:.0f} (сигнал, не цель)')
    cats = {}
    for _, m in out2: c = re.sub(r'[\d«].*', '', m).strip(); cats[c] = cats.get(c, 0) + 1
    print('   нарушений:', len(out2), '·', ', '.join(f'{k} {v}' for k, v in sorted(cats.items(), key=lambda x: -x[1])))
    if '-v' in sys.argv:
        for ln, m in out2: print(f'   {ln}: {m}')

for f in [a for a in sys.argv[1:] if a != '-v']: check(f)
```

## plan_row.py — строка в таблице 00-plan.md §7

Запуск: `python3 -I plan_row.py ЧАСТЬ "источник вывода" "что не проверено"`

```python
#!/usr/bin/env python3
"""plan_row.py PART SOURCE UNVERIFIED — вставить/заменить строку в таблице 00-plan.md §7."""
import sys, re
part, src, unv = sys.argv[1:4]
p = '/home/user/claude/kubernetes/00-plan.md'
s = open(p, encoding='utf-8').read()
row = f'| {part} | {src} | kind 0.32.0, k8s 1.36.1 | {unv} |'
lines = s.split('\n')
for i, l in enumerate(lines):
    if l.startswith(f'| {part} |'):
        lines[i] = row; break
else:
    hdr = next(i for i, l in enumerate(lines) if l.startswith('| Часть | Источник вывода'))
    j = hdr + 2
    while lines[j].startswith('|') and lines[j].split('|')[1].strip() < part: j += 1
    lines.insert(j, row)
open(p, 'w', encoding='utf-8').write('\n'.join(lines))
```
