# Third-Party Notices

Chika (the application source) is licensed under the **Mozilla Public License 2.0** — see
[`LICENSE`](LICENSE). This file documents the third-party software, models, fonts, and data that
Chika depends on or bundles, along with the obligations each imposes. Full license texts are in
[`THIRD_PARTY_LICENSES/`](THIRD_PARTY_LICENSES).

## Summary of obligations

| Component | License | Bundled? | Key obligation |
|---|---|---|---|
| AndroidX / Jetpack Compose / Kotlin / Coroutines | Apache-2.0 | yes (in APK) | Keep license + NOTICE attribution |
| Apache Commons Compress | Apache-2.0 | yes | Keep license + NOTICE |
| TensorFlow Lite (`org.tensorflow:tensorflow-lite`) | Apache-2.0 | yes (native `.so`) | Keep license |
| **7-Zip-JBinding-4Android** | **LGPL-2.1** (+ unRAR, BSD parts) | yes (native `.so`) | See LGPL note below |
| Panel-detection model (`manga_panel_detector_int8.tflite` on Android, `MangaPanelDetector.mlpackage` on Apple) | Apache-2.0 | yes (asset) | Disclose Manga109-s training data |
| Anton font | OFL-1.1 | yes (asset) | Keep OFL text; don't sell font alone |
| Archivo font | OFL-1.1 | yes (asset) | Keep OFL text; don't sell font alone |

MPL-2.0 (Chika) is compatible with all of the above, including the LGPL component (MPL-2.0 §3.3).

## Dependencies

### Apache License 2.0
Full text: [`THIRD_PARTY_LICENSES/Apache-2.0.txt`](THIRD_PARTY_LICENSES/Apache-2.0.txt)

- **Kotlin** standard library & coroutines — © JetBrains / Kotlin Foundation
- **AndroidX / Jetpack**: `core-ktx`, `lifecycle-*`, `activity-compose`, Jetpack **Compose** (UI,
  Material 3, Material Icons), `navigation-compose`, `documentfile`, **Room** — © The Android Open
  Source Project
- **Apache Commons Compress** `org.apache.commons:commons-compress` — © The Apache Software
  Foundation (used for CBZ/ZIP reading)
- **TensorFlow Lite** `org.tensorflow:tensorflow-lite:2.16.1` — © The TensorFlow Authors (on-device
  panel-detection inference)

### GNU LGPL 2.1 — 7-Zip-JBinding-4Android
Full text: [`THIRD_PARTY_LICENSES/LGPL-2.1.txt`](THIRD_PARTY_LICENSES/LGPL-2.1.txt)
Source: https://github.com/omicronapps/7-Zip-JBinding-4Android (wraps 7-Zip, https://7-zip.org)

`com.github.omicronapps:7-Zip-JBinding-4Android` is used to read **CBR (RAR/RAR5)** archives. It is
licensed **GNU LGPL 2.1**, with a portion under **LGPL + the unRAR license restriction**, and some
files under BSD.

- **unRAR restriction:** the unRAR source may not be used to *re-create the RAR compression
  algorithm*. Chika only **decompresses/reads** RAR archives, which is permitted.
- **LGPL compliance:** the library ships as a dynamically-loaded native library (`.so`) that a user
  could replace, satisfying LGPL §6 even when combined with the MPL-licensed application. We retain
  the LGPL text and this attribution, and point to the upstream source above. If you distribute a
  build, keep this notice and the library replaceable.

### SIL Open Font License 1.1 — Fonts
Full texts: [`THIRD_PARTY_LICENSES/OFL-1.1-Anton.txt`](THIRD_PARTY_LICENSES/OFL-1.1-Anton.txt),
[`THIRD_PARTY_LICENSES/OFL-1.1-Archivo.txt`](THIRD_PARTY_LICENSES/OFL-1.1-Archivo.txt)

- **Anton** (display) and **Archivo** (UI), bundled in `app/src/main/res/font/`. The OFL permits
  bundling and redistribution within software; the fonts may not be sold on their own, and the
  copyright/Reserved Font Name notices are retained in the OFL texts above.

## Bundled model & training data

- **`manga_panel_detector_int8.tflite`** — from
  [`leoxs22/manga-panel-detector-yolo26n`](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n),
  released under **Apache-2.0**. It detects panels (class 0) and text balloons (class 1).
- **`MangaPanelDetector.mlpackage`** (iOS, iPadOS, Mac) — the same model's upstream FP32 weights
  (`manga_panel_detector_fp32.pt`) converted to Core ML by `training/scripts/export_coreml.py`. Same
  weights, same license and training-data disclosure as the `.tflite`.
- The model was **trained on the Manga109-s dataset**. Per the dataset terms, commercial use of the
  model's outputs is permitted provided dataset usage is disclosed — **this notice constitutes that
  disclosure**. See http://www.manga109.org/ for dataset terms.
- The model was produced with Ultralytics YOLO tooling; the distributed weights are licensed
  Apache-2.0 by their author, which is the basis on which Chika redistributes them.
- **Licensing caveat (to resolve before any commercial release):** the upstream weights are labelled
  Apache-2.0, but because they are **trained on Manga109-s** (an academic/research dataset), some
  readings — e.g. the CoMix project's license, which labels Manga109-trained weights CC BY-NC-SA 4.0
  (non-commercial) — consider such weights non-commercial. The Manga109-s terms (clause 5) do appear
  to permit commercial use of a trained model's *outputs*, so this is likely fine for distribution,
  but it is **genuinely ambiguous**. Any Manga109-derived replacement model inherits the same
  caveat; a model trained only on permissively-licensed (e.g. CC-BY) panel datasets would remove it.

## Brand assets

The **Chika / Chitra Katha** name, logo, and wordmark are brand assets owned by the project owner
(Chakra / Chalchitra Krida) and are **not** covered by the MPL-2.0 code license. Trademark/brand
rights are reserved even where the surrounding source is open.

## Distribution notes

- **Google Play / Apple App Store:** MPL-2.0 is compatible with both stores. (A strong-copyleft
  license such as GPL would not be App-Store compatible — one reason MPL-2.0 was chosen.)
- **F-Droid:** Chika bundles **prebuilt** native libraries (7-Zip-JBinding, TensorFlow Lite) and a
  **prebuilt model** asset, pulled from trusted Maven repos (JitPack / Google Maven). These are
  free-licensed and permitted, though F-Droid may flag the prebuilt model blob.
