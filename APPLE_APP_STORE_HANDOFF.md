# Chika: Apple App Store submission handoff

Updated 23 September 2026. Target: **iPhone and iPad App Store**. Fill the blanks below before the developers submit Chika for review. Keep passwords, private API keys, and signing certificates out of this file and the Git repository.

## Distribution route

Chika's Apple target is an **iOS/iPadOS app**. Apple does not use a separate notarization submission ID for this route. The developers must create an **Apple Distribution signed archive**, upload it to **App Store Connect**, complete the product page and compliance forms, and submit it for **App Review**. A `notarytool` submission ID applies to Developer ID signed **macOS software distributed outside the Mac App Store**. It cannot sign or approve this iOS build.

## Build prepared on 23 September 2026

A local Release archive and **App Store signed IPA** were exported successfully for bundle ID `com.chakra.comicreader`, version `0.2.1`, build `1`. Xcode used a cloud managed Apple Distribution certificate and an iOS Team Store provisioning profile. The IPA's app code signature was verified after export. The IPA and archive are held outside the Git repository for separate handoff. IPA SHA-256: `06cdf9483f5368e9dd96881f42d76f53da7943fe80cbc38bdae8dcf6de68a2d4`.

This build has **not** been uploaded to App Store Connect or submitted for review. Confirm the final version/build number and complete the fields below before upload.

## Product and account details to confirm

| Field | Fill in or confirm | Notes |
| --- | --- | --- |
| Apple Developer team and App Store Connect access | **[team/account holder and developer role]** | An active Apple Developer Program membership and permission to create an app record/upload a build are needed. Share access through Apple, not by sending a password. |
| Existing App Store Connect record? | **[yes/no; link if yes]** | Check before creating a duplicate app. |
| Bundle ID | `com.chakra.comicreader` **[confirm]** | Must match the Xcode target and an explicit registered App ID. |
| Public app name | `Chika` **[confirm or replace]** | Up to 30 characters; availability is checked in App Store Connect. |
| Subtitle | **[up to 30 characters]** | Optional but recommended. |
| Internal SKU | **[unique SKU]** | Set when creating the app record; cannot be changed later. |
| Primary language | **[language]** | Choose the language of the first listing. |
| Primary and secondary category | **[categories]** | Choose categories that describe a comic reader accurately. |
| Release version and build number | **[version] / [build]** | Set an intentional version; every uploaded build needs a unique build number. |
| Distribution and release method | **[public or unlisted; automatic or manual release]** | Decide whether Apple should release immediately after approval. |
| Price | **[free or paid; price if paid]** | Paid distribution requires the applicable paid-app agreement and tax/banking setup. |
| Countries/regions | **[list or all available]** | Include any region-specific restrictions or launch schedule. |
| Copyright | **[year and legal owner name]** | App Store Connect adds the copyright symbol. |
| EU Digital Services Act status | **[trader or non-trader; required contact details if trader]** | Complete the declaration for EU distribution. |
| Rights to app assets and sample comics | **[confirm ownership/licences]** | Confirm rights to fonts, icon, model, screenshots, and any comic shown in listing or review material. Do not use unlicensed comic pages. |

## Product page material to provide

| Field | Fill in or supply | Notes |
| --- | --- | --- |
| Description | **[plain text, up to 4,000 characters]** | Explain CBZ/CBR import, local library, reading modes, and on-device panel detection accurately. |
| Keywords | **[comma-separated, up to 100 bytes]** | Avoid repeating the app name or using other companies' names. |
| Support URL | **[public HTTPS URL with a way to contact support]** | Apple requires a support page with real contact information. A repository issue link alone may need a clearer contact page. |
| Privacy policy URL | `https://github.com/batunii/chika/blob/main/PRIVACY.md` **[confirm]** | Check that the policy still matches the shipped iOS build and its dependencies. |
| Marketing URL | **[optional public URL]** | Optional. |
| iPhone screenshots | **[1–10 final screenshots]** | Use accepted 6.9-inch or 6.5-inch dimensions. Show the actual iOS app; no alpha/transparency. |
| iPad screenshots | **[1–10 final screenshots]** | Required because the project supports iPad; use accepted 13-inch dimensions. |
| App preview video | **[optional]** | Not required. |
| Promotional text | **[optional, up to 170 characters]** | Not required. |

