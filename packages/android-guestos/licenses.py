#!/usr/bin/env python3
import argparse
import glob
import os
import re
import subprocess
import sys

TEXT_RULES = [
    (re.compile(r'A Bison parser, made by GNU Bison [\d.]+\..{0,800}?As a special exception.{0,660}?version 2\.2 of Bison'),
     'GPL-3.0-or-later WITH Bison-exception-2.2', 'bison-exception'),
    (re.compile(r'Boost Software License|Permission is hereby granted, free of charge, to any person or organization'
                r' obtaining a copy of the software and accompanying documentation covered by this license', re.I),
     'BSL-1.0', None),
    (re.compile(r'(?:This document is licensed under the )?SGI Free Software B License|SGI FREE SOFTWARE LICENSE B', re.I),
     'SGI-B-2.0', None),
    (re.compile(r'Permission to use, copy, modify, distribute, and sell this software and its documentation for any'
                r' purpose is hereby granted', re.I), 'HPND-sell-variant', 'comment'),
    (re.compile(r'Permission is hereby granted, free of charge, to any person obtaining a copy', re.I), 'MIT', None),
    (re.compile(r'Licensed under the MIT License'), 'MIT', None),
    (re.compile(r'(^|\s)License: MIT(\s|$)'), 'MIT', None),
    (re.compile(r'Licensed under the Apache License,? Version 2\.0', re.I), 'Apache-2.0', None),
]
BSD = re.compile(r'Redistribution and use in source and binary forms'
                 r'|licensed under the same 3-clause BSD license(?=.{0,400}?Redistribution and use in source and binary forms)')
BSD3 = re.compile(r'Neither the name|endorse or promote', re.I)
POINTER = re.compile(r'Use of this source code is governed by a BSD-style license that can be found in the LICENSE file\.')
REVIEW = re.compile(r'GNU (Lesser |Library )?General Public|(?-i:\bL?GPL)|public domain|licensed under|under the terms of'
                    r'|permission to use|permission is granted|hereby granted|Mozilla Public|ISC License'
                    r'|governed by a BSD-style license|Creative Commons|Unlicense', re.I)
SPDX = re.compile(r'SPDX-License-Identifier:\s*(.+?)\s*(?:\*/|-->|$)', re.M)
DEPRECATED = [(re.compile(r'\bGPL-2\.0\+'), 'GPL-2.0-or-later'), (re.compile(r'\bGPL-2\.0(?![-+\w.])'), 'GPL-2.0-only')]


def flat(text):
    text = re.sub(r'(?m)^[ \t]*(?:/\*+|\*+/|\*+|//+|#+)?[ \t]?', '', text)
    return re.sub(r'\s+', ' ', text)


def run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def leading_comment(path, rule):
    with open(path, errors='replace') as f:
        head = f.read(16384)
    m = re.match(r'\s*((?://[^\n]*\n)+)', head)
    if m:
        text = '\n'.join(re.sub(r'^\s*// ?', '', line) for line in m.group(1).splitlines()).strip() + '\n'
    else:
        m = re.search(r'/\*.*?\*/', head, re.S)
        if not m:
            sys.exit(f'licenses.py: no leading comment in {path}')
        text = '\n'.join(re.sub(r'^\s*\*? ?', '', line) for line in m.group(0)[2:-2].splitlines()).strip() + '\n'
    if not rule.search(flat(text)):
        sys.exit(f'licenses.py: the leading comment of {path} lacks the wording of its license')
    return text


