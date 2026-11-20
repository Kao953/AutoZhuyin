plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
}

val repoRoot = rootProject.projectDir.parentFile

tasks.test {
    // Shared data made by windows/tools/build_data.py, and the Python/Swift parity fixtures.
    systemProperty("autozhuyin.data", System.getenv("AUTOZHUYIN_DATA") ?: "$repoRoot/windows/autozhuyin/data")
    systemProperty("autozhuyin.parity", System.getenv("AUTOZHUYIN_PARITY") ?: "$repoRoot/training/parity-fixtures.json")
    maxHeapSize = "1g"
    testLogging {
        events("failed")
        showStandardStreams = true
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
