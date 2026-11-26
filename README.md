# Ad Nope: a Safari content blocker for iPhone, iPad and Mac

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
        │  SFContentBlockerManager.reloadContentBlocker       ▲
        ▼                                                     │ allowlist synced by iCloud,
 3 content-blocker extensions ── hand the file to Safari;     │ also editable from Safari's
                                 Safari compiles and enforces │ Share menu (iPhone, iPad)
```

## Layout

| Path | What it is |
|---|---|
| `App/` | SwiftUI host app (iOS, iPadOS, macOS): status, updates, allowlist, filter-server setting |
| `Shared/Blocker.swift` | The three blockers and App Group file paths (compiled into every target) |
| `Shared/RuleComposer.swift` | Builds each blocker's file (base list + allowlist) and reloads Safari; used by the app and the Share extension |
| `Shared/Allowlist.swift` | Allowed sites: App Group storage mirrored to iCloud key-value storage |
| `Extension/ContentBlockerRequestHandler.swift` | Shared by all three extensions; hands Safari a file URL |
| `ShareExtension/` | Safari Share › Ad Nope: allow or re-block the current site (iPhone, iPad) |
| `DarkExtension/` | Ad Nope Dark: optional Safari web extension for Extras › Dark mode for websites |
| `Shared/DarkModeSettings.swift` | Dark-mode settings, shared by the app and the Dark extension |
| `Seeds/{Ads,Privacy,Annoyances}/blockerList.json` | Tiny starter lists bundled in each extension for first launch |
| `Config/` | Info.plists and entitlements (iOS and macOS variants) |
| `tools/build_filters.py` | Filter-list → Safari JSON converter |
| `tools/compile_check.swift` | Compiles lists with WebKit; `--prune` removes rules WebKit rejects |
| `tools/filters.json` | Which lists go into which blocker |
| `tools/gen_xcodeproj.py` | Generates `Blocker.xcodeproj` (re-run only to change targets or build settings) |
| `tools/make_icon.swift` | Draws the app icon |
| `.github/workflows/filters.yml` | Daily build and publish to GitHub Pages |

There are three extensions because each is limited to 150,000 rules, and so
you can turn categories on and off separately in Settings.

## Run it

1. Open `Blocker.xcodeproj`. Bundle IDs come from two project-level build
   settings: `BUNDLE_ID_PREFIX` (`com.dcantor`) and `APP_GROUP_ID`
   (`group.com.dcantor.blocker`). Signing is automatic with your team.
2. Run the **Blocker** scheme on your iPhone, iPad or Mac (choose "My Mac" as
   the destination). The project, scheme and
   bundle IDs are still called Blocker internally; only the displayed name is
   "Ad Nope" (the `INFOPLIST_KEY_CFBundleDisplayName` setting).
3. Turn on Ads, Trackers and Annoyances (listed under Ad Nope):
   - iPhone and iPad: **Settings › Apps › Safari › Extensions**
   - Mac: **Safari › Settings › Extensions**
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

## Extras

**Dark mode for websites** (Extras › Dark mode for websites in the app) gives
light-only sites a dark look. It's a separate, optional Safari web extension,
**Ad Nope Dark**, because content blockers can only hide or block things, not
change colors.

- It inverts the page's colors with a hue rotation, so reds stay red and blues
  stay blue, then flips images, video and embeds back. Sites that are already
  dark are detected and left alone.
- "When my device is in dark mode" follows the iPhone, iPad or Mac appearance;
  "Always" darkens all the time. "Never darken" excludes sites.
- Turn it on in Settings › Apps › Safari › Extensions › Ad Nope Dark (Mac:
  Safari › Settings › Extensions), and allow it on all websites. Unlike the
  blockers it needs permission to change web pages. It doesn't send anything
  anywhere: the extension asks the app only for its settings.
- Limitation: very saturated yellows and cyans in images come out slightly
  muted, because CSS's `hue-rotate` isn't exactly reversible. Mid-tones,
  including skin tones, are reproduced accurately.
- Mac: Safari only loads web extensions from development-signed apps after
  you turn on Develop › Developer Settings › Allow unsigned extensions.

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
  at the end of every list, so it overrides everything above it. Composing is
  done on bytes, not by parsing JSON, so it's fast and fits in the Share
  extension's memory limit.
- **Share menu:** in Safari, tap Share › Ad Nope to allow the current site (or
  block it again). The extension receives only the page's address. Reload the
  page afterwards to see the change.
- **iCloud sync:** the allowlist is stored in iCloud key-value storage (free,
  private to your Apple Account). The first time a device syncs, its list and
  iCloud's are merged; after that iCloud wins, so removals carry over too.
  Changes arrive within seconds to minutes while the app is open, or the next
  time you open it.
- **Mac:** the same app and blockers, sandboxed. There's no Share extension on
  the Mac; add sites in the app, or on your iPhone and let iCloud sync them.
  The Mac checks for new lists about twice a day while the app is running.
- **Background updates:** iOS decides when `BGAppRefreshTask` runs, often
  overnight. The app also updates on launch when the last check is over a day old.
- **Licenses:** EasyList and EasyPrivacy are GPLv3 / CC BY-SA 3.0. That's fine
  for personal use; follow those licenses if you ever distribute the app.
- **Tests:** `tools/fixtures/sample.txt` covers each syntax the converter
  handles:
  `python3 tools/build_filters.py --config tools/fixtures/filters.test.json --out /tmp/out`
