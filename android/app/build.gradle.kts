import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Relative storeFile paths resolve from android/; absolute external paths work too.
val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = Properties()
if (signingPropertiesFile.isFile) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}
val requiredSigningFields = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val missingSigningFields = requiredSigningFields.filter {
    signingProperties.getProperty(it).isNullOrBlank()
}
val productionStoreFile = signingProperties.getProperty("storeFile")
    ?.takeIf { it.isNotBlank() }?.let { rootProject.file(it) }
val productionStoreExists = productionStoreFile?.isFile == true
val validateProductionSigning = tasks.register("validateProductionSigning") {
    group = "verification"
    description = "Require local production signing credentials for release builds."
    doLast {
        if (missingSigningFields.isNotEmpty()) {
            throw GradleException(
                "Production signing required: configure android/key.properties with " +
                    "non-empty fields: ${missingSigningFields.joinToString()}. " +
                    "Release builds never fall back to debug signing."
            )
        }
        if (!productionStoreExists) {
            throw GradleException("Production signing required: storeFile must reference an existing keystore.")
        }
    }
}
tasks.configureEach {
    if (name == "preReleaseBuild") {
        dependsOn(validateProductionSigning)
    }
}

android {
    namespace = "com.trismart.pos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.trismart.pos"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = "TRISMART POS"
    }

    signingConfigs {
        create("release") {
            storeFile = productionStoreFile
            storePassword = signingProperties.getProperty("storePassword")
            keyAlias = signingProperties.getProperty("keyAlias")
            keyPassword = signingProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appLabel"] = "TRISMART POS DEV"
        }
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

flutter {
    source = "../.."
}
