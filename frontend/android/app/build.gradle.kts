import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Real Firebase push wiring (ADR-030, round-10) — reads
    // google-services.json (already at android/app/google-services.json)
    // and generates the resources FirebaseOptions/the native SDK need.
    // Version declared in settings.gradle.kts's plugins{} block.
    id("com.google.gms.google-services")
}

android {
    namespace = "com.profconn.professional_connections_platform"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.profconn.professional_connections_platform"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // # RELEASE SIGNING (tracker #55, review finding V-5)
    //
    // The release build used to be signed with the DEBUG keystore — the
    // one every Android SDK install generates, with a password everyone
    // knows ("android"). An APK signed with it cannot go to Play, and an
    // APK that does go anywhere carries a signature that proves nothing
    // about who built it: anyone can produce a byte-identical signer and
    // ship an "update".
    //
    // The keystore itself is NOT in this repository and is not generated
    // by it. It is created once by Shashika and kept outside the tree;
    // android/key.properties points at it and is gitignored. See the
    // runbook's release-signing section for the exact commands and for
    // what to do if it is ever lost (there is no recovery: a new key
    // means a new app listing).
    // "Is this invocation actually going to produce a release artifact?"
    // assembleRelease, bundleRelease, flutter's own build apk --release,
    // and the IDE's variants all name the Release variant in the task.
    val isReleaseBuild = gradle.startParameter.taskNames.any {
        it.contains("Release") || it.contains("release")
    }

    val keyProperties = Properties()
    val keyPropertiesFile = rootProject.file("key.properties")
    if (keyPropertiesFile.exists()) {
        keyPropertiesFile.inputStream().use { keyProperties.load(it) }
    }

    signingConfigs {
        create("release") {
            // Resolved relative to android/, so key.properties can hold a
            // path outside the repository.
            val storePath = keyProperties.getProperty("storeFile")
            if (storePath != null) {
                storeFile = rootProject.file(storePath)
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // FAIL, DO NOT FALL BACK. A missing key.properties used to
            // mean "sign with debug and carry on", which is exactly how a
            // debug-signed release got built in the first place: nothing
            // ever said no. The build stops instead, naming the file it
            // wants.
            //
            // Gated on the requested tasks, not just on the file: this
            // block is CONFIGURED on every Gradle invocation, debug
            // included, so an unconditional throw here would break
            // `flutter run` on any machine without a keystore — which is
            // every machine that is not Shashika's. Debug and profile
            // builds keep the debug signing config the Android plugin
            // gives them and need nothing.
            if (isReleaseBuild && !keyPropertiesFile.exists()) {
                throw GradleException(
                    "Release build needs android/key.properties (storeFile, " +
                        "storePassword, keyAlias, keyPassword). It is gitignored " +
                        "and the keystore lives outside this repository — see " +
                        "docs/deploy/gcp-runbook.md, 'Android release signing'. " +
                        "Debug and profile builds do not need it."
                )
            }
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
