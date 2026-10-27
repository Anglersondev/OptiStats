#!/usr/bin/env python3
"""Verifica que en.lproj e pt-BR.lproj têm os mesmos arquivos e as mesmas chaves, e que toda chave usada em L("...") existe."""
import re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent / "App" / "OptiStats"
res = root / "Resources"
def keys(p): return set(re.findall(r'^\s*"([^"]+)"\s*=', p.read_text(encoding="utf-8"), re.M))
ok = True
en = {p.name: keys(p) for p in (res / "en.lproj").glob("*.strings")}
pt = {p.name: keys(p) for p in (res / "pt-BR.lproj").glob("*.strings")}
for n in sorted(set(en) | set(pt)):
    if n not in en or n not in pt: print("arquivo ausente:", n); ok = False; continue
    for k in sorted(en[n] ^ pt[n]): print(f"{n}: chave sem par: {k}"); ok = False
allk = set().union(*en.values()) if en else set()
used = set()
for f in root.rglob("*.swift"): used |= set(re.findall(r'\bL\("([A-Za-z0-9_.]+)"', f.read_text(encoding="utf-8")))
for k in sorted(used - allk): print("chave usada e não definida:", k); ok = False
print("OK" if ok else "FALHOU"); sys.exit(0 if ok else 1)
