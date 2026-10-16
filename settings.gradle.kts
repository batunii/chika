pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://jitpack.io")
            // Only the 7-Zip-JBinding native bundle comes from JitPack; never let it serve other groups.
            content { includeGroup("com.github.omicronapps") }
        }
    }
}

rootProject.name = "ComicBookReader"
include(":app")
include(":shared")
