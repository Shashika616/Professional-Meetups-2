pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    // Real Firebase push wiring (ADR-030, round-10) — this project's
    // Flutter template puts the top-level plugins{} block here, in
    // settings.gradle.kts, not in the root build.gradle.kts (which has no
    // plugins{} block at all in this template version — the round-10
    // plan's own instruction assumed the older layout; this is the
    // equivalent location for the same declare-version-here,
    // apply-in-app-module-below pattern the other two plugins already
    // use). Applied for real in app/build.gradle.kts.
    id("com.google.gms.google-services") version "4.5.0" apply false
}

include(":app")
