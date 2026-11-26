#!/usr/bin/env python3
"""Convert Adblock Plus / uBlock Origin / AdGuard filter lists into Safari
content-blocker JSON, one file per content-blocker extension.

Handles the parts of the filter syntax that Safari's declarative rules can
express:
  * network rules:   ||ads.example.com^$third-party,script,domain=a.com|~b.com
  * exceptions:      @@||example.com/ads.js   and   @@||site.com^$document
  * element hiding:  ##.ad-banner   example.com##.sponsored   example.com#@#.ad
  * hosts lines:     0.0.0.0 tracker.example.com

Anything else (regex rules, scriptlets, $redirect, $removeparam, extended CSS
such as :has-text(), ...) is skipped and counted in the report. AdGuard's
SafariConverterLib converts more than this script does. Replace this script
with it later if you need better coverage.

Usage:
  tools/build_filters.py                      # uses tools/filters.json, writes dist/
  tools/build_filters.py --seed               # also refreshes the bundled seed lists
  tools/build_filters.py --config tools/fixtures/filters.test.json --out /tmp/out
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import shutil
import subprocess
import sys
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SAFARI_RULE_LIMIT = 150_000
CSS_BATCH = 50  # selectors per css-display-none rule; WebKit silently drops a rule with any invalid selector
PLACEHOLDER_RULE = {"trigger": {"url-filter": "^blocker-placeholder:"}, "action": {"type": "block"}}

ALL_TYPES = ["document", "image", "style-sheet", "script", "font", "svg-document",
             "media", "popup", "ping", "fetch", "websocket", "other"]
TYPE_MAP = {
    "script": ["script"], "image": ["image", "svg-document"], "stylesheet": ["style-sheet"],
    "css": ["style-sheet"], "font": ["font"], "media": ["media"], "object": ["other"],
    "xmlhttprequest": ["fetch"], "xhr": ["fetch"], "websocket": ["websocket"],
    "ping": ["ping"], "beacon": ["ping"], "popup": ["popup"], "other": ["other"],
    "subdocument": ["document"], "frame": ["document"],
}
IGNORED_OPTIONS = {"important", "all", "~important", "_"}
EXTENDED_CSS = re.compile(
    r":(-abp-|has-text|contains|xpath|matches-|upward|remove|style|min-text-length|"
    r"watch-attr|others|nth-ancestor|if|if-not|properties|matches-path|matches-attr)")
OPTION_SYNTAX = re.compile(r"^~?[a-z0-9_-]+(=[^,]*)?(,~?[a-z0-9_-]+(=[^,]*)?)*$", re.I)
HOSTS_LINE = re.compile(r"^(?:0\.0\.0\.0|127\.0\.0\.1|::1?)\s+([A-Za-z0-9.-]+)\s*(?:#.*)?$")
COSMETIC = re.compile(r"^(.*?)(#@?[?$%]?#|\$@?\$)(.*)$")
DOMAIN_RE = re.compile(r"^[a-z0-9.-]+$")


# --------------------------------------------------------------------------- helpers

def is_ascii(s: str) -> bool:
    return all(ord(c) < 128 for c in s)


def safari_domain(d: str) -> str:
    # "*example.com" matches example.com and every subdomain.
    return "*" + d.lower()


def split_domains(text: str, sep: str):
    """Returns (included, excluded) domain lists, or None if unusable."""
    inc, exc = [], []
    for raw in text.split(sep):
        d = raw.strip().lower()
        if not d:
            continue
        neg = d.startswith("~")
        d = d.lstrip("~")
        if "*" in d or not DOMAIN_RE.match(d):
            # TLD wildcards (google.*) and regex domains can't be expressed; drop the entry.
            continue
        (exc if neg else inc).append(d)
    return inc, exc


def pattern_to_regex(p: str) -> str | None:
    if p in ("", "*", "|", "||"):
        return ".*"
    start = end = ""
    if p.startswith("||"):
        start, p = r"^[^:]+://+([^:/]+\.)?", p[2:]
    elif p.startswith("|"):
        start, p = "^", p[1:]
    if p.endswith("|"):
        end, p = "$", p[:-1]
    out = []
    # "||host^": a URL always has "/" or ":port" right after the host, so "[/:]" is exact
    # and far cheaper for WebKit than an optional group anchored with "$".
    host_only = start.startswith("^[^:]") and re.fullmatch(r"[a-z0-9.-]+\^", p, re.I)
    for i, ch in enumerate(p):
        if ch == "*":
            out.append(".*")
        elif ch == "^":
            if host_only:
                out.append("[/:]")
            elif i == len(p) - 1:
                # Separator at the very end: a separator char, or the end of the URL.
                out.append(r"([^a-zA-Z0-9_.%-].*)?$")
                end = ""
            else:
                out.append(r"[^a-zA-Z0-9_.%-]")
        elif ch in ".+?${}()[]\\|":
            out.append("\\" + ch)
        else:
            out.append(ch)
    regex = start + "".join(out) + end
    while ".*.*" in regex:
        regex = regex.replace(".*.*", ".*")
    return regex


def css_looks_valid(sel: str) -> bool:
    if not sel or "{" in sel or "}" in sel or not is_ascii(sel):
        return False
    depth_paren = depth_brack = 0
    quote = None
    for ch in sel:
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
        elif ch == "(":
            depth_paren += 1
        elif ch == ")":
            depth_paren -= 1
        elif ch == "[":
            depth_brack += 1
        elif ch == "]":
            depth_brack -= 1
        if depth_paren < 0 or depth_brack < 0:
            return False
    return quote is None and depth_paren == 0 and depth_brack == 0


# --------------------------------------------------------------------------- converter

class Converter:
    def __init__(self):
        self.blocks: list[dict] = []
        self.exceptions: list[dict] = []
        self.generic_css: list[str] = []
        self.generic_css_except: dict[str, list[str]] = defaultdict(list)  # selector -> unless domains
        self.domain_css: dict[tuple, list[str]] = defaultdict(list)
        self.css_exceptions: dict[str, set[str]] = defaultdict(set)  # selector -> domains
        self.no_generic_hide: set[str] = set()  # sites with @@...$generichide
        self.no_hide: set[str] = set()          # sites with @@...$elemhide
        self.badfilters: set[str] = set()
        self.stats = Counter()

    # -- input

    def add_list(self, text: str):
        lines = [l.strip() for l in text.splitlines()]
        # Collect $badfilter targets first so they can cancel rules anywhere in the lists.
        for line in lines:
            if "badfilter" in line and "$" in line:
                self.badfilters.add(re.sub(r"[$,]badfilter\b", "", line))
        skipping = 0
        for line in lines:
            if line.startswith("!#if"):
                skipping += 1  # platform-specific sections; not worth evaluating
                continue
            if line.startswith("!#endif"):
                skipping = max(0, skipping - 1)
                continue
            if skipping or not line or line.startswith(("!", "[", "# ")) or line == "#":
                continue
            if line in self.badfilters or "badfilter" in line:
                self.stats["skipped: badfilter"] += 1
                continue
            self.add_line(line)

    def add_line(self, line: str):
        m = HOSTS_LINE.match(line)
        if m:
            host = m.group(1).lower()
            if host not in ("localhost", "0.0.0.0", "local", "broadcasthost"):
                self.add_network(f"||{host}^")
            return
        m = COSMETIC.match(line)
        if m and not line.startswith(("|", "@@", "/")):
            self.add_cosmetic(m.group(1), m.group(2), m.group(3))
            return
        self.add_network(line)

    def add_cosmetic(self, domains: str, marker: str, selector: str):
        selector = selector.strip()
        if marker not in ("##", "#@#"):
            self.stats["skipped: extended css/scriptlet"] += 1
            return
        if selector.startswith(("+js(", "^", "%")) or EXTENDED_CSS.search(selector):
            self.stats["skipped: extended css/scriptlet"] += 1
            return
        if not css_looks_valid(selector):
            self.stats["skipped: invalid selector"] += 1
            return
        inc, exc = split_domains(domains, ",")
        if domains and not inc and not exc:
            self.stats["skipped: unsupported domain"] += 1
            return
        if marker == "#@#":
            for d in inc:
                self.css_exceptions[selector].add(d)
            if not inc:
                self.stats["skipped: generic hide exception"] += 1
            return
        if inc and exc:
            self.stats["skipped: mixed domains"] += 1
            return
        if inc:
            self.domain_css[("if", tuple(sorted(set(inc))))].append(selector)
        elif exc:
            self.generic_css_except[selector].extend(exc)
        else:
            self.generic_css.append(selector)

    def add_network(self, line: str):
        exception = line.startswith("@@")
        if exception:
            line = line[2:]
        pattern, options = line, ""
        idx = line.rfind("$")
        if idx > 0 and OPTION_SYNTAX.match(line[idx + 1:]):
            pattern, options = line[:idx], line[idx + 1:]
        if pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 2:
            self.stats["skipped: regex rule"] += 1
            return
        if not is_ascii(pattern):
            self.stats["skipped: non-ascii"] += 1
            return

        trigger: dict = {}
        types: set[str] = set()
        neg_types: set[str] = set()
        inc: list[str] = []
        exc: list[str] = []
        allow_site = False
        hide_off = None  # "generic" for $generichide, "all" for $elemhide
        subdocument_only = False
        for opt in filter(None, options.split(",")):
            name, _, value = opt.partition("=")
            name = name.lower()
            neg = name.startswith("~")
            base = name.lstrip("~")
            if name in IGNORED_OPTIONS:
                continue
            if base in ("third-party", "3p", "first-party", "1p"):
                third = (base in ("third-party", "3p")) != neg
                trigger["load-type"] = ["third-party" if third else "first-party"]
            elif base == "domain" and not neg:
                inc, exc = split_domains(value, "|")
                if not inc and not exc:
                    self.stats["skipped: unsupported domain"] += 1
                    return
            elif base == "match-case" and not neg:
                trigger["url-filter-is-case-sensitive"] = True
            elif base in TYPE_MAP:
                (neg_types if neg else types).update(TYPE_MAP[base])
                if base in ("subdocument", "frame") and not neg:
                    subdocument_only = True
            elif base in ("document", "doc") and not neg:
                if exception:
                    allow_site = True
                else:
                    types.add("document")
            elif base in ("elemhide", "ehide", "generichide", "ghide") and exception and not neg:
                hide_off = "all" if base in ("elemhide", "ehide") else hide_off or "generic"
            else:
                self.stats[f"skipped: ${base}"] += 1
                return
        if inc and exc:
            self.stats["skipped: mixed domains"] += 1
            return

        if allow_site or hide_off:
            m = re.match(r"^\|\|([a-z0-9.-]+)\^?$", pattern.lower())
            if m:
                sites = [m.group(1)]
            elif pattern in ("", "*") and inc:
                sites = inc  # uBlock style: @@*$ghide,domain=a.com|b.com
            else:
                self.stats["skipped: unsupported allowlist"] += 1
                return
            if allow_site:
                # $document: nothing at all applies on this site.
                self.exceptions.append({
                    "trigger": {"url-filter": ".*", "if-domain": [safari_domain(s) for s in sites]},
                    "action": {"type": "ignore-previous-rules"},
                })
            else:
                # $elemhide / $generichide: keep network blocking, skip (generic) element hiding.
                (self.no_hide if hide_off == "all" else self.no_generic_hide).update(sites)
            return

        bare = pattern.strip("|*^")
        if len(bare) < 3 and not inc:
            self.stats["skipped: too generic"] += 1
            return
        regex = pattern_to_regex(pattern)
        if regex is None:
            self.stats["skipped: pattern"] += 1
            return
        trigger = {"url-filter": regex, **trigger}
        if neg_types and not types:
            # "~stylesheet" means every subresource type except stylesheets, never page loads.
            types = set(ALL_TYPES) - neg_types - {"document", "popup"}
        elif neg_types:
            types -= neg_types
        if types:
            trigger["resource-type"] = sorted(types)
            if subdocument_only and types == {"document"}:
                trigger["load-context"] = ["child-frame"]
        if inc:
            trigger["if-domain"] = [safari_domain(d) for d in inc]
        elif exc:
            trigger["unless-domain"] = [safari_domain(d) for d in exc]

        rule = {"trigger": trigger, "action": {"type": "ignore-previous-rules" if exception else "block"}}
        (self.exceptions if exception else self.blocks).append(rule)

    def all_selectors(self) -> set[str]:
        sels = set(self.generic_css) | set(self.generic_css_except)
        for v in self.domain_css.values():
            sels.update(v)
        return sels

    def drop_selectors(self, bad: set[str]):
        """Removes selectors WebKit can't parse. One bad selector would make WebKit
        silently skip the whole batch of selectors it's in."""
        if not bad:
            return
        self.stats["skipped: invalid selector (WebKit)"] += len(bad)
        self.generic_css = [s for s in self.generic_css if s not in bad]
        for s in bad:
            self.generic_css_except.pop(s, None)
        for k in list(self.domain_css):
            self.domain_css[k] = [s for s in self.domain_css[k] if s not in bad]

    # -- output

    def css_rules(self) -> list[dict]:
        rules = []

        def batches(selectors):
            uniq = list(dict.fromkeys(selectors))
            for i in range(0, len(uniq), CSS_BATCH):
                yield ", ".join(uniq[i:i + CSS_BATCH])

        # Generic selectors apply everywhere except sites with $generichide/$elemhide
        # exceptions, plus any #@# exceptions for that particular selector.
        no_generic = self.no_generic_hide | self.no_hide
        unless: dict[str, set[str]] = {}
        for s in self.generic_css:
            unless.setdefault(s, set(no_generic)).update(self.css_exceptions.get(s, ()))
        for s, ds in self.generic_css_except.items():
            unless.setdefault(s, set(no_generic)).update(ds, self.css_exceptions.get(s, ()))
        grouped = defaultdict(list)
        for s, ds in unless.items():
            grouped[tuple(sorted(ds))].append(s)
        for ds, sels in grouped.items():
            trigger = {"url-filter": ".*"}
            if ds:
                trigger["unless-domain"] = [safari_domain(d) for d in ds]
            for sel in batches(sels):
                rules.append({"trigger": dict(trigger), "action": {"type": "css-display-none", "selector": sel}})

        regrouped = defaultdict(list)
        for (_, ds), sels in self.domain_css.items():
            for s in sels:
                keep = tuple(d for d in ds if d not in self.css_exceptions.get(s, ()) and d not in self.no_hide)
                if keep:
                    regrouped[keep].append(s)
                else:
                    self.stats["skipped: cancelled by #@#"] += 1
        for ds, sels in regrouped.items():
            for sel in batches(sels):
                rules.append({"trigger": {"url-filter": ".*", "if-domain": [safari_domain(d) for d in ds]},
                              "action": {"type": "css-display-none", "selector": sel}})
        return rules

    def rules(self, limit: int = SAFARI_RULE_LIMIT) -> list[dict]:
        def dedupe(rules):
            seen, out = set(), []
            for r in rules:
                key = json.dumps(r, sort_keys=True)
                if key not in seen:
                    seen.add(key)
                    out.append(r)
            return out

        blocks = dedupe(self.blocks)
        css = self.css_rules()
        exceptions = dedupe(self.exceptions)  # must come last: ignore-previous-rules only affects earlier rules
        room = limit - len(exceptions)
        if len(blocks) + len(css) > room:
            over = len(blocks) + len(css) - room
            self.stats["dropped: over Safari rule limit"] += over
            print(f"  warning: {over} rules over the {limit} limit were dropped", file=sys.stderr)
            css = css[:max(0, room - len(blocks))]
            blocks = blocks[:room - len(css)]
        return blocks + css + exceptions


