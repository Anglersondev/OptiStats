#!/usr/bin/env python3
"""Validate bilingual page metadata, structured data, sitemap and local assets."""
import json
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent / "site"
BASE = "https://anglersondev.github.io/OptiStats/"
LANGUAGES = {"en": BASE, "pt-BR": BASE + "pt-br/", "x-default": BASE}


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags = []
        self.structured = []
        self.in_json = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if tag == "script":
            assert attrs.get("type") == "application/ld+json", "No runtime JS needed"
            self.in_json = True

    def handle_data(self, text):
        if self.in_json:
            self.structured.append(json.loads(text))

    def handle_endtag(self, tag):
        if tag == "script":
            self.in_json = False


for lang, relative in [("en", "index.html"), ("pt-BR", "pt-br/index.html")]:
    path = ROOT / relative
    page = Page()
    page.feed(path.read_text())
    assert next(a["lang"] for t, a in page.tags if t == "html") == lang
    assert sum(t == "h1" for t, _ in page.tags) == 1
    links = [a for t, a in page.tags if t == "link"]
    assert next(a["href"] for a in links if a.get("rel") == "canonical") == LANGUAGES[lang]
    assert {a["hreflang"]: a["href"] for a in links if a.get("rel") == "alternate"} == LANGUAGES
    assert any(t == "meta" and a.get("name") == "description" and a.get("content") for t, a in page.tags)
    assert page.structured[0]["softwareVersion"] == "1.0"
    assert page.structured[0]["inLanguage"] == lang
    for tag, attrs in page.tags:
        url = attrs.get("href", attrs.get("src", ""))
        if url and not urlparse(url).scheme and not url.startswith("#"):
            local = (path.parent / url).resolve()
            assert local == ROOT or ROOT in local.parents
            if local.is_dir():
                local /= "index.html"
            assert local.is_file(), f"Missing local target: {url}"

sitemap = ET.parse(ROOT / "sitemap.xml")
assert {el.text for el in sitemap.findall(".//{*}loc")} == {BASE, BASE + "pt-br/"}
size = sum(p.stat().st_size for p in ROOT.rglob("*") if p.is_file())
print(f"Website OK: English + pt-BR, reciprocal hreflang, structured data, local links; {size:,} bytes total")
