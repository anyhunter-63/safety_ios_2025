plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.civilsafety.app"

    compileSdk = 36
//    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.civilsafety.app"
        minSdk = 24
        targetSdk = 36

        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 🔐 release 서명 설정 (하드코딩 버전)
    signingConfigs {
        create("release") {
            // ⚠ 여기 패스워드를 keytool에서 입력한 실제 비밀번호로 바꿔줄 것
            storeFile = file("upload-keystore.jks")   // android/app 기준 경로
            storePassword = "tkfkdgkwk11@#"
            keyAlias = "upload"
            keyPassword = "tkfkdgkwk11@#"          // 보통 storePassword와 같게 했을 것
        }
    }

    buildTypes {
        debug {
            // debug 기본 설정
        }
        release {
            // ✅ 우리가 만든 release 키로 서명
            signingConfig = signingConfigs.getByName("release")

            // 🔥 코드/리소스 축소 (Flutter 기본 스타일)
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }
}

dependencies {
    implementation("com.google.android.gms:play-services-location:21.3.0")
}

flutter {
    source = "../.."
}