## Privacy, compliance, and review answers

- **App Privacy questionnaire:** **[confirm every collected or shared data type, or “Data Not Collected”]**. The current repository claims no collection and includes `PrivacyInfo.xcprivacy`; verify the final build and third-party libraries before answering.
- **Age-rating questionnaire:** **[owner/developer answers]**. Account for the app's actual features and the fact that users can import their own comic files. Do not guess a rating from the app name.
- **Export compliance/encryption:** **[confirm]**. The project currently sets `ITSAppUsesNonExemptEncryption` to `false`; validate that against the shipped build and answer any App Store Connect questions.
- **Content rights:** **[confirm third-party content and distribution rights]**. The app imports user files; any bundled or promotional comic art needs its own rights check.
- **App Review contact:** **[name, email, international-format phone]**. Apple uses this privately if reviewers need help.
- **Review notes:** **[how to import and test a CBZ/CBR; any special settings]**. Provide a licensed sample comic or a clear way for reviewers to exercise the reader. No account credentials are needed if the app has no login.
- **Other disclosures:** **[advertising, tracking, in-app purchases, external purchase links, regulated features, if any]**. Confirm against the final binary.

## Developer release checklist

- [ ] Confirm the App Store Connect app record and register the explicit `com.chakra.comicreader` App ID.
- [ ] Use current Xcode and an iOS SDK accepted by App Store Connect. This checkout targets iOS 16.0 and later.
- [ ] Generate the Xcode project (`xcodegen generate --spec iosApp/project.yml --project iosApp`). The Kotlin shared framework builds automatically in Xcode's pre-build phase; a JDK 17 must be installed. There are no CocoaPods dependencies.
- [ ] Confirm the 1024×1024 App Store icon is fully opaque, all bundled assets are licensed, and the final privacy manifest covers the app and SDKs.
- [ ] Set the release version/build number, enable **Apple Distribution** signing (automatic signing is acceptable), and create a Release `.xcarchive`.
- [ ] Validate the archive, upload to App Store Connect, and resolve all upload/processing errors. The existing GitHub `release-ios.yml` creates an **unsigned sideloading IPA** and is not an App Store upload workflow.
- [ ] Test the processed build through TestFlight on at least one iPhone and one iPad. Exercise CBZ and CBR import, reading, panel detection, progress, orientation, and offline behavior.
- [ ] Upload screenshots, complete every product-page and compliance field above, then submit for App Review.

## Mac release (Mac Catalyst)

The same Xcode target also builds a Mac app via **Mac Catalyst** (Apple silicon Macs only, macOS 13 or later). It uses the iOS bundle ID `com.chakra.comicreader`, so it's the same App Store Connect record: add the **macOS** platform to that app and the purchase is universal. Mac-specific steps:

- [ ] In Xcode, archive with the destination **Any Mac (Mac Catalyst)** and upload it like the iOS build. Mac builds need their own **Mac App Store** provisioning profile; automatic signing creates it.
- [ ] The Mac build is sandboxed (`iosApp/Chika-macOS.entitlements`: App Sandbox and read access to files the user picks). Confirm importing a CBZ/CBR from Finder works in the TestFlight Mac build.
- [ ] Upload Mac screenshots (16:10, e.g. 2880×1800), and confirm the **Books** category and privacy answers apply to the Mac.
- [ ] Mac builds share the version with iOS but each upload needs a new build number.

Distributing **outside** the Mac App Store would instead need a **Developer ID Application** signature, Hardened Runtime, and notarization with `notarytool`. That's a separate route, not needed for the App Store.

## Apple references

- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Required App Store Connect properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)
- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [App information, including privacy policy and content rights](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
