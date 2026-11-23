pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "AutoZhuyin"

// :core is plain Kotlin/JVM (the shared input logic, testable anywhere).
// :app is the Android input method; it needs the Android SDK. Build only the core with
//   ./gradlew -Pautozhuyin.coreOnly=true :core:test
include(":core")
if (providers.gradleProperty("autozhuyin.coreOnly").orNull != "true") {
    include(":app")
}
