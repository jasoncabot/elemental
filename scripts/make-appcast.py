#!/usr/bin/env python3
"""Write the Sparkle appcast for one release.

Called by .github/workflows/release.yml after the DMG is notarized, stapled and EdDSA-signed. The
feed holds only the newest release: Sparkle needs nothing older, and the feed URL in Info.plist
(…/releases/latest/download/appcast.xml) always serves the latest stable release's copy.

    make-appcast.py --version 0.1.12 --build 0.1.12 \
        --url https://github.com/…/Elemental-0.1.12.dmg --length 1942587 \
        --signature <sign_update -p output> --notes changelog.md \
        --release-page https://github.com/…/releases/tag/v0.1.12 --out appcast.xml

--self-test writes a feed from sample values and checks it parses with every field Sparkle reads.
"""
import argparse
import html
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from email.utils import formatdate
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MIN_MACOS = "15.0"


def markdown_to_html(md: str) -> str:
    """The release changelog is simple generated Markdown: headings, '- ' bullets with
    [text](url) links, **bold**, and plain lines. Convert just that, escaping everything else."""

    def inline(text: str) -> str:
        out, last = [], 0
        for m in re.finditer(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", text):
            out.append(html.escape(text[last:m.start()]))
            out.append(f'<a href="{html.escape(m.group(2), quote=True)}">{html.escape(m.group(1))}</a>')
            last = m.end()
        out.append(html.escape(text[last:]))
        joined = "".join(out)
        return re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", joined)

    parts, in_list = [], False
    for raw in md.splitlines():
        line = raw.rstrip()
        if line.startswith("- "):
            if not in_list:
                parts.append("<ul>")
                in_list = True
            parts.append(f"<li>{inline(line[2:])}</li>")
            continue
        if in_list:
            parts.append("</ul>")
            in_list = False
        if not line:
            continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            level = min(len(heading.group(1)) + 1, 6)  # the item title is the real heading
            parts.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
        else:
            parts.append(f"<p>{inline(line)}</p>")
    if in_list:
        parts.append("</ul>")
    return "\n".join(parts)


def cdata(text: str) -> str:
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def make_appcast(*, version, build, url, length, signature, notes_html, release_page, pub_date):
    a = lambda v: html.escape(str(v), quote=True)  # noqa: E731 — attribute/text escaping
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
  <channel>
    <title>Elemental</title>
    <link>https://github.com/jasoncabot/elemental</link>
    <description>The latest Elemental release.</description>
    <language>en</language>
    <item>
      <title>Elemental {a(version)}</title>
      <pubDate>{a(pub_date)}</pubDate>
      <sparkle:version>{a(build)}</sparkle:version>
      <sparkle:shortVersionString>{a(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MIN_MACOS}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{a(release_page)}</sparkle:fullReleaseNotesLink>
      <description>{cdata(notes_html)}</description>
      <enclosure url="{a(url)}" length="{a(length)}" type="application/octet-stream" sparkle:edSignature="{a(signature)}"/>
    </item>
  </channel>
</rss>
"""


def check(path: Path, expect: dict) -> None:
    """Parse the feed back and assert the fields Sparkle relies on are present and right."""
    item = ET.parse(path).getroot().find("channel/item")
    assert item is not None, "no <item>"
    s = f"{{{SPARKLE_NS}}}"
    assert item.findtext(f"{s}version") == expect["build"], "sparkle:version"
    assert item.findtext(f"{s}shortVersionString") == expect["version"], "sparkle:shortVersionString"
    enc = item.find("enclosure")
    assert enc is not None, "no <enclosure>"
    assert enc.get("url") == expect["url"], "enclosure url"
    assert enc.get("length") == str(expect["length"]), "enclosure length"
    assert enc.get(f"{s}edSignature") == expect["signature"], "edSignature"
    assert int(enc.get("length")) > 0, "empty download"


def self_test() -> None:
    notes = ("## What's Changed\n\n- Fix <b>&</b> things ([abc1234](https://example.com/c/abc))\n\n"
             "**Full Changelog**: https://example.com/compare/v1...v2\n")
    expect = dict(version="0.1.12", build="0.1.12", length=1942587,
                  url="https://github.com/jasoncabot/elemental/releases/download/v0.1.12/Elemental-0.1.12.dmg",
                  signature="c2lnbmF0dXJlLWJ5dGVzLWZvci10ZXN0aW5nLW9ubHk=")
    body = markdown_to_html(notes)
    assert "<li>Fix &lt;b&gt;&amp;&lt;/b&gt; things" in body, body
    assert '<a href="https://example.com/c/abc">abc1234</a>' in body, body
    assert "<strong>Full Changelog</strong>" in body, body
    xml = make_appcast(notes_html=body + "]]>", release_page="https://example.com/r",
                       pub_date=formatdate(usegmt=True), **expect)
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "appcast.xml"
        p.write_text(xml, encoding="utf-8")
        check(p, expect)
    print("make-appcast self-test passed")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--version")
    ap.add_argument("--build")
    ap.add_argument("--url")
    ap.add_argument("--length", type=int)
    ap.add_argument("--signature")
    ap.add_argument("--notes", type=Path, help="Markdown changelog")
    ap.add_argument("--release-page")
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()

    if args.self_test:
        self_test()
        return 0

    required = ["version", "build", "url", "length", "signature", "notes", "release_page", "out"]
    missing = [f"--{r.replace('_', '-')}" for r in required if getattr(args, r) in (None, "")]
    if missing:
        ap.error("missing " + ", ".join(missing))

    expect = dict(version=args.version, build=args.build, url=args.url,
                  length=args.length, signature=args.signature.strip())
    xml = make_appcast(notes_html=markdown_to_html(args.notes.read_text(encoding="utf-8")),
                       release_page=args.release_page, pub_date=formatdate(usegmt=True), **expect)
    args.out.write_text(xml, encoding="utf-8")
    check(args.out, expect)
    print(f"Wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
