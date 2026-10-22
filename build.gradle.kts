import com.android.build.api.dsl.LibraryExtension
import com.lagradost.cloudstream3.gradle.CloudstreamExtension
import org.gradle.api.plugins.JavaPluginExtension
import org.gradle.kotlin.dsl.register
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile
import java.io.File as JFile

buildscript {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
        maven(uri("local-repo"))
    }
    dependencies {
        classpath("com.android.tools.build:gradle:9.1.1")
        classpath("com.github.recloudstream.gradle:gradle:32895aedb6")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.0")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}

// -----------------------------------------------------------------------
// Seed the CloudStream gradle plugin's API-jar cache with our vendored copy.
//
// The plugin looks for its API at
//   <gradleUserHome>/caches/cloudstream/cloudstream/cloudstream.jar
// and downloads it from the MOVING "pre-release" GitHub release tag whenever
// that file is absent. CloudStream re-uploads that asset on every pre-release
// build, so a clean CI runner picks up different API bytes than a developer
// machine that already has the file cached - the same source then compiles to
// different classes.dex debug metadata, every .cs3 gets a new fileHash, and
// CloudStream re-downloads all plugins for no functional change.
//
// Copying the vendored jar into that exact cache location BEFORE the plugin is
// applied makes the download a no-op, so local and CI builds are reproducible.
// This mirrors how the repo already vendors the gradle plugin itself under
// local-repo/. See the long comment in subprojects { } for how to bump it.
// -----------------------------------------------------------------------
fun pinCloudstreamApiJar(rootDir: JFile, gradleUserHome: JFile) {
    val vendoredApi = JFile(rootDir, "local-repo/cloudstream-api/pre-release/classes.jar")
    if (!vendoredApi.isFile) {
        logger.lifecycle("No vendored CloudStream API jar - using the upstream download.")
        return
    }
    val cacheJar = JFile(gradleUserHome, "caches/cloudstream/cloudstream/cloudstream.jar")
    // Only copy when the bytes actually differ, so we do not invalidate caches.
    val sameFile = cacheJar.isFile &&
        cacheJar.length() == vendoredApi.length() &&
        cacheJar.inputStream().use { a ->
            vendoredApi.inputStream().use { b -> a.readBytes().contentEquals(b.readBytes()) }
        }
    if (sameFile) return
    cacheJar.parentFile.mkdirs()
    vendoredApi.copyTo(cacheJar, overwrite = true)
    logger.lifecycle("Pinned CloudStream API jar -> $cacheJar")
}

pinCloudstreamApiJar(rootDir, gradle.gradleUserHomeDir)

fun Project.cloudstream(configuration: CloudstreamExtension.() -> Unit) =
    extensions.getByName<CloudstreamExtension>("cloudstream").configuration()

fun Project.android(configuration: LibraryExtension.() -> Unit) {
    extensions.getByName<LibraryExtension>("android").apply {
        project.extensions.findByType(JavaPluginExtension::class.java)?.apply {
            toolchain { languageVersion.set(JavaLanguageVersion.of(17)) }
        }
        configuration()
    }
}

subprojects {
    apply(plugin = "com.android.library")
    apply(plugin = "com.lagradost.cloudstream3.gradle")

    cloudstream {
        setRepo(System.getenv("GITHUB_REPOSITORY") ?: "https://github.com/KSHITIJ8473/raghav")
        authors = listOf("KSHITIJ8473")

        // ------------------------------------------------------------------
        // Pin the CloudStream API jar.
        //
        // By default the gradle plugin resolves
        //   https://github.com/recloudstream/cloudstream/releases/download/pre-release/classes.jar
        // "pre-release" is a MOVING tag: CloudStream re-uploads that asset on
        // every pre-release build, so two builds of identical source produce
        // different classes.dex debug metadata, every .cs3 gets a new
        // fileHash, and CloudStream re-downloads all plugins for no reason.
        // It also makes builds non-reproducible, because CI would download
        // whatever was uploaded most recently rather than what local uses.
        //
        // Only the "pre-release" tag publishes classes.jar (the versioned tags
        // v4.8.0/v4.7.0/... do not), so pinning a version string cannot work -
        // the plugin ignores it and hardcodes the moving tag. Instead we vendor
        // the exact jar we build against and seed the plugin's own cache with it
        // below, so local and CI always compile against identical API bytes.
        //
        // TO UPDATE the API on purpose:
        //   1. download the new classes.jar:
        //      https://github.com/recloudstream/cloudstream/releases/download/pre-release/classes.jar
        //   2. overwrite local-repo/cloudstream-api/pre-release/classes.jar
        //   3. update the sha256 in tools/cloudstream-api.lock.json
        //   4. bump the 'version' of every module you want users to re-download
        // tools/build-repo.ps1 verifies the vendored jar against that lock file,
        // so an accidental or partial replacement fails the build loudly.
        // ------------------------------------------------------------------
    }

    android {
        namespace = "com.laddu100"
        compileSdk = 36
        defaultConfig { minSdk = 21 }
        lint { targetSdk = 36 }
        compileOptions {
            sourceCompatibility = JavaVersion.VERSION_11
            targetCompatibility = JavaVersion.VERSION_11
        }
        tasks.withType<KotlinJvmCompile> {
            compilerOptions {
                jvmTarget.set(JvmTarget.JVM_11)
                freeCompilerArgs.addAll(
                    "-Xno-call-assertions",
                    "-Xno-param-assertions",
                    "-Xno-receiver-assertions",
                    "-Xskip-metadata-version-check"
                )
            }
        }
    }

    dependencies {
        val implementation by configurations
        val cloudstream by configurations
        val testImplementation by configurations
        cloudstream("com.lagradost:cloudstream3:pre-release")
        testImplementation("com.lagradost:cloudstream3:pre-release")
        testImplementation("junit:junit:4.13.2")
        implementation(kotlin("stdlib"))
        implementation("com.github.Blatzar:NiceHttp:0.4.18")
        implementation("org.jsoup:jsoup:1.22.2")
        implementation("androidx.annotation:annotation:1.10.0")
        implementation("org.jspecify:jspecify:1.0.0")
        implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.13.1")
        implementation("com.fasterxml.jackson.core:jackson-databind:2.13.1")
        implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
        implementation("org.mozilla:rhino:1.8.1")
        implementation("me.xdrop:fuzzywuzzy:1.4.0")
        implementation("com.google.code.gson:gson:2.14.0")
        implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
        implementation("org.bouncycastle:bcpkix-jdk18on:1.84")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