class Inventory:
    def __init__(self, ndk, top, extra):
        self.ndk = os.path.realpath(ndk)
        self.top = top
        self.mesa = self.one('mesa-*')
        self.libdrm = self.one(os.path.join(self.mesa, 'subprojects', 'libdrm-*'))
        self.fossilize = self.one('Fossilize-*')
        self.rapidjson = self.one('rapidjson-*')
        lic = os.path.join(self.mesa, 'licenses')
        self.claims = {
            os.path.join(self.mesa, 'src/gallium/drivers/zink/zink_program.h'):
                [re.compile(r'TODO: is sample shading even possible to handle with GPL\?')],
            os.path.join(self.mesa, 'src/util/fast_idiv_by_const.c'):
                [re.compile(r'Any copyright is dedicated to the Public Domain\.')],
            os.path.join(self.mesa, 'src/util/rand_xor.c'): [re.compile(r'belongs to the public domain\.')],
            os.path.join(self.fossilize, 'miniz/miniz.h'):
                [re.compile(r'miniz\.c [\d.]+ - public domain deflate/inflate, zlib-subset, ZIP reading/writing/appending,'
                            r' PNG writing See "unlicense" statement at the end of this file\.')],
        }
        self.vendored = [
            (os.path.join(self.mesa, 'src/util/blake3'),
             'CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception',
             os.path.join(self.mesa, 'src/util/blake3/README'), []),
            self.license_file(os.path.join(self.mesa, 'src/vulkan/runtime/radix_sort'), pointer=[POINTER]),
            self.license_file(os.path.join(self.mesa, 'include/android_stub'),
                              os.path.join(self.mesa, 'include/android_stub/system/graphics.h')),
            self.license_file(os.path.join(self.fossilize, 'miniz')),
        ] + [self.license_file(os.path.realpath(os.path.join(top, f)), os.path.realpath(t), [POINTER]) for f, t in extra]
        self.roots = [
            (self.libdrm, 'MIT', None),
            (self.mesa, 'MIT', None),
            (self.fossilize, 'MIT', os.path.join(self.fossilize, 'LICENSE')),
            (self.rapidjson, 'MIT', os.path.join(self.rapidjson, 'license.txt')),
        ]
        self.texts = {
            'MIT': [os.path.join(lic, 'MIT')],
            'Apache-2.0': [os.path.join(lic, 'Apache-2.0')],
            'BSL-1.0': [os.path.join(lic, 'BSL-1.0')],
            'SGI-B-2.0': [os.path.join(lic, 'SGI-B-2.0')],
            'GPL-2.0-only': [os.path.join(lic, 'GPL-2.0-only')],
            'Linux-syscall-note': [os.path.join(lic, 'exceptions/Linux-Syscall-Note')],
            'GPL-3.0-or-later': ['/usr/share/licenses/bison/COPYING'],
            'LLVM-exception': [os.path.join(self.ndk_tool(), 'NOTICE')],
            'LicenseRef-NDK-sysroot': [os.path.join(self.ndk_tool(), 'sysroot/NOTICE')],
        }
        self.notices = {}
        self.cache = {}

    def one(self, pattern):
        found = glob.glob(os.path.join(self.top, pattern))
        if len(found) != 1:
            sys.exit(f'licenses.py: {pattern} matches {found}')
        return os.path.realpath(found[0])

    def license_file(self, prefix, source=None, pointer=()):
        source = source or os.path.join(prefix, 'LICENSE')
        expr, _ = self.classify_text(source)
        if not expr:
            sys.exit(f'licenses.py: no license in {source}')
        return prefix, expr, source, list(pointer)

    def ndk_tool(self):
        return os.path.join(self.ndk, 'toolchains/llvm/prebuilt/linux-x86_64')

    def notice(self, expr, source):
        if source[0] == 'bison-exception':
            self.notices.setdefault('Bison-exception-2.2', []).append(source)
            return
        for part in re.split(r' AND | OR | WITH ', expr):
            if part in ('MIT', 'BSD-2-Clause', 'BSD-3-Clause', 'HPND-sell-variant'):
                self.notices.setdefault(part, []).append(source)

    def classify_text(self, path, claims=()):
        with open(path, errors='replace') as f:
            head = f.read(16384)
        m = SPDX.search(head)
        if m:
            expr = m.group(1).strip()
            for old, new in DEPRECATED:
                expr = old.sub(new, expr)
            return expr, []
        text = flat(head)
        found, sources = set(), []
        spans = [m.span() for rule in claims for m in rule.finditer(text)]
        for rule, expr, kind in TEXT_RULES:
            hits = [m.span() for m in rule.finditer(text)]
            if not hits:
                continue
            spans += hits
            if expr:
                found.add(expr)
            if kind:
                sources.append((expr, (kind, path, rule)))
        hits = [m.span() for m in BSD.finditer(text)]
        if hits:
            spans += hits
            expr = 'BSD-3-Clause' if BSD3.search(text) else 'BSD-2-Clause'
            found.add(expr)
            sources.append((expr, ('comment', path, BSD)))
        for m in REVIEW.finditer(text):
            if not any(s <= m.start() and m.end() <= e for s, e in spans):
                sys.exit(f'licenses.py: {path} states "{m.group(0)}" outside the wording of every license it matched')
        if not found:
            return None, []
        return ' AND '.join(sorted(found)), sources

    def classify_source(self, path):
        if path.startswith(self.ndk + '/'):
            rel = os.path.relpath(path, self.ndk_tool())
            if rel.startswith('sysroot/usr/include/c++/') or rel.startswith('lib/clang/'):
                return {'Apache-2.0 WITH LLVM-exception'}
            if rel.startswith('sysroot/'):
                return {'LicenseRef-NDK-sysroot'}
            sys.exit(f'licenses.py: {path} is an NDK file outside the sysroot and clang headers')
        with open(path, errors='replace') as f:
            spdx = SPDX.search(f.read(16384))
        claims = self.claims.get(path, [])
        for prefix, expr, source, pointer in self.vendored:
            if (path == prefix or path.startswith(prefix + '/')) and not spdx:
                found, _ = self.classify_text(path, claims + pointer)
                if found and not set(found.split(' AND ')) <= set(re.split(r' OR | AND ', expr)):
                    sys.exit(f'licenses.py: {path} states {found}, which is not part of {expr} of {prefix}')
                self.notice(expr, ('file', source))
                return {expr}
        root = next(((p, e, s) for p, e, s in self.roots if path.startswith(p + '/')), None)
        if not root:
            sys.exit(f'licenses.py: {path} is outside every source tree')
        expr, sources = self.classify_text(path, claims)
        if not expr:
            expr = root[1]
        for e, src in sources:
            self.notice(e, src)
        if root[2] and root[1] in re.split(r' AND | OR | WITH ', expr.replace('(', '').replace(')', '')):
            self.notice(root[1], ('file', root[2]))
        return {expr}

    def generated(self, bdir, rel, seen):
        out = run(['ninja', '-C', bdir, '-t', 'query', rel])
        inputs, state = [], None
        for line in out.splitlines()[1:]:
            s = line.strip()
            if line.startswith('  input:'):
                state = 'in'
                continue
            if line.startswith('  ') and not line.startswith('    '):
                state = None
                continue
            if state == 'in' and not s.startswith('||'):
                inputs.append(s.lstrip('| ').strip())
        exprs = set()
        own, sources = self.classify_text(os.path.join(bdir, rel))
        if own:
            exprs.add(own)
        for e, src in sources:
            self.notice(e, src)
        for i in inputs:
            p = os.path.normpath(os.path.join(bdir, i))
            if i.startswith('/usr/') or not os.path.isfile(p):
                continue
            exprs |= self.classify(bdir, p, seen)
        if not exprs:
            owner = self.libdrm if rel.startswith('subprojects/libdrm-') else (
                self.fossilize if bdir.endswith('build-fossilize') else self.mesa)
            exprs.add('MIT')
            for prefix, expr, src in self.roots:
                if prefix == owner and src:
                    self.notice(expr, ('file', src))
        return exprs

    def classify(self, bdir, path, seen=()):
        if path in self.cache:
            return self.cache[path]
        if path in seen:
            return set()
        if path.startswith(bdir + '/'):
            exprs = self.generated(bdir, os.path.relpath(path, bdir), set(seen) | {path})
        else:
            exprs = self.classify_source(path)
        self.cache[path] = exprs
        return exprs

    def compiled(self, target):
        bdir, rel = target.split('/', 1)
        bdir = os.path.realpath(bdir)
        objs = [i for i in run(['ninja', '-C', bdir, '-t', 'inputs', rel]).split() if i.endswith('.o')]
        if not objs:
            sys.exit(f'licenses.py: no objects for {target}')
        files, valid = set(), 0
        for line in run(['ninja', '-C', bdir, '-t', 'deps', *objs]).splitlines():
            if not line.strip():
                continue
            if not line.startswith(' '):
                if '(VALID)' not in line:
                    sys.exit(f'licenses.py: {line}')
                valid += 1
                continue
            files.add(os.path.normpath(os.path.join(bdir, line.strip())))
        if valid != len(objs):
            sys.exit(f'licenses.py: {valid} of {len(objs)} objects of {target} have deps')
        return bdir, files

    def runtime(self, clangxx):
        out = subprocess.run([clangxx, '-###', '-shared', '-static-libstdc++', '-o', '/dev/null', '-x', 'c++', '/dev/null'],
                             capture_output=True, text=True).stderr
        link = [line for line in out.splitlines() if 'ld.lld' in line]
        if len(link) != 1:
            sys.exit('licenses.py: no ld.lld line from the NDK driver')
        args = re.findall(r'"([^"]*)"', link[0])
        dirs = [a[2:] for a in args if a.startswith('-L')]
        found, objects = set(), set()

        def lookup(name):
            for d in dirs:
                if os.path.isfile(os.path.join(d, name)):
                    return os.path.join(d, name)
            sys.exit(f'licenses.py: {name} not found in {dirs}')

        def add(path):
            with open(path, 'rb') as f:
                if f.read(7) == b'!<arch>':
                    found.add(os.path.realpath(path))
                    return
            m = re.search(r'(?:INPUT|GROUP)\s*\(([^)]*)\)', open(path, errors='replace').read())
            if not m:
                sys.exit(f'licenses.py: {path} is neither an archive nor a linker script')
            for item in m.group(1).split():
                add(lookup('lib' + item[2:] + '.a') if item.startswith('-l') else item)

        static = False
        for a in args:
            if a in ('-Bstatic', '-Bdynamic'):
                static = a == '-Bstatic'
            elif a.startswith('-l:'):
                if a.endswith('.a'):
                    add(lookup(a[3:]))
            elif a.startswith('-l'):
                if static:
                    add(lookup('lib' + a[2:] + '.a'))
            elif a.endswith('.a'):
                add(a)
            elif a.endswith('.o') and os.path.realpath(a).startswith(self.ndk + '/'):
                objects.add(os.path.realpath(a))
        return sorted(found), sorted(objects)

    def label(self, path):
        for base, name in ((self.top, ''), (self.ndk, os.path.basename(self.ndk) + '/')):
            if path.startswith(base + '/'):
                return name + os.path.relpath(path, base)
        return path if path.startswith('/usr/') else os.path.basename(path)


