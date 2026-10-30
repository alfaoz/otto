"""Adds a release to site/releases.json and writes site/appcast.xml from it (newest first, the last 20).
release.sh signs the feed afterwards with otto's EdDSA key, so this writes it whole every time.
Usage: python3 tools/appcast.py <site dir> <version> <length> <ed signature> [notes file]
Notes: one change per line."""
import datetime, html, json, os, sys

site, version, length, signature = sys.argv[1:5]
notes_file = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
BASE = "https://otto.alfaoz.dev"
MIN_OS = "26.0"

path = os.path.join(site, "releases.json")
releases = json.load(open(path)) if os.path.exists(path) else []
if any(r["version"] == version for r in releases):
    sys.exit(f"{version} is in releases.json already")
notes = [l.strip().lstrip("-* ").strip() for l in open(notes_file)] if notes_file else []
releases.insert(0, {
    "version": version,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000"),
    "length": int(length),
    "ed_signature": signature,
    "notes": [n for n in notes if n],
})
with open(path, "w") as f:
    json.dump(releases, f, indent=2, ensure_ascii=False)
    f.write("\n")

def item(r):
    notes = "".join(f"<li>{html.escape(n)}</li>" for n in r["notes"])
    desc = f"\n      <description><![CDATA[<ul>{notes}</ul>]]></description>" if notes else ""
    return f"""    <item>
      <title>otto {r["version"]}</title>
      <pubDate>{r["date"]}</pubDate>
      <sparkle:version>{r["version"]}</sparkle:version>
      <sparkle:shortVersionString>{r["version"]}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MIN_OS}</sparkle:minimumSystemVersion>{desc}
      <enclosure url="{BASE}/download/otto-{r["version"]}.dmg" length="{r["length"]}" type="application/octet-stream" sparkle:edSignature="{r["ed_signature"]}"/>
    </item>
"""

with open(os.path.join(site, "appcast.xml"), "w") as f:
    f.write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>otto</title>
    <link>{BASE}/appcast.xml</link>
{"".join(item(r) for r in releases[:20])}  </channel>
</rss>
""")
print(f"appcast: {version} added, {len(releases)} release(s)")
