plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.pcspeaker.pc_speaker"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.pcspeaker.pc_speaker"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 只编译 arm64，大幅减小 APK 体积
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // 【v3.13】原生 JPEG 编码器（libjpeg-turbo）
    // 采集链路里最贵的一步就是 NV21 → JPEG，Android 自带的
    // YuvImage.compressToJpeg 在 720p 上要 50~90 ms/帧，直接把帧率卡死在
    // 20 fps 上下。换成 NEON 加速的 libjpeg-turbo 后这一步通常快 3~6 倍。
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            // 只留一个版本，避免 AGP 去找不存在的 build type 目录
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
