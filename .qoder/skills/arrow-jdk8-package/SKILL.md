---
name: arrow-jdk8-package
description: Adapt and package Apache arrow-java / arrow-adbc as JDK8 二方包 (plain + shaded jars, plus JNI natives for c-data/dataset/orc) into the local Maven repository. Use when building, rebuilding, or troubleshooting the JDK8 arrow-java (v19.0.0-jdk8-SNAPSHOT) or arrow-adbc (0.25.0-jdk8-SNAPSHOT) artifacts, the maven-shade relocation config (tianshu.shaded_v19_0_0), dependency downgrades for Java 8, or the arrow-cpp JNI native build on macOS arm64 / Linux x86_64.
---

# arrow-jdk8-package

## Overview

Produces the JDK8 二方包 set for arrow-java and arrow-adbc into `~/.m2`:
plain jars, `shaded`-classifier jars (third-party relocated to
`tianshu.shaded_v19_0_0.*` so consumers never clash with their own libs), and
JNI-enabled `arrow-c-data` / `arrow-dataset` / `arrow-orc` jars embedding
`libarrow_*_jni.<dylib|so>`.

Read `references/build-guide.md` for the full adaptation checklist, per-module
shade design, JNI build steps and every environment workaround. This file is
the quick-run reference.

## Prerequisites

- JDK 8 at `JAVA_HOME=/Users/zhonggu/Library/Java/JavaVirtualMachines/liberica-jdk-8.jdk/Contents/Home`
  (any JDK8 works; set `JAVA_HOME` accordingly).
- Maven 3.8.x. arrow-adbc's enforcer demands Maven>=3.9 → always pass `-Denforcer.skip=true` for adbc.
- macOS arm64 host for the mac natives; Linux x86_64 natives via `dev/jdk8/build-jni-linux-x86_64.sh`.
- Network: github release/archive downloads are throttled/blocked here. Route
  arrow-cpp BUNDLED deps through `https://gh-proxy.com/<github-url>` (see guide §5).

## Quick run (macOS, base Java artifacts)

```bash
export JAVA_HOME=/Users/zhonggu/Library/Java/JavaVirtualMachines/liberica-jdk-8.jdk/Contents/Home
cd <arrow-java>
mvn install -ntp -T 1C -DskipTests -Dmdep.analyze.skip=true -Drat.skip=true -Dcyclonedx.skip=true
cd <arrow-adbc>/java
mvn install -ntp -Dmaven.test.skip=true -Denforcer.skip=true -Drat.skip=true \
    -Dmdep.analyze.skip=true -Dcyclonedx.skip=true
```

`-DskipTests`/`-Dmaven.test.skip` are required: surefire argLines use JDK9+
`--add-opens/--add-reads` and many tests use Java9+ APIs.

## JNI natives (macOS arm64)

Already-produced natives live under `/tmp/arrow-jni-dist/lib/<name>/aarch_64/`.
To rebuild, follow `references/build-guide.md` §5 (arrow-cpp static via
gh-proxy → merge absl+utf8_range → JNI cmake → package). Then package the three
modules:

```bash
cd <arrow-java>
mvn install -ntp -Parrow-jni -pl c,dataset,adapter/orc \
  -Darrow.cpp.build.dir=/tmp/arrow-jni-dist/lib \
  -Darrow.c.jni.dist.dir=/tmp/arrow-jni-dist/lib \
  -Dmaven.test.skip=true -DskipTests -Dmdep.analyze.skip=true -Drat.skip=true -Dcyclonedx.skip=true
```

Linux x86_64: run `dev/jdk8/build-jni-linux-x86_64.sh` (self-contained; re-applies
the gh-proxy patch and the absl/utf8_range merge with `ar -M`).

## Key invariants (do not break)

- Relocation prefix is `tianshu.shaded_v19_0_0` everywhere (was mistakenly
  `dlink` once; never reintroduce). `org.apache.arrow.*` and `slf4j` are NEVER
  relocated/embedded.
- `arrow-vector` shade must keep `createDependencyReducedPom=false` (main
  artifact is the plain jar and needs `arrow-format` transitively).
- flight-core embeds+relocates grpc/netty(pure-java)/guava/protobuf/jackson;
  JNI netty artifacts (tcnative, transport-native-*) are excluded (not relocatable).
- flight-sql / adbc-driver-flight-sql REWRITE io.grpc/io.netty refs (classes come
  from flight-core:shaded) rather than re-embedding them.
- adbc-driver-flight-sql filters `META-INF/services/java.sql.Driver` from the
  embedded flight-sql-jdbc-core (avatica-backed, would fail ServiceLoader).
- JNI C++ uses `JNI_VERSION_1_8` (JDK8 JVM rejects `JNI_VERSION_10`).

## Verify

```bash
unzip -Z1 <jar> | grep -c '^tianshu/shaded_v19_0_0/'   # relocated class count
unzip -Z1 <jar> | grep -cE '^io/grpc/'                 # expect 0 in flight-core-shaded
unzip -Z1 <jar> | grep -E '\.dylib$|\.so$'             # JNI native present
```

## Resources

- `references/build-guide.md` — full JDK8 adaptation checklist, dependency
  downgrades, per-module shade design, JNI build + all workarounds, pitfalls.
- `../../../dev/jdk8/build-jni-linux-x86_64.sh` — reproducible Linux x86_64 JNI build.
