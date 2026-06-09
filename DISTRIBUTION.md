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

- **Versioning:** F-Droid builds from a tag, so the **`versionCode` must be real and increasing in
  source** for each release (the CI env override is only for Play/IzzyOnDroid APKs). Bump the
  default `versionCode` in `app/build.gradle.kts` per release, or set it deterministically from the
  tag in the F-Droid recipe.
- **Bundled model blob:** `app/src/main/assets/manga_panel_detector_int8.tflite` is a prebuilt
  binary committed to the repo. It is Apache-2.0 (free) **data**, not executable code, so it is
  generally acceptable, but F-Droid reviewers may ask that it be fetched at build time or flagged.
- **Reproducible builds** are encouraged (not required). The release signing is already isolated via
  env vars, which helps.
- Dependencies from JitPack (7-Zip-JBinding) and Maven are allowed as free binaries.

## Also free: direct distribution

The `release` workflow already publishes a signed APK on every `v*` tag's GitHub Release, so users
can sideload directly, and tools like **Obtainium** can auto-update from the GitHub Releases page —
no repo submission needed.

## Donations

All of the above are compatible with seeking donations via an **external link** (e.g. Ko-fi, GitHub
Sponsors, Liberapay) from the listing/README. (In-app donations on Google Play are restricted to
registered nonprofits; external links avoid that entirely.)
