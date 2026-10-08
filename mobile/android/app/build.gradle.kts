plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "cloud.hubera.jobs"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cloud.hubera.jobs"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        resValue("string", "app_name", "Hubera Jobs")
    }

    // Trois apps côte à côte (dev / préprod / prod) + OTA par canal API.
    flavorDimensions += "env"
    productFlavors {
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Hubera Jobs Dev")
        }
        create("preprod") {
            dimension = "env"
            applicationIdSuffix = ".preprod"
            resValue("string", "app_name", "Hubera Jobs Preprod")
        }
        create("prod") {
            dimension = "env"
            resValue("string", "app_name", "Hubera Jobs")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation(project(":hubera-id-sso"))
}

// Contourne compress*Assets / Zip « already contains entry … kernel_blob.bin »
// (sortie compressée sale). Ne jamais supprimer le kernel_blob SOURCE (merge*Assets).
tasks.configureEach {
    if (name.startsWith("compress") && name.contains("Assets", ignoreCase = true)) {
        doFirst {
            val compressedRoot =
                layout.buildDirectory.get().asFile.resolve("intermediates/compressed_assets")
            if (compressedRoot.exists()) {
                compressedRoot.deleteRecursively()
            }
        }
        // Flutter copie les assets hors du graphe de dépendances AGP classique.
        val copyFlutter =
            tasks.findByName("copyFlutterAssetsDebug")
                ?: tasks.findByName("copyFlutterAssets${name.removePrefix("compress").removeSuffix("Assets")}")
        if (copyFlutter != null) {
            dependsOn(copyFlutter)
        }
    }
}
