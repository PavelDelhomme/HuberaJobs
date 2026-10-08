pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    // Use writable copy when FLUTTER_GRADLE_BUILD_PATH is set (fixes read-only SDK e.g. /usr/lib/flutter)
    val gradleBuildPath = System.getenv("FLUTTER_GRADLE_BUILD_PATH")
    val pathToUse = if (!gradleBuildPath.isNullOrBlank()) gradleBuildPath else "$flutterSdkPath/packages/flutter_tools/gradle"
    includeBuild(pathToUse)

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("com.android.library") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
include(":hubera-id-sso")
project(":hubera-id-sso").projectDir = file("hubera-id-sso")
