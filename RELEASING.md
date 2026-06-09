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
- derives `versionName` from the tag (`v1.0.0` → `1.0.0`) and `versionCode` from the run number,
- builds and **signs** `app-release.aab` and `app-release.apk`,
- creates a GitHub Release for the tag with auto-generated notes and both files attached.

`workflow_dispatch` is also enabled, so you can run it manually from the Actions tab.

## Notes

- Local `./gradlew assembleRelease` without the signing env vars still works but produces an
  **unsigned** APK (debug builds are unaffected). Signing only kicks in when `KEYSTORE_FILE` etc.
  are present (i.e. in CI).
- For Google Play, prefer the **AAB** and enroll in **Play App Signing**.
- `isMinifyEnabled` is currently `false`. If you later enable R8 shrinking, verify the ProGuard
  keep rules still cover the JNI/native libraries (OpenCV, 7-Zip-JBinding, TensorFlow Lite).
