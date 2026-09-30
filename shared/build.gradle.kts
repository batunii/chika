plugins {
    alias(libs.plugins.kotlin.multiplatform)
}

// Platform-independent core: panel model, reading-order + merge/divide planning, camera math, and
// the archive abstraction. No Android (or any platform) APIs may be added to commonMain — platform
// integrations (TFLite/LiteRT, bitmap decoding, archive backends) live behind these interfaces in
// the consuming targets.
kotlin {
    jvm {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    // macosArm64 exists only to feed Mac Catalyst: Kotlin/Native has no Catalyst target, so the
    // Xcode build retags this macOS framework's objects as Catalyst (iosApp/scripts/build-shared.sh).
    listOf(iosArm64(), iosSimulatorArm64(), macosArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "ChikaShared"
            isStatic = true
        }
    }

    sourceSets {
        commonTest.dependencies {
            implementation(libs.kotlin.test)
        }
    }
}
