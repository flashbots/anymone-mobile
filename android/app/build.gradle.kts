plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "net.flashbots.anymone"
    compileSdk = 35
    defaultConfig {
        // The Play Integrity policy pins this package name and the signing
        // certificate digest, so changing either is a signed-config change.
        applicationId = "net.flashbots.anymone"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += listOf("arm64-v8a") }
    }
    sourceSets["main"].kotlin.srcDir("src/main/kotlin")
    buildFeatures { compose = true }
    composeOptions { kotlinCompilerExtensionVersion = "1.5.14" }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(project(":core"))
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation(platform("androidx.compose:compose-bom:2024.09.02"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    // Play Integrity standard requests; needed once the Play Console app entry exists.
    implementation("com.google.android.play:integrity:1.4.0")
}