def atoms(expr):
    return [a.strip().strip('()') for a in re.split(r' AND (?![^(]*\))', expr)]


def conjunction(exprs):
    parts = {a for e in exprs for a in atoms(e)}
    return ' AND '.join(sorted(f'({a})' if ' OR ' in a and len(parts) > 1 else a for a in parts))


def simple(atom):
    return [p.strip('() ') for p in re.split(r' OR | WITH ', atom)]


def write_text(out, ident, sources, inv):
    parts = []
    for s in sources:
        if isinstance(s, tuple) and s[0] == 'bison-exception':
            m = re.search(r'As a special exception, you may create.*?version 2\.2 of Bison\.', open(s[1]).read(), re.S)
            if not m:
                sys.exit(f'licenses.py: no Bison exception in {s[1]}')
            parts.append(('GNU Bison 3.8 skeleton', '\n'.join(line.strip() for line in m.group(0).splitlines()) + '\n'))
        elif isinstance(s, tuple) and s[0] == 'comment':
            parts.append((inv.label(s[1]), leading_comment(s[1], s[2])))
        else:
            path = s[1] if isinstance(s, tuple) else s
            parts.append((inv.label(path), open(path, errors='replace').read()))
    seen, body = set(), []
    for label, text in parts:
        if text in seen:
            continue
        seen.add(text)
        body.append(f'---- {label} ----\n\n{text.rstrip()}\n')
    with open(os.path.join(out, 'LICENSES', ident + '.txt'), 'w') as f:
        f.write('\n'.join(body))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ndk', required=True)
    ap.add_argument('--clangxx', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--license', action='append', default=[], metavar='FILE=LICENSE')
    ap.add_argument('targets', nargs='+')
    a = ap.parse_args()
    inv = Inventory(a.ndk, os.getcwd(), [x.split('=', 1) for x in a.license])
    rows = {}
    for t in a.targets:
        bdir, files = inv.compiled(t)
        for f in sorted(files):
            rows[inv.label(f)] = conjunction(inv.classify(bdir, f))
    archives, objects = inv.runtime(a.clangxx)
    for ar in archives:
        rows[inv.label(ar)] = 'Apache-2.0 WITH LLVM-exception'
    for obj in objects:
        rows[inv.label(obj)] = conjunction(inv.classify_source(obj))
    tag = sorted({x if ' OR ' not in x else f'({x})' for e in rows.values() for x in atoms(e)})
    needed = {}
    for atom in tag:
        alts = [p for p in re.split(r' OR ', atom.strip('()'))]
        usable = [alt for alt in alts if all(i in inv.texts or i in inv.notices for i in simple(alt))]
        if not usable:
            sys.exit(f'licenses.py: no text for {atom}')
        for i in simple(usable[0]):
            needed[i] = inv.texts.get(i, []) + inv.notices.get(i, [])
    os.makedirs(os.path.join(a.out, 'LICENSES'), exist_ok=True)
    for ident, sources in sorted(needed.items()):
        write_text(a.out, ident, sources, inv)
    with open(os.path.join(a.out, 'SOURCES.tsv'), 'w') as f:
        for path, expr in sorted(rows.items()):
            f.write(f'{expr}\t{path}\n')
    print(' AND '.join(tag))


main()
