# Distributing Chika (free / FOSS channels)

Chika is built to be distributable through FOSS app repositories without a paid developer account.
It already meets the core requirements:

- **License:** Mozilla Public License 2.0 (FOSS) — see [`LICENSE`](LICENSE).
- **All dependencies are free-licensed and from trusted Maven repos** (Maven Central, Google Maven,
  JitPack) — OpenCV, TensorFlow Lite, 7-Zip-JBinding, Commons Compress, AndroidX. F-Droid permits
  free binaries from these repos.
- **No trackers, no ads, no Google Play Services, no network access** — no anti-features.
- Store listing metadata lives in `fastlane/metadata/android/en-US/` (title, descriptions,
  changelog, icon, screenshots) and is read by both F-Droid and IzzyOnDroid.

The 16 KB-page-size requirement is a **Google Play** rule and does **not** apply to these channels.

## Route A — IzzyOnDroid (recommended first; easiest)

IzzyOnDroid is the largest third-party F-Droid repo. It does **not** build from source — it ingests
the **APK from your GitHub Releases** — so it's the fastest path and accepts apps that are FOSS with
at most minor non-free components (flagged). Steps:

1. Cut a release so an APK is attached to a GitHub Release (the `release` workflow does this on a
   `v*` tag — see [`RELEASING.md`](RELEASING.md)).
2. Request inclusion per https://codeberg.org/IzzyOnDroid/repo (the repo's wiki/issue template).
   They check the license, scan for anti-features, and pull the APK + the fastlane metadata.
3. Users add the IzzyOnDroid repo to the F-Droid client and install Chika.

## Route B — F-Droid main repo (more rigorous)

F-Droid builds the app **from source** on their servers and publishes the result. Submit a build
recipe to `fdroiddata` via merge request: https://gitlab.com/fdroid/fdroiddata

Things to handle for the main repo:

- **Versioning:** ✅ handled — `versionCode` is now derived deterministically from `versionName`
  (`MAJOR*10000 + MINOR*100 + PATCH`, e.g. `0.1.1` → `101`) in `app/build.gradle.kts`, so it's stable
  and increasing whether built by CI or by F-Droid from source. Just bump `versionName` per release.
- **Unsigned release build:** ✅ handled — release signing only activates when the keystore env vars
  are present (CI), so F-Droid's `assembleRelease` produces an unsigned APK that F-Droid then signs
  with its own key.
- **Bundled model blob:** `app/src/main/assets/manga_panel_detector_int8.tflite` is a prebuilt
  binary committed to the repo. It is Apache-2.0 (free) **data**, not executable code, so it is
  generally acceptable, but F-Droid reviewers may ask that it be fetched at build time or flagged.
- Dependencies from JitPack (7-Zip-JBinding) and Maven are allowed as free binaries.

A ready-to-submit recipe is in [`fdroid/com.chakra.comicreader.yml`](fdroid/com.chakra.comicreader.yml)
— copy it to `metadata/com.chakra.comicreader.yml` in your `fdroiddata` fork and open the MR.

## Submission materials

**IzzyOnDroid request** — open an issue/RFP at https://codeberg.org/IzzyOnDroid/repo with:

> **App:** Chika — Chitra Katha
> **Package:** `com.chakra.comicreader`
> **Source:** https://github.com/batunii/chika
> **License:** MPL-2.0 (FOSS)
> **Releases:** signed APKs attached to GitHub Releases (`v*` tags); fastlane metadata in
> `fastlane/metadata/android/en-US`.
> **Anti-features:** none — no trackers, no ads, no Google Play Services, no network access.
> All dependencies are free-licensed (Apache-2.0 / LGPL-2.1 / OFL-1.1) from Maven Central, Google
> Maven, and JitPack. Please track GitHub releases for updates.

## Also free: direct distribution

The `release` workflow already publishes a signed APK on every `v*` tag's GitHub Release, so users
can sideload directly, and tools like **Obtainium** can auto-update from the GitHub Releases page —
no repo submission needed.

## Donations

All of the above are compatible with seeking donations via an **external link** (e.g. Ko-fi, GitHub
Sponsors, Liberapay) from the listing/README. (In-app donations on Google Play are restricted to
registered nonprofits; external links avoid that entirely.)
