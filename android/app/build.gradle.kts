import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// One monotonic code across the universal APK and Play AAB.
// The old Flutter ABI offsets reached 6129 in private candidates.
// Flutter 3.41.7 applies ABI offsets after Android Components callbacks. A late
// output override is already locked by AGP; reject split builds instead of
// producing codes that could prevent a later universal/Play update.
require(project.findProperty("split-per-abi")?.toString()?.toBoolean() != true) {
    "Honey supports universal APKs only; remove --split-per-abi (all three ABIs are included)"
}
val honeyBaseBuild = flutter.versionCode.toLong()
val honeyDistributionCode = 10_000L + honeyBaseBuild
require(honeyBaseBuild >= 2129L && honeyDistributionCode <= 2_100_000_000L) {
    "Android distribution versionCode is outside the supported range"
}

val keyProps = Properties()
val keyFile = rootProject.file("key.properties")
if (keyFile.exists()) keyProps.load(FileInputStream(keyFile))

android {
    namespace = "ru.honeyvpn.proxy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        create("release") {
            keyAlias = keyProps["keyAlias"] as String?
            keyPassword = keyProps["keyPassword"] as String?
            storeFile = keyProps["storeFile"]?.let { file(it) }
            storePassword = keyProps["storePassword"] as String?
        }
    }

    defaultConfig {
        applicationId = "ru.honeyvpn.proxy"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = honeyDistributionCode.toInt()
        versionName = flutter.versionName
    }

    flavorDimensions += "distribution"

    productFlavors {
        create("direct") {
            dimension = "distribution"
            // APK distribution: self-update download, REQUEST_INSTALL_PACKAGES in manifest
        }
        create("play") {
            dimension = "distribution"
            // Google Play AAB: no REQUEST_INSTALL_PACKAGES, update opens Play Store
        }
    }

    buildTypes {
        configureEach {
            // Universal APKs and Play AABs retain all three supported ABIs.
            ndk {
                abiFilters.clear()
                abiFilters += setOf("armeabi-v7a", "arm64-v8a", "x86_64")
            }
        }
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
}

flutter {
    source = "../.."
}

// Native CLI cores are reviewed build inputs, not large checked-in binaries.
// Preparation verifies both ABI/components before replacing any executable;
// validation also runs when Gradle regards preparation outputs as up to date.
val honeyRepository = rootProject.projectDir.parentFile
val honeyCorePython = providers.gradleProperty("honeyCorePython")
    .orElse(if (System.getProperty("os.name").startsWith("Windows")) "python" else "python3")
val prepareAndroidCores by tasks.registering(Exec::class) {
    workingDir(honeyRepository)
    commandLine(honeyCorePython.get(), "-B", "scripts/prepare_android_cores.py",
        "--cache-dir", "build/android-core-cache", "--download")
    inputs.files("../../core-lock.json", "../../scripts/core_manifest.py",
        "../../scripts/prepare_android_cores.py", "../../scripts/validate_android_cores.py")
    outputs.files("src/main/jniLibs/armeabi-v7a/libsingbox.so",
        "src/main/jniLibs/armeabi-v7a/libtun2socks.so",
        "src/main/jniLibs/arm64-v8a/libsingbox.so",
        "src/main/jniLibs/x86_64/libsingbox.so",
        "src/main/jniLibs/arm64-v8a/libtun2socks.so",
        "src/main/jniLibs/x86_64/libtun2socks.so")
}
val validateAndroidCores by tasks.registering(Exec::class) {
    dependsOn(prepareAndroidCores)
    workingDir(honeyRepository)
    commandLine(honeyCorePython.get(), "-B", "scripts/validate_android_cores.py")
}
tasks.named("preBuild") { dependsOn(validateAndroidCores) }
