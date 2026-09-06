# Releasing Chika

Pushing a version tag (`v*`) triggers [`.github/workflows/release.yml`](.github/workflows/release.yml),
which builds a **signed release AAB + APK** and publishes them on a GitHub Release. The AAB is what
you upload to the Google Play Console; the APK is for direct/sideload distribution.

## One-time setup

### 1. Create an upload keystore

> ⚠️ Keep this file and its passwords safe and backed up. If you lose the key you use for Play, you
> can't push updates to that listing (unless enrolled in Play App Signing key reset).

```bash
keytool -genkeypair -v \
  -keystore chika-release.jks \
  -alias chika \
  -keyalg RSA -keysize 2048 -validity 10000
```

### 2. Base64-encode the keystore

```bash
# macOS / Linux
base64 -w0 chika-release.jks > keystore.b64
```

```powershell
# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("chika-release.jks")) | Set-Content -NoNewline keystore.b64
```

### 3. Add the GitHub repo secrets

Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `KEYSTORE_BASE64` | contents of `keystore.b64` |
| `KEYSTORE_PASSWORD` | the keystore password |
| `KEY_ALIAS` | `chika` (the alias above) |
| `KEY_PASSWORD` | the key password |

Do **not** commit the keystore or `keystore.b64` to the repo.

## Cutting a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow then:
- derives `versionName` from the tag (`v1.0.0` → `1.0.0`) and `versionCode` deterministically from
  it (`MAJOR*10000 + MINOR*100 + PATCH`),
- builds and **signs** `app-release.aab` and `app-release.apk`,
- creates a GitHub Release for the tag with auto-generated notes, both files, and the R8
  `mapping-<version>.txt` attached (upload the mapping to Play alongside the AAB for readable
  crash stacks).

`workflow_dispatch` is also enabled, so you can run it manually from the Actions tab.

## Notes

- Local `./gradlew assembleRelease` without the signing env vars still works but produces an
  **unsigned** APK (debug builds are unaffected). Signing only kicks in when `KEYSTORE_FILE` etc.
  are present (i.e. in CI).
- For Google Play, prefer the **AAB** and enroll in **Play App Signing**.
- `isMinifyEnabled` and `isShrinkResources` are **enabled**: release builds go through R8 with the
  keep rules in `app/proguard-rules.pro` (JNI natives, 7-Zip-JBinding, TFLite/LiteRT). Smoke-test a
  release build on a device after touching dependencies or the rules.
- Google Play requires a hosted **privacy policy** URL for every app: use
  `https://github.com/batunii/chika/blob/main/PRIVACY.md`. The Data Safety form is "no data
  collected" — the app has no INTERNET permission.
- Play's 16 KB page-size requirement (targetSdk 35+) is satisfied by 7-Zip-JBinding ≥ 16.02-2.03
  and LiteRT 1.4.x — both ship 16 KB-aligned `.so`s. Keep that in mind on any dependency change:
  check with `unzip -p app.apk 'lib/arm64-v8a/*.so' | readelf -lW - | grep LOAD` (align must be
  0x4000).
