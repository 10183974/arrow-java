#!/usr/bin/env bash
#
# Reproducible build of the JDK8 arrow-java JNI二方包 for Linux x86_64:
#   arrow-c-data / arrow-dataset / arrow-orc  (plain jars embedding libarrow_*_jni.so)
#
# It rebuilds everything the macOS run needed, adapted for Linux x86_64:
#   1. arrow-cpp static build (BUNDLED deps routed through the gh-proxy.com mirror,
#      because direct github release/archive downloads are blocked/throttled here)
#   2. merge absl + utf8_range into libarrow_bundled_dependencies.a
#      (arrow-cpp builds them as separate FetchContent archives and does NOT export
#       them in the static Arrow* cmake targets -> JNI link fails with undefined
#       absl::/utf8_range_ symbols otherwise)
#   3. build the arrow-java JNI glue (c / dataset / adapter-orc) against that arrow-cpp
#      - source already carries the JDK8 fix JNI_VERSION_10 -> JNI_VERSION_1_8
#      - Linux needs no macOS frameworks (CoreFoundation/Security)
#   4. mvn install the full arrow-java on JDK8, then the 3 JNI modules with the
#      native resource dirs pointed at the built .so
#
# Prereqs on the Linux host:
#   - JDK 8 (javac/java 1.8)              -> set JDK8_HOME
#   - Maven 3.8+                           (mvn on PATH)
#   - cmake >= 3.25                        (cmake 4.x OK; we pass CMAKE_POLICY_VERSION_MINIMUM=3.5)
#   - a C++17 compiler (gcc >= 9 or clang), make, perl, patch, ar (binutils)
#   - internet access to gh-proxy.com + dlcdn.apache.org/archive.apache.org + Maven Central
#   - arrow-java source at $ARROW_JAVA_SRC  (branch release-19.0.0-jdk8)
#   - arrow-cpp  source at $ARROW_CPP_SRC   (apache/arrow release-25.0.1, the cpp/ dir's repo root)
#
# Usage:
#   JDK8_HOME=/path/to/jdk8 \
#   ARROW_JAVA_SRC=/path/to/arrow-java \
#   ARROW_CPP_SRC=/path/to/arrow \
#   ./build-jni-linux-x86_64.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
: "${JDK8_HOME:?set JDK8_HOME to a JDK 8 home}"
: "${ARROW_JAVA_SRC:?set ARROW_JAVA_SRC to the arrow-java checkout (release-19.0.0-jdk8)}"
: "${ARROW_CPP_SRC:?set ARROW_CPP_SRC to the arrow monorepo checkout (release-25.0.1) containing cpp/}"
WORK="${WORK:-/tmp/arrow-jni-linux-build}"
CPP_BUILD="$WORK/cpp-build"
CPP_PREFIX="$WORK/cpp-dist"          # arrow-cpp install prefix
JNI_BUILD="$WORK/jni-build"
JNI_PREFIX="$WORK/jni-dist"          # JNI natives install prefix
JOBS="${JOBS:-$(nproc)}"
GH_PROXY="${GH_PROXY:-https://gh-proxy.com/}"
ARCH_DIR="x86_64"                     # JniLoader normalizes amd64 -> x86_64
export JAVA_HOME="$JDK8_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

