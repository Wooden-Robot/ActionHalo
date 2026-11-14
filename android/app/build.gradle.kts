import java.util.Properties

plugins { id("com.android.application") }

val releaseSigningProperties = Properties().apply {
    val propertiesFile = rootProject.file("signing/keystore.properties")
    if (propertiesFile.isFile) propertiesFile.inputStream().use { load(it) }
}
val releaseSigningConfigured = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !releaseSigningProperties.getProperty(it).isNullOrBlank() }

android {
    namespace = "com.actionhalo.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.actionhalo.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 57
        versionName = "0.11.21"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    signingConfigs {
        create("release") {
            storeFile = releaseSigningProperties.getProperty("storeFile")?.let { rootProject.file(it) }
            storePassword = releaseSigningProperties.getProperty("storePassword")
            keyAlias = releaseSigningProperties.getProperty("keyAlias")
            keyPassword = releaseSigningProperties.getProperty("keyPassword")
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    lint { abortOnError = true }
    buildFeatures { buildConfig = true }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    doFirst {
        check(releaseSigningConfigured) {
            "Release signing is required. Configure android/signing/keystore.properties using keystore.properties.example."
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
