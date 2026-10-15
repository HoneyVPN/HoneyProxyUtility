#!/usr/bin/env python3
"""Compile/run pure JVM Android session regressions using the existing Kotlin SDK."""
import argparse
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODULES = {"kotlin-compiler-embeddable", "kotlin-stdlib", "kotlin-reflect", "kotlin-script-runtime",
           "kotlin-daemon-embeddable", "kotlinx-coroutines-core-jvm", "annotations", "trove4j"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default=str(Path(os.environ["JAVA_HOME"]) / "bin/java") if "JAVA_HOME" in os.environ else shutil.which("java"))
    parser.add_argument("--compiler-directory", type=Path, help="Existing bundled Kotlin compiler jars")
    parser.add_argument("--cc", default=shutil.which("clang") or shutil.which("gcc"))
    parser.add_argument("--core", help="Optional verified host CLI for an actual local authentication check; never starts a TUN")
    parser.add_argument("--gradle-cache", type=Path, default=Path.home() / ".gradle/caches/modules-2/files-2.1")
    args = parser.parse_args()
    settings = (ROOT / "android/settings.gradle.kts").read_text()
    match = re.search(r'id\("org.jetbrains.kotlin.android"\)\s+version\s+"([0-9.]+)"', settings)
    if match is None:
        parser.error("Cannot determine the reviewed Android Kotlin plugin version")
    kotlin_version = match.group(1)
    if args.compiler_directory:
        jars = [path for path in args.compiler_directory.glob("*.jar") if any(path.name.startswith(name + "-") for name in MODULES)]
    else:
        jars = []
        # The reviewed compiler POM pins reflect independently of the compiler.
        # Resolve exact coordinates, so a reused CI cache cannot choose another
        # Kotlin/reflect runtime just because it happens to be present.
        coordinates = [("org.jetbrains.kotlin", name, "1.6.10" if name == "kotlin-reflect" and kotlin_version == "2.2.20" else kotlin_version)
                       for name in MODULES if name.startswith("kotlin-")]
        coordinates += [("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.8.0"),
                        ("org.jetbrains", "annotations", "13.0"),
                        ("org.jetbrains.intellij.deps", "trove4j", "1.0.20200330")]
        for group, module, version in coordinates:
            folder = args.gradle_cache / group / module
            matches = list((folder / version).glob("*/*.jar"))
            if not matches and module in ("annotations", "trove4j"):
                matches = list(folder.glob("*/*/*.jar"))
            if len(matches) > 1:
                parser.error(f"Ambiguous cached dependency {group}:{module}; provide an explicit bundled compiler directory")
            jars.extend(matches)
    compilers = [path for path in jars if re.fullmatch(r"kotlin-compiler-embeddable-[0-9.]+\.jar", path.name)]
    standard_libraries = [path for path in jars if re.fullmatch(r"kotlin-stdlib-[0-9.]+\.jar", path.name)]
    if not args.java or not args.cc or len(compilers) != 1 or len(standard_libraries) != 1:
        parser.error("Resolve the existing Android Gradle dependencies first, or provide the bundled compiler directory/Java")
    stdlib = standard_libraries[0]
    annotations = [path for path in jars if path.name.startswith("annotations-")]
    source = ROOT / "android/app/src/main/kotlin/ru/honeyvpn/proxy"
    with tempfile.TemporaryDirectory(prefix="honeyproxy-android-lifecycle-") as name:
        target = Path(name) / "checks.jar"
        subprocess.run([args.java, "-cp", os.pathsep.join(map(str, jars)), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                        "-no-stdlib", "-no-reflect", "-jvm-target", "17", "-classpath", os.pathsep.join(map(str, [stdlib] + annotations)),
                        "-d", str(target), str(source / "VpnSessionGate.kt"), str(source / "CoreReadinessProbe.kt"),
                        str(source / "NativeStopRequests.kt"),
                        str(source / "OwnedChildStatus.kt"),
                        str(source / "HoneyDiagnostics.kt"),
                        str(ROOT / "test/native/AndroidDiagnosticsCheck.kt"),
                        str(source / "VpnNotificationLabels.kt"),
                        str(ROOT / "test/native/AndroidLifecycleCheck.kt")], check=True, timeout=120)
        runtime = [args.java, "-cp", os.pathsep.join(map(str, [target, stdlib])), "ru.honeyvpn.proxy.AndroidLifecycleCheckKt"]
        if args.core:
            runtime.append(str(Path(args.core).resolve()))
        subprocess.run(runtime, check=True, timeout=30)
        native_source = ROOT / "android/app/src/main/cpp"
        native_target = Path(name) / "owned-child-check"
        subprocess.run([args.cc, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-DHONEY_OWNED_CHILD_TESTING", "-Wall", "-Wextra", "-Werror", "-pthread",
                        "-I", str(native_source), str(native_source / "owned_child.c"),
                        str(ROOT / "test/native/android_owned_child_check.c"), "-o", str(native_target)], check=True, timeout=30)
        subprocess.run([str(native_target)], check=True, timeout=30)
        latency_target = Path(name) / "latency-child-check"
        subprocess.run([args.cc, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror", "-pthread",
                        "-I", str(native_source), str(native_source / "latency_process.c"),
                        str(ROOT / "test/native/android_latency_process_check.c"), "-o", str(latency_target)], check=True, timeout=30)
        subprocess.run([str(latency_target)], check=True, timeout=30)


if __name__ == "__main__":
    main()
