plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val repoRoot: File = rootProject.projectDir.parentFile

// One version for every platform: Resources/Info.plist (scripts/bump-version.sh updates it).
val plist = repoRoot.resolve("Resources/Info.plist").readText()
fun plistValue(key: String): String =
    Regex("<key>$key</key>\\s*<string>([^<]*)</string>").find(plist)?.groupValues?.get(1)
        ?: error("$key missing from Resources/Info.plist")

// Release signing from the environment (CI secrets); without it only debug builds are signed.
val keystorePath: String? = System.getenv("ANDROID_KEYSTORE")

android {
    namespace = "com.autozhuyin.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.autozhuyin.android"
        minSdk = 26
        targetSdk = 35
        versionName = plistValue("CFBundleShortVersionString")
        versionCode = plistValue("CFBundleVersion").toInt()
    }

    signingConfigs {
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (keystorePath != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/imeAssets").get().asFile)

    packaging {
        resources.excludes += "META-INF/*.kotlin_module"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core"))
}

// Shared data from windows/tools/build_data.py (the English dictionary must come from
// macOS's /usr/share/dict/words to behave like the other versions), plus the licenses.
val dataDir = repoRoot.resolve("windows/autozhuyin/data")
val copyImeAssets by tasks.registering(Copy::class) {
    doFirst {
        check(dataDir.resolve("english-dict.txt").exists()) {
            "$dataDir is missing: run python3 windows/tools/build_data.py first"
        }
    }
    from(dataDir) {
        include("lexicon.txt", "english-common.txt", "english-dict.txt", "english-bigram.json", "classifier-weights.json")
    }
    from(repoRoot) {
        include("THIRD_PARTY_LICENSES.txt", "LICENSE")
    }
    into(layout.buildDirectory.dir("generated/imeAssets"))
}
tasks.named("preBuild") { dependsOn(copyImeAssets) }
