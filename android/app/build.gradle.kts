plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningDir = rootProject.file("../../pixdraft-signing")
val releasePasswordFile = releaseSigningDir.resolve("android-release.pass")
val releasePassword = providers.fileContents(layout.file(providers.provider { releasePasswordFile })).asText

android {
    namespace = "com.dinosaur.imagegen"
    // flutter_local_notifications 要求 compileSdk 37。
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications 依赖 desugaring，见插件 README。
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = providers.gradleProperty("imageGenApplicationId").getOrElse("com.dinosaur.imagegen")
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        multiDexEnabled = true
        targetSdk = flutter.targetSdkVersion
        // 通用包和按 ABI 拆分的包使用相同版本号，可相互覆盖安装。
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = releaseSigningDir.resolve("android-release.p12")
            storeType = "PKCS12"
            storePassword = releasePassword.orNull?.trim().orEmpty()
            keyAlias = "pixdraft"
            keyPassword = storePassword
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
