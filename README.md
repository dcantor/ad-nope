# Ad Nope: a Safari content blocker for iPhone and iPad

A small, private ad and tracker blocker for Safari. It's a Safari **Content
Blocker**: the app gives Safari a list of rules, Safari applies them itself,
and the app never sees the pages you visit.

```
 filter lists (EasyList, EasyPrivacy, …)
        │  daily GitHub Action (macOS)
        ▼
 tools/build_filters.py ── converts to Safari JSON, prunes rules WebKit rejects
        │
        ▼
 GitHub Pages: manifest.json + ads.json + privacy.json + annoyances.json
        │  app checks about once a day (and on "Update Filters Now")
        ▼
 Blocker.app ── verifies SHA-256, adds your allowlist, writes to the App Group
        │  SFContentBlockerManager.reloadContentBlocker
        ▼
 3 content-blocker extensions ── hand the file to Safari; Safari compiles and enforces it
```

## Layout

| Path | What it is |
|---|---|
| `App/` | SwiftUI host app: status, update, allowlist, filter-server setting |
| `Shared/Blocker.swift` | The three blockers and App Group file paths (compiled into every target) |
| `Extension/ContentBlockerRequestHandler.swift` | Shared by all three extensions; hands Safari a file URL |
| `Seeds/{Ads,Privacy,Annoyances}/blockerList.json` | Tiny starter lists bundled in each extension for first launch |
| `Config/` | Info.plists and the App Group entitlement |
| `tools/build_filters.py` | Filter-list → Safari JSON converter |
| `tools/compile_check.swift` | Compiles lists with WebKit; `--prune` removes rules WebKit rejects |
| `tools/filters.json` | Which lists go into which blocker |
| `.github/workflows/filters.yml` | Daily build and publish to GitHub Pages |

There are three extensions because each is limited to 150,000 rules, and so
you can turn categories on and off separately in Settings.

## Run it

1. Open `Blocker.xcodeproj`. Bundle IDs come from two project-level build
   settings: `BUNDLE_ID_PREFIX` (`com.dcantor`) and `APP_GROUP_ID`
   (`group.com.dcantor.blocker`). Signing is automatic with your team.
2. Run the **Blocker** scheme on your iPhone or iPad. The project, scheme and
   bundle IDs are still called Blocker internally; only the displayed name is
   "Ad Nope" (the `INFOPLIST_KEY_CFBundleDisplayName` setting).
3. On the device, go to **Settings › Apps › Safari › Extensions** and turn on
   Ads, Trackers and Annoyances (listed under Ad Nope).
4. On first launch the app downloads the full lists from
   `https://dcantor.github.io/ad-nope/` (`FilterStore.defaultServerURL`).
   Until then, the small starter lists bundled with the app are active.

## Publish the full lists

The **Build filters** workflow rebuilds the lists daily and publishes them to
GitHub Pages at `https://dcantor.github.io/ad-nope/`. To publish from a fork:

1. Push this folder to a GitHub repo.
2. In the repo, go to **Settings › Pages › Source** and choose **GitHub Actions**.
3. Run the **Build filters** workflow (Actions tab), or wait for the daily run.
4. Change `FilterStore.defaultServerURL`, or set **Filter server** in the app,
   to `https://<user>.github.io/<repo>/`.

Or build locally and host `dist/` anywhere:

```bash
python3 tools/build_filters.py            # writes dist/, validated with WebKit
python3 tools/build_filters.py --seed     # also refreshes the bundled starter lists
swift tools/compile_check.swift dist/ads.json dist/privacy.json dist/annoyances.json
```

## Things worth knowing

- **One bad rule breaks the whole list.** WebKit refuses to compile a list
  containing an unsupported regex (for example `a|b`), and refuses an empty list.
  `build_filters.py` runs `compile_check.swift --prune` on macOS to remove
  exactly the rejected rules. The app also keeps the previous list if Safari
  rejects a new one.
- **One bad selector silently disables its batch.** Element-hiding selectors
  are grouped 50 per rule. If any selector in a group is invalid, WebKit skips
  the whole rule without reporting an error. The build therefore checks every
  selector with WebKit's CSS parser first (`compile_check.swift
  --invalid-selectors`). EasyList currently has a few such selectors.
- **Compile time matters.** Safari compiles each list on the device. Matching
  `||host^` as `host[/:]` instead of `host([^…].*)?$` made the Ads list compile
  9× faster on a Mac (14 s → 1.5 s).
- **What the converter skips:** regex rules, scriptlets (`##+js`), extended
  CSS (`:has-text`, `:-abp-*`, …), `$redirect`, `$removeparam`, `$csp`, and TLD
  wildcards like `google.*`. Each run prints counts of what it skipped. AdGuard's
  [SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib)
  converts more of these if you outgrow this script.
- **Allowlist:** each allowed site becomes an `ignore-previous-rules` rule added
  at the end of every list, so it overrides everything above it.
- **Background updates:** iOS decides when `BGAppRefreshTask` runs, often
  overnight. The app also updates on launch when the last check is over a day old.
- **Licenses:** EasyList and EasyPrivacy are GPLv3 / CC BY-SA 3.0. That's fine
  for personal use; follow those licenses if you ever distribute the app.
- **Tests:** `tools/fixtures/sample.txt` covers each syntax the converter
  handles:
  `python3 tools/build_filters.py --config tools/fixtures/filters.test.json --out /tmp/out`
