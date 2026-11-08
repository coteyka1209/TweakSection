# TweakSection

**Groups every tweak's settings pane under a single "Cydia tweaks" entry in the iOS 6
Settings root list** — the way iOS 7+ does it natively — instead of a dozen scattered
rows.

## What it does

- On iOS 6, every tweak with a PreferenceLoader plist adds its own row to the main
  Settings list. TweakSection collects them all under one **"Cydia tweaks"** entry;
  tapping it opens a page with all the tweak panes.
- **Auto-adapts**: new tweaks are discovered by scanning
  `/Library/PreferenceLoader/Preferences/` (plain plists, extensionless files and
  directory-style entries alike) — nothing to update when you install another tweak.
- Each pane inside behaves exactly like it did standalone (toggles persist through
  PSDefaultController, sub-pages push as usual).
- The entry carries the **icon of the installed package manager** (Cydia, Sileo, Zebra,
  Icy — first match wins), restyled into the era look: rounded corners, gloss, hairline
  border. No icon sources found → the row renders without one. No new dependencies.

## Requirements

- iPhone / iPod touch, iOS 6.0 – 6.1.x (restricted via `firmware` deps)
- MobileSubstrate (Cydia Substrate) and **PreferenceLoader** (the panes being grouped)

## Install

Add the Cydia/Sileo source: `http://coteyka.qzz.io` — or grab the `.deb` from
[Releases](../../releases) and install with `dpkg -i`.

## How it works

On iOS 6 the Settings root (`PrefsListController`) populates lazily through the
`-specifiers` getter, and PreferenceLoader appends its entries inside the same getter —
so that getter is the only hook point that always sees the fully populated list
(`reloadSpecifiers` never fires at launch). TweakSection hooks the getter, matches
specifiers against the normalized `entry.label` of every PreferenceLoader plist, pulls
them out of the root array and drops a single `PSLinkCell` row whose detail is a runtime
`PSListController` subclass returning the stashed specifiers. An in-place merge is used
deliberately: the table renders the live `_specifiers` array, not the getter's return
value. A "General" specifier marks the true root, guarding against grouping inside
tweak sub-pages.

## Build

```bash
git clone https://github.com/coteyka1209/TweakSection.git && cd TweakSection
THEOS=~/theos make package FINALPACKAGE=1
```

Debug logging: set `#define TS_DEBUG 1` in `Tweak.x`, rebuild, then
`grep TweakSection /var/log/syslog`.

## License

[MIT](LICENSE).