log(){ printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Prereq checks
# ---------------------------------------------------------------------------
log "Checking prerequisites"
[ -x "$JAVA_HOME/bin/javac" ] || die "javac not found at $JAVA_HOME/bin/javac"
"$JAVA_HOME/bin/javac" -version 2>&1 | grep -q "1\.8\." || die "JDK8_HOME is not a JDK 8 ($("$JAVA_HOME/bin/javac" -version 2>&1))"
command -v mvn   >/dev/null || die "mvn not on PATH"
command -v cmake >/dev/null || die "cmake not on PATH"
command -v perl  >/dev/null || die "perl not on PATH"
command -v ar    >/dev/null || die "ar (binutils) not on PATH"
[ -d "$ARROW_JAVA_SRC" ] || die "ARROW_JAVA_SRC not a dir: $ARROW_JAVA_SRC"
[ -f "$ARROW_CPP_SRC/cpp/CMakeLists.txt" ] || die "arrow-cpp not found at $ARROW_CPP_SRC/cpp"
cmake --version | head -1
mkdir -p "$WORK"

# ---------------------------------------------------------------------------
# 1. Route arrow-cpp BUNDLED github downloads through the mirror (idempotent)
# ---------------------------------------------------------------------------
log "Patching arrow-cpp ThirdpartyToolchain.cmake for gh-proxy mirror"
TT="$ARROW_CPP_SRC/cpp/cmake_modules/ThirdpartyToolchain.cmake"
cp -n "$TT" "$TT.orig" 2>/dev/null || true
if ! grep -q "gh-proxy.com/https://github.com/" "$TT"; then
  perl -pi -e "s{https://github\.com/}{${GH_PROXY}https://github.com/}g" "$TT"
  echo "  patched ($(grep -c "${GH_PROXY}https://github.com/" "$TT") github URLs)"
else
  echo "  already patched"
fi
# NOTE: orc/thrift come from dlcdn.apache.org / www.apache.org (reachable), no proxy needed.
# arrow-cpp's built-in THIRDPARTY_MIRROR_URL (apache.jfrog.io) is dead (404) and only a fallback.

# ---------------------------------------------------------------------------
# 2. Configure + build + install arrow-cpp (static, reduced feature set)
#    Features needed by the JNI: dataset(+substrait) / orc / c-data.
#    Deliberately OFF: gandiva (needs LLVM), flight, S3/HDFS/GCS/Azure (huge, unneeded).
# ---------------------------------------------------------------------------
log "Configuring arrow-cpp (static) -> $CPP_PREFIX"
rm -rf "$CPP_BUILD" "$CPP_PREFIX"
cmake -S "$ARROW_CPP_SRC/cpp" -B "$CPP_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DARROW_BUILD_SHARED=OFF -DARROW_BUILD_STATIC=ON \
  -DARROW_DEPENDENCY_SOURCE=BUNDLED -DARROW_DEPENDENCY_USE_SHARED=OFF \
  -DARROW_DATASET=ON -DARROW_SUBSTRAIT=ON -DARROW_ORC=ON -DARROW_PARQUET=ON \
  -DARROW_CSV=ON -DARROW_JSON=ON -DARROW_COMPUTE=ON -DARROW_FILESYSTEM=ON -DARROW_IPC=ON \
  -DARROW_GANDIVA=OFF -DARROW_FLIGHT=OFF -DARROW_S3=OFF -DARROW_HDFS=OFF \
  -DARROW_GCS=OFF -DARROW_AZURE=OFF \
  -DARROW_MIMALLOC=ON -DARROW_USE_CCACHE=OFF \
  -DARROW_BUILD_TESTS=OFF -DARROW_BUILD_BENCHMARKS=OFF \
  -DCMAKE_UNITY_BUILD=ON \
  -DCMAKE_INSTALL_PREFIX="$CPP_PREFIX" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5

log "Building arrow-cpp (this is the long step, -j$JOBS)"
cmake --build "$CPP_BUILD" --target install -j "$JOBS"

[ -f "$CPP_PREFIX/lib/libarrow_dataset.a" ] || die "arrow-cpp install missing libarrow_dataset.a"
[ -f "$CPP_PREFIX/lib/libarrow_substrait.a" ] || die "arrow-cpp install missing libarrow_substrait.a"

# ---------------------------------------------------------------------------
# 3. Merge absl + utf8_range into libarrow_bundled_dependencies.a (Linux: ar MRI)
#    Without this the JNI link fails on undefined absl::lts_* / utf8_range_* symbols.
# ---------------------------------------------------------------------------
log "Merging absl + utf8_range into libarrow_bundled_dependencies.a"
BUNDLED="$CPP_PREFIX/lib/libarrow_bundled_dependencies.a"
mapfile -t EXTRA_LIBS < <(find "$CPP_BUILD/_deps/absl-build" "$CPP_BUILD/_deps/protobuf-build" \
                             \( -name 'libabsl_*.a' -o -name 'libutf8*.a' \) 2>/dev/null)
[ "${#EXTRA_LIBS[@]}" -gt 0 ] || die "no absl/utf8_range archives found under $CPP_BUILD/_deps"
cp "$BUNDLED" "$WORK/bundled.orig.a"
MRI="$WORK/merge.mri"
{
  echo "create $WORK/bundled.merged.a"
  echo "addlib $WORK/bundled.orig.a"
  for a in "${EXTRA_LIBS[@]}"; do echo "addlib $a"; done
  echo "save"
  echo "end"
} > "$MRI"
ar -M < "$MRI"
cp "$WORK/bundled.merged.a" "$BUNDLED"
# verify the previously-undefined symbols are now DEFINED (T) in the merged archive
nm "$BUNDLED" 2>/dev/null | grep -qE "T _?(AbslInternalSpinLockWake|absl)" \
  && echo "  absl symbols present" || echo "  WARN: absl 'T' symbol not detected (check nm output)"
nm "$BUNDLED" 2>/dev/null | grep -qE "T _?utf8_range_IsValid" \
  && echo "  utf8_range symbols present" || echo "  WARN: utf8_range 'T' symbol not detected"

# ---------------------------------------------------------------------------
# 4. Build the arrow-java JNI natives (c / dataset / orc) against arrow-cpp
#    Linux: no macOS frameworks. JNI_VERSION is already 1_8 in the source.
# ---------------------------------------------------------------------------
log "Configuring arrow-java JNI -> $JNI_PREFIX"
rm -rf "$JNI_BUILD" "$JNI_PREFIX"
cmake -S "$ARROW_JAVA_SRC" -B "$JNI_BUILD" \
  -DCMAKE_PREFIX_PATH="$CPP_PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DARROW_JAVA_JNI_ENABLE_DEFAULT=OFF \
  -DARROW_JAVA_JNI_ENABLE_C=ON \
  -DARROW_JAVA_JNI_ENABLE_DATASET=ON \
  -DARROW_JAVA_JNI_ENABLE_ORC=ON \
  -DARROW_JAVA_JNI_ENABLE_GANDIVA=OFF \
  -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="$JNI_PREFIX" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5

log "Building arrow-java JNI (-j$JOBS)"
cmake --build "$JNI_BUILD" --target install -j "$JOBS"

for n in arrow_cdata_jni arrow_dataset_jni arrow_orc_jni; do
  so="$JNI_PREFIX/lib/${n}/${ARCH_DIR}/lib${n}.so"
  [ -f "$so" ] || die "missing native: $so"
  echo "  built: $so"
  # self-contained? (static arrow linked in -> no external libarrow*.so deps)
  if ldd "$so" 2>/dev/null | grep -qiE "libarrow|libprotobuf|libabsl|liborc"; then
    echo "  WARN: $so has external arrow/dep .so links (expected fully static):"
    ldd "$so" | grep -iE "libarrow|libprotobuf|libabsl|liborc" || true
  fi
done

# ---------------------------------------------------------------------------
# 5. Maven: install full arrow-java (JDK8), then the 3 JNI modules with natives
# ---------------------------------------------------------------------------
MVN_SKIP=( -Dmaven.test.skip=true -DskipTests -Dmdep.analyze.skip=true
           -Drat.skip=true -Dcyclonedx.skip=true -Dspotless.check.skip=true )

log "mvn install: arrow-java base reactor (JDK8)"
( cd "$ARROW_JAVA_SRC" && mvn install -ntp -T 1C "${MVN_SKIP[@]}" )

log "mvn install: JNI modules (c / dataset / adapter-orc) with natives from $JNI_PREFIX/lib"
( cd "$ARROW_JAVA_SRC" && mvn install -ntp -Parrow-jni -pl c,dataset,adapter/orc \
    -Darrow.cpp.build.dir="$JNI_PREFIX/lib" \
    -Darrow.c.jni.dist.dir="$JNI_PREFIX/lib" \
    "${MVN_SKIP[@]}" )

# ---------------------------------------------------------------------------
# 6. Verify the .so landed in the installed jars
# ---------------------------------------------------------------------------
log "Verifying JNI natives inside installed jars"
M2="${HOME}/.m2/repository/org/apache/arrow"
V="v19.0.0-jdk8-SNAPSHOT"
check_jar(){ # <jar> <expected-entry-substr>
  unzip -Z1 "$1" 2>/dev/null | grep -q "$2" \
    && echo "  OK   $(basename "$1") contains $2" \
    || die "$(basename "$1") MISSING $2"
}
check_jar "$M2/arrow-c-data/$V/arrow-c-data-$V.jar"        "arrow_cdata_jni/$ARCH_DIR/libarrow_cdata_jni.so"
check_jar "$M2/arrow-dataset/$V/arrow-dataset-$V.jar"      "arrow_dataset_jni/$ARCH_DIR/libarrow_dataset_jni.so"
check_jar "$M2/orc/arrow-orc/$V/arrow-orc-$V.jar"          "arrow_orc_jni/$ARCH_DIR/libarrow_orc_jni.so"

log "DONE. Linux x86_64 JNI二方包 installed to ~/.m2 (version $V)."
cat <<EOF

Next (optional): make the jars multi-platform.
  The jars now hold x86_64/*.so. To also ship the macOS arm64 build in the SAME jar,
  copy the aarch_64/*.dylib natives (from the macOS build's $JNI_PREFIX/lib) into a dir
  laid out as  <name>/aarch_64/lib<name>.dylib  and run, per module:
      jar uf arrow-c-data-$V.jar -C <mac-natives-dir> arrow_cdata_jni/aarch_64/libarrow_cdata_jni.dylib
  (a single jar may carry natives for many os/arch; JniLoader picks <name>/<arch>/<lib> at runtime.)

Reminder: the JDK8 branch release-19.0.0-jdk8 already carries the source fixes this
script relies on (JNI_VERSION_1_8, dataset protobuf generation unbound, arrow-vector
createDependencyReducedPom=false, reactor excludes for arrow-variant/avro/performance).
EOF
