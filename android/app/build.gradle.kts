import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key: android/key.properties (never committed, see android/.gitignore):
//   storeFile=/absolute/path/to/upload-keystore.jks
//   storePassword=...
//   keyAlias=upload
//   keyPassword=...
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.abhi.abhi_utility"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.abhi.abhi_utility"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 10+: PDFs are saved to Downloads with MediaStore (no storage permission).
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Phone CPUs only: x86 libraries are left out in packaging {} below (an ndk
        // abiFilters here would clash with flutter build apk --split-per-abi).
    }

    buildFeatures { buildConfig = true }

    // Two builds of the same app:
    //   full: every feature, for sideloading (flutter build apk --flavor full)
    //   play: Google Play policy-compliant (flutter build appbundle --flavor play).
    //         src/play/AndroidManifest.xml removes the restricted permissions and
    //         components; BuildConfig.PLAY_STORE (Kotlin) and kPlayStore (Dart,
    //         lib/store_build.dart) hide the features that need them.
    flavorDimensions += "store"
    productFlavors {
        create("full") {
            dimension = "store"
            buildConfigField("boolean", "PLAY_STORE", "false")
        }
        create("play") {
            dimension = "store"
            buildConfigField("boolean", "PLAY_STORE", "true")
        }
    }

    // Required by openvpn_flutter: the OpenVPN engine runs from a native
    // library that must be extracted on install.
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // abiFilters above is merged with Flutter's own list, so the OpenVPN / speed-test
            // libraries still came in for x86 (emulators only, ~29 MB). Leave them out.
            excludes += listOf("lib/x86/**", "lib/x86_64/**")
        }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Never ship debug-signed builds: without key.properties the release
            // build stops with an error (see the check at the end of this file).
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else null
            isMinifyEnabled = false
            isShrinkResources = false
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

dependencies {
    // Zip tool: password-protected (AES-256) zips.
    implementation("net.lingala.zip4j:zip4j:2.11.5")
    // SOS: record video + sound over the lock screen when no contact answers.
    val camerax = "1.4.2"
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-video:$camerax")
    implementation("androidx.camera:camera-view:$camerax")
    implementation("androidx.activity:activity:1.9.3")
}

// Fail release builds clearly instead of producing an unsigned / debug-signed app.
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any { it.project == project && it.name.contains("Release") &&
        (it.name.startsWith("assemble") || it.name.startsWith("bundle") || it.name.startsWith("package")) }
    if (buildsRelease && !hasReleaseKey) {
        throw GradleException(
            "Release signing key missing: create android/key.properties (see the top of android/app/build.gradle.kts)."
        )
    }
}
