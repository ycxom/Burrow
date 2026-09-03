import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名。`android/key.properties` 不入 git（见 .gitignore），
// CI 里由 workflow 从仓库 secrets 现写一份。
//
// **找不到就退回 debug 签名**，而不是让构建失败：没有密钥的人（刚 clone
// 下来想自己编一个装着玩）照样能 `flutter build apk --release`，
// 只是装出来的包和正式发布的那个签名不同、不能互相覆盖升级。
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.burrow"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.burrow"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只打这两个 ABI。armeabi-v7a 的 32 位机器已经不值得为它多背一份
        // rootfs（bootstrap 是按 ABI 分包的，多一个 ABI 就多几十 MB）。
        // x86_64 保留是为了模拟器 —— 没有它就没法在 CI 和模拟器上验证。
        externalNativeBuild {
            cmake {
                // pty.c 是纯 C，burrow_launch.c 也是。不需要 C++ 运行时，
                // 关掉能省下 libc++_shared.so（每 ABI 约 1MB）。
                arguments += listOf("-DANDROID_STL=none")

                // 这一份 abiFilters 约束 CMake 实际编译的 ABI。APK 级别的
                // 过滤由 Flutter 的 --target-platform / split ABI 控制；
                // 不要再加 defaultConfig.ndk.abiFilters，新版 Flutter 会把它
                // 判定为与 split ABI 冲突。
                abiFilters += listOf("arm64-v8a", "x86_64")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            // 必须解压到 nativeLibraryDir，否则 libburrow-launch.so 只是 APK 里的
            // 一段字节，exec 不了。代价是安装体积翻倍（APK 里一份 + 解压一份）。
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (hasReleaseKey) "release" else "debug",
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
