// Top-level build file
plugins {
    id("com.android.application") version "8.5.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.0" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.0.0" apply false
    id("com.google.protobuf") version "0.9.4" apply false
    id("com.google.dagger.hilt.android") version "2.51.1" apply false
    id("org.jetbrains.kotlin.kapt") version "2.0.0" apply false
}

allprojects {
    val buildRoot = System.getenv("GRADLE_BUILD_DIR") ?: "/tmp/droidlink-android-build"
    val projectFolder = if (path == ":") "root" else path.replace(":", "_")
    layout.buildDirectory.set(file("$buildRoot/$projectFolder"))
}
