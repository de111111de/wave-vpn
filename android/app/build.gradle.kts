plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val ksPath: String? = System.getenv("WAVE_KEYSTORE")

android {
    namespace = "com.wave.vpn"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.wave.vpn"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (ksPath != null) {
            create("wave") {
                storeFile = file(ksPath)
                storePassword = System.getenv("WAVE_KS_PASS")
                keyAlias = System.getenv("WAVE_KEY_ALIAS")
                keyPassword = System.getenv("WAVE_KEY_PASS")
            }
        }
    }

    buildTypes {
        release {
            // no WAVE_KEYSTORE secret -> debug key, still installable (but updates need the same CI key)
            signingConfig = if (ksPath != null) signingConfigs.getByName("wave") else signingConfigs.getByName("debug")
            isMinifyEnabled = false   // libbox is JNI/reflection heavy, R8 breaks it
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(files("libs/libbox.aar"))
    implementation("androidx.core:core-ktx:1.13.1")
}
