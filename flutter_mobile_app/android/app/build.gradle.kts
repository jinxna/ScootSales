import java.util.Base64
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The client this build is for, from --dart-define=FIREBASE_TARGET (the same
// define lib/firebase_options.dart reads). Flutter passes every --dart-define
// to Gradle as the "dart-defines" property: comma-separated base64 entries.
// Each client gets its own application ID and launcher label so both apps can
// be installed side by side. An unknown target fails the build instead of
// falling back to the supermarket app.
val firebaseTarget: String =
    (findProperty("dart-defines") as String?)
        ?.split(",")
        ?.filter { it.isNotBlank() }
        ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
        ?.lastOrNull { it.startsWith("FIREBASE_TARGET=") }
        ?.substringAfter("=")
        ?: "supermarket"
val clientApps =
    mapOf(
        "supermarket" to Pair("my.scootsales.app", "Scoot Sales"),
        "hardware" to Pair("my.scootsales.app.hardware", "Scoot Sales Hardware"),
    )
val (clientApplicationId, clientAppLabel) =
    clientApps[firebaseTarget]
        ?: throw GradleException(
            "Unknown FIREBASE_TARGET \"$firebaseTarget\". " +
                "Build with --dart-define=FIREBASE_TARGET=supermarket or hardware.",
        )

val releaseRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
val unsignedCiRelease = providers.gradleProperty("ciUnsignedRelease").orNull == "true"
val ciEnvironment = System.getenv("CI")?.equals("true", ignoreCase = true) == true
val unsignedCiReleaseAllowed = unsignedCiRelease && ciEnvironment
val signingPropertiesFile = rootProject.file("key.properties")
val releaseSigningProperties = if (releaseRequested && !unsignedCiRelease && signingPropertiesFile.isFile) {
    Properties().apply {
        FileInputStream(signingPropertiesFile).use { load(it) }
        listOf("storeFile", "storePassword", "keyAlias", "keyPassword").forEach { name ->
            if (getProperty(name).isNullOrBlank()) {
                throw GradleException("Release signing configuration is missing '$name' in android/key.properties.")
            }
        }
    }
} else {
    if (releaseRequested && unsignedCiRelease && !ciEnvironment) {
        throw GradleException("ciUnsignedRelease is permitted only when CI=true.")
    }
    null
}
if (releaseRequested && !unsignedCiRelease && releaseSigningProperties == null) {
    throw GradleException(
        "android/key.properties was not found. A release build is never signed with the debug key. " +
            "Create android/key.properties that points to the release keystore kept outside the repository.",
    )
}
val releaseKeystoreFile = releaseSigningProperties?.let { properties ->
    val propertiesFile = signingPropertiesFile
    val storePath = properties.getProperty("storeFile")
    val configuredStoreFile = File(storePath)
    val resolvedStoreFile = if (configuredStoreFile.isAbsolute) {
        configuredStoreFile
    } else {
        File(propertiesFile.parentFile, storePath)
    }
    if (!resolvedStoreFile.isFile) {
        throw GradleException("The release keystore listed in android/key.properties was not found.")
    }
    resolvedStoreFile
}

gradle.taskGraph.addTaskExecutionGraphListener(
    org.gradle.api.execution.TaskExecutionGraphListener { taskGraph ->
        val releaseVariantTask = taskGraph.allTasks.firstOrNull { task ->
            task.name.split(Regex("(?=[A-Z])")).any { it.equals("release", ignoreCase = true) }
        }
        if (releaseVariantTask != null && !releaseRequested && !unsignedCiReleaseAllowed) {
            if (unsignedCiRelease && !ciEnvironment) {
                throw GradleException("ciUnsignedRelease is permitted only when CI=true.")
            }
            throw GradleException(
                "Gradle selected release task '${releaseVariantTask.path}' without loading release signing configuration. " +
                    "Rerun with the full release task name, such as :app:assembleRelease.",
            )
        }
    },
)

android {
    namespace = "my.scootsales.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = clientApplicationId
        // AndroidManifest.xml reads the launcher label as @string/app_name.
        resValue("string", "app_name", clientAppLabel)
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (releaseSigningProperties != null) {
                signingConfig = signingConfigs.create("release").apply {
                    storeFile = releaseKeystoreFile
                        ?: throw GradleException("The validated release keystore path is unavailable.")
                    storePassword = releaseSigningProperties.getProperty("storePassword")
                    keyAlias = releaseSigningProperties.getProperty("keyAlias")
                    keyPassword = releaseSigningProperties.getProperty("keyPassword")
                }
            }
        }
    }
}

flutter {
    source = "../.."
}