# --------------------------------------------------------------------------- main

def fetch(source: str, cache: Path) -> str:
    path = (ROOT / source) if not re.match(r"^https?://", source) else None
    if path and path.exists():
        return path.read_text(encoding="utf-8", errors="replace")
    cache.mkdir(parents=True, exist_ok=True)
    cached = cache / hashlib.sha1(source.encode()).hexdigest()
    req = urllib.request.Request(source, headers={"User-Agent": "safari-blocker-filter-builder"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            text = resp.read().decode("utf-8", errors="replace")
        cached.write_text(text, encoding="utf-8")
        return text
    except Exception as e:  # keep the last good copy if a list host is down
        if cached.exists():
            print(f"  warning: {source}: {e}; using cached copy", file=sys.stderr)
            return cached.read_text(encoding="utf-8")
        raise


def webkit_invalid_selectors(selectors: set[str], workdir: Path) -> set[str]:
    """Asks WebKit's CSS parser (via compile_check.swift) which selectors it rejects."""
    if not selectors:
        return set()
    tmp = workdir / ".selectors.txt"
    tmp.write_text("\n".join(sorted(s for s in selectors if "\n" not in s)) + "\n")
    try:
        result = subprocess.run(["swift", str(ROOT / "tools/compile_check.swift"), "--invalid-selectors", str(tmp)],
                                check=True, capture_output=True, text=True)
    finally:
        tmp.unlink(missing_ok=True)
    return set(result.stdout.splitlines())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(ROOT / "tools/filters.json"))
    ap.add_argument("--out", default=str(ROOT / "dist"))
    ap.add_argument("--cache", default=str(ROOT / ".cache/lists"))
    ap.add_argument("--seed", action="store_true", help="also copy results into Seeds/<Blocker>/blockerList.json")
    ap.add_argument("--no-validate", dest="validate", action="store_false",
                    help="skip pruning with WebKit's compiler (on by default on macOS)")
    args = ap.parse_args()
    if args.validate and (sys.platform != "darwin" or not shutil.which("swift")):
        print("note: not on macOS with Swift; skipping WebKit validation", file=sys.stderr)
        args.validate = False

    config = json.loads(Path(args.config).read_text())
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = {"version": 1,
                "generated": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
                "blockers": {}}

    for name, spec in config["blockers"].items():
        print(f"{name}:")
        conv = Converter()
        for src in spec["lists"]:
            text = fetch(src["url"], Path(args.cache))
            print(f"  {src['name']}: {len(text.splitlines())} lines")
            conv.add_list(text)
        if args.validate:
            conv.drop_selectors(webkit_invalid_selectors(conv.all_selectors(), out))
        rules = conv.rules() or [PLACEHOLDER_RULE]  # Safari rejects an empty list
        target = out / f"{name}.json"
        target.write_bytes(json.dumps(rules, separators=(",", ":")).encode())
        if args.validate:
            # WebKit rejects the whole list over one bad regex, so drop exactly the rules it refuses.
            subprocess.run(["swift", str(ROOT / "tools/compile_check.swift"), "--prune", str(target)], check=True)
            rules = json.loads(target.read_text())
        data = json.dumps(rules, separators=(",", ":")).encode()
        target.write_bytes(data)
        manifest["blockers"][name] = {
            "file": f"{name}.json",
            "sha256": hashlib.sha256(data).hexdigest(),
            "rules": len(rules),
            "bytes": len(data),
            "lists": [s["name"] for s in spec["lists"]],
        }
        print(f"  -> {len(rules)} rules, {len(data) // 1024} KB")
        for k, v in sorted(conv.stats.items(), key=lambda kv: -kv[1])[:8]:
            print(f"     {k}: {v}")
        if args.seed:
            seed = ROOT / "Seeds" / spec["seedFolder"] / "blockerList.json"
            seed.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(out / f"{name}.json", seed)

    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {out}/manifest.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
