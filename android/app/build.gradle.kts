plugins { id("com.android.application") }

android {
    namespace = "com.actionhalo.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.actionhalo.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 41
        versionName = "0.11.5"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    lint { abortOnError = true }
    buildFeatures { buildConfig = true }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
