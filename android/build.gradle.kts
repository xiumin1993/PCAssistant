allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// ---- 自动补丁：修正插件 compileSdk 版本 ----
// flutter_pcm_sound 插件的 build.gradle 写死了 compileSdkVersion 33，
// 但它依赖的 AndroidX 库要求至少 34。这里在 Gradle 读取插件配置之前，
// 直接把文件里的 33 改成 36，避免手动去 pub cache 改文件。
subprojects {
    if (project.name == "flutter_pcm_sound") {
        val buildFile = project.layout.projectDirectory.file("build.gradle").asFile
        if (buildFile.exists()) {
            val content = buildFile.readText()
            val patched = content.replace("compileSdkVersion 33", "compileSdkVersion 36")
            if (patched != content) {
                buildFile.writeText(patched)
                println("[Patch] flutter_pcm_sound: compileSdkVersion 33 → 36")
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
