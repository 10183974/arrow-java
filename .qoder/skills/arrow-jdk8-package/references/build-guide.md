# arrow-java / arrow-adbc JDK8 适配与二方包打包构建 — 详细方案

记录把 Apache arrow-java、arrow-adbc 适配到 JDK8 并打包成二方包（plain + shaded + JNI native）装入本地 Maven 仓库的完整方案与所有环境 workaround。

## 0. 目标与产物

版本：
- arrow-java → `v19.0.0-jdk8-SNAPSHOT`（基线 tag `v19.0.0`，分支 `release-19.0.0-jdk8`）
- arrow-adbc → `0.25.0-jdk8-SNAPSHOT`（基线 tag `apache-arrow-adbc-25-rc0`，分支 `release-25-jdk8`）
- arrow monorepo（cpp）基线 `apache-arrow-25.0.1`，仅用于构建 JNI native，不产出二方包

17 个二方包（装入 `~/.m2`）：

| # | 构件 | 形态 |
|---|------|------|
| 1 | arrow-memory-core | plain |
| 2 | arrow-memory-unsafe | shaded |
| 3 | arrow-memory-netty | shaded |
| 4 | arrow-memory-netty-buffer-patch | shaded |
| 5 | arrow-vector | shaded |
| 6 | arrow-vector | plain |
| 7 | arrow-compression | shaded |
| 8 | arrow-jdbc | shaded |
| 9 | arrow-dataset | plain + JNI native |
| 10 | arrow-orc (org.apache.arrow.orc) | plain + JNI native |
| 11 | arrow-c-data | plain + JNI native |
| 12 | flight-core | shaded |
| 13 | flight-sql | shaded |
| 14 | adbc-core | shaded |
| 15 | adbc-sql | shaded |
| 16 | adbc-driver-jdbc | shaded |
| 17 | adbc-driver-flight-sql | shaded |

额外（覆盖对齐参考工程）：arrow-format-shaded、flight-sql-jdbc-core-shaded。

## 1. 环境事实

- JDK8：`/Users/zhonggu/Library/Java/JavaVirtualMachines/liberica-jdk-8.jdk/Contents/Home`
- Maven 3.8.6。arrow-adbc 的 enforcer 要求 Maven>=3.9 → adbc 构建必须 `-Denforcer.skip=true`。
- macOS arm64（host）。Linux x86_64 native 只能在该平台构建（本机无 Docker）。
- 网络：`github.com/.../releases/download/*` 与 `/archive/*` 直连被限速（~14KB/s 或 302 后 0 字节）。
  `https://gh-proxy.com/<github-url>` 可达 ~11MB/s。`archive.apache.org`/`dlcdn.apache.org` 直连可用。
  `ghcr.io`（brew bottle）可用。git over SSH 正常。
- cmake 4.4.2。arrow-cpp 需 >=3.25；cmake4 移除了 <3.5 策略 → 传 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`。
- arrow-cpp 内置 `THIRDPARTY_MIRROR_URL`(apache.jfrog.io) 已失效(404)，仅作 fallback。

## 2. JDK8 代码适配清单

源码级（arrow-java / arrow-adbc 通用）：
- 删除所有 `module-info.java`。
- `List.of/Set.of/Map.of` → `Arrays.asList` 等。
- `var x = ...` → 显式类型。
- `Map.entry(k,v)` → `new AbstractMap.SimpleImmutableEntry<>(k,v)`。
- `Objects.requireNonNullElse(a,b)` → `a != null ? a : b`。
- `URLDecoder.decode(s, Charset)`（Java10+）→ `decode(s, charset.name())` 并 catch `UnsupportedEncodingException`。
- interface 内 `private` 方法 → 去掉 private（隐式 public static）。
- `@Deprecated(forRemoval=,since=)` → 纯 `@Deprecated`。
- `Files.writeString` → `Files.write`；`Predicate.not` → lambda。
- JDK8 javac 泛型推断弱：`List<?>` 取出后直接 `(int) obj` 报 CAP#1，需经 `(Integer)`/`((Number)x).intValue()` 中转。

依赖降级（Java11 字节码 → Java8）：
- logback 1.5.x → 1.3.15；mockito 5.x → 4.11.0（测试）。
- caffeine 3.x → 2.9.3（`expireAfterWrite(Duration)` 是 3.x API，2.x 用 `(long,TimeUnit)`）。
- checker-qual 4.x → 3.53.1。
- protobuf 对齐 arrow 的 4.33.4（避免跨 shaded jar 版本冲突）。
- avro 1.12.1 / parquet-variant 1.17.0 无 Java8 版本 → 从 reactor 排除 `arrow-variant`、`adapter/avro`、`performance`（均非交付物）。

构建插件：
- spotless-maven-plugin 2.44.4/3.x 是 Java11 字节码，JDK8 无法加载（skip 参数在类加载后才生效，无效）。
  arrow-java 在 bom 的 spotless-check execution 设 `<phase>none</phase>` 解绑；adbc 的 spotless 无 execution 不会跑。
- JNI C++：`JNI_VERSION_10` → `JNI_VERSION_1_8`（JDK8 JVM 拒绝 1.10，否则 native 加载失败）。

## 3. pom 关键改动

- `maven.compiler.source/target=8`，**删除** `maven.compiler.release`（JDK8 javac 不支持 release）。
- 各模块 parent/project 版本 → `*-jdk8-SNAPSHOT`。
- maven-shade-plugin 3.6.0（Java8 字节码）进 pluginManagement。
- shade 通用配置：`shadedArtifactAttached=true` + `shadedClassifierName=shaded`（主构件保持 plain）。
- 重定位前缀：`tianshu.shaded_v19_0_0`（用户工程命名空间；曾误用 dlink，已全量替换）。
- `createDependencyReducedPom`：
  - **arrow-vector 必须 false** —— 主构件是 plain jar，运行期需要 arrow-format；DRP=true 会剥离 arrow-format 导致 arrow-orc 等编译不到 `org.apache.arrow.flatbuf.Message`。
  - 其余模块 true/false 视主构件是否需要被剥离的传递依赖；交付模型用 `*:*` 排除传递依赖，DRP 影响有限。
- 永不重定位/内嵌：`org.apache.arrow.*`、`org.slf4j:*`。

各模块 shade 设计：
- vector：内嵌 arrow-format(不重定位)+flatbuffers(重定位)。
- memory-unsafe/netty/buffer-patch：内嵌自身需要的少量依赖；netty **不重定位**（buffer-patch 类在 io.netty.buffer 包内需包私有访问）。
- compression：内嵌+重定位 `org.apache.commons`(commons-compress)；zstd-jni 运行时提供不内嵌。
- jdbc：内嵌+重定位 `com.fasterxml.jackson`。
- flight-core：内嵌+重定位 io.grpc / io.netty(纯java) / com.google.common / com.google.thirdparty / com.google.protobuf / com.fasterxml.jackson / javax.annotation；**排除** netty-tcnative-boringssl-static 与 netty-transport-native-*（JNI 不可重定位）；加 ServicesResourceTransformer（grpc ServiceLoader）。
- flight-sql：内嵌 guava/protobuf/commons-cli；**重写** io.grpc 引用（类由 flight-core:shaded 提供）。
- format：内嵌+重定位 flatbuffers。
- flight-sql-jdbc-core：内嵌+重定位 avatica/caffeine/checker-qual/commons-io/gson；重写 grpc/netty/guava/protobuf/jackson；ServicesResourceTransformer。
- adbc-core/sql：内嵌+重定位 checker-qual。
- adbc-driver-jdbc：内嵌 adbc-driver-manager + checker-qual（driver-manager 非独立交付物）。
- adbc-driver-flight-sql：内嵌 caffeine/checker-qual/gson/flight-sql-jdbc-core/adbc-driver-manager；重写 grpc/netty/guava/protobuf/jackson；**过滤** `META-INF/services/java.sql.Driver`（flight-sql-jdbc-core 的 avatica 驱动，避免 ServiceLoader 提前加载 avatica 类）。

## 4. 构建命令

arrow-java 基础 reactor（产出 1-8,12,13 + format/jdbc-core shaded）：
```bash
JAVA_HOME=<jdk8> mvn install -ntp -T 1C -DskipTests \
  -Dmdep.analyze.skip=true -Drat.skip=true -Dcyclonedx.skip=true
```
JNI 三模块（产出 9,10,11，需先有 native，见 §5）：
```bash
JAVA_HOME=<jdk8> mvn install -ntp -Parrow-jni -pl c,dataset,adapter/orc \
  -Darrow.cpp.build.dir=<jni-dist>/lib -Darrow.c.jni.dist.dir=<jni-dist>/lib \
  -Dmaven.test.skip=true -DskipTests -Dmdep.analyze.skip=true -Drat.skip=true -Dcyclonedx.skip=true
```
arrow-adbc（产出 14-17）：
```bash
JAVA_HOME=<jdk8> mvn install -ntp -Dmaven.test.skip=true -Denforcer.skip=true \
  -Drat.skip=true -Dmdep.analyze.skip=true -Dcyclonedx.skip=true
```
注意：必须全 reactor 跑，勿用 `-rf` 续跑（test-compile 不 install 上游构件，续跑会找不到新版本上游）。

## 5. JNI native 构建

macOS arm64（已验证）/ Linux x86_64（脚本 `dev/jdk8/build-jni-linux-x86_64.sh`）步骤一致：

1. **arrow-cpp 静态构建**（BUNDLED 依赖走 gh-proxy）：
   - 补丁：`perl -pi -e 's{https://github\.com/}{https://gh-proxy.com/https://github.com/}g' cpp/cmake_modules/ThirdpartyToolchain.cmake`
     （无 GIT_REPOSITORY，全是 tarball，URL_HASH 仍匹配；orc/thrift 走 dlcdn 无需代理）。
   - configure：`-DARROW_BUILD_STATIC=ON -DARROW_DEPENDENCY_SOURCE=BUNDLED`，
     开 `DATASET/SUBSTRAIT/ORC/PARQUET/CSV/JSON/COMPUTE/FILESYSTEM`，
     关 `GANDIVA(需LLVM)/FLIGHT/S3/HDFS/GCS/AZURE`；`-DCMAKE_POLICY_VERSION_MINIMUM=3.5`、`-DCMAKE_UNITY_BUILD=ON`。
   - dataset JNI 需要 `ArrowDataset`+`ArrowSubstrait`（故 SUBSTRAIT=ON）；orc JNI 需 `Arrow`。
2. **合并 absl + utf8_range** 进 `libarrow_bundled_dependencies.a`：
   arrow-cpp 把它们建成独立 FetchContent 静态库且不并入/不安装，JNI 链接报 undefined `absl::lts_*`/`utf8_range_*`。
   - macOS：`libtool -static -o merged.a bundled.orig.a <absl/*.a> <protobuf/third_party/utf8_range/libutf8*.a>`
   - Linux：`ar -M` MRI 脚本（create/addlib.../save/end）。
3. **JNI cmake**（arrow-java 根 CMakeLists）：
   `-DCMAKE_PREFIX_PATH=<cpp-dist> -DARROW_JAVA_JNI_ENABLE_C/DATASET/ORC=ON -DARROW_JAVA_JNI_ENABLE_GANDIVA=OFF -DBUILD_TESTING=OFF`。
   - macOS 链接需 `-DCMAKE_SHARED_LINKER_FLAGS="-framework CoreFoundation -framework Security"`（absl timezone）；Linux 不需要。
   - 产物：`<jni-dist>/lib/{arrow_cdata_jni,arrow_dataset_jni,arrow_orc_jni}/<arch>/lib*_jni.{dylib,so}`，arch: mac arm64=`aarch_64`，linux=`x86_64`。
4. **Maven 打包**：`-Darrow.cpp.build.dir=<jni-dist>/lib -Darrow.c.jni.dist.dir=<jni-dist>/lib`，
   模块资源 glob `**/*arrow_<name>_jni.*` 会命中 `<jni-dist>/lib/<name>/<arch>/`。
   dataset 的 protobuf 生成已解绑（`<phase>none</phase>`）：其 proto 路径 `../../cpp/src/jni/dataset/proto` 只存在于 arrow-cpp 19，且生成类 main 代码并不使用（AceroSubstraitConsumer 走 ByteBuffer+JNI）。
5. 自包含校验：`otool -L`/`ldd` 应只有系统库（arrow 静态链入）；JDK8 `System.load` 通过即 `JNI_OnLoad`(1.8) 被接受。

## 6. 验证

- 重定位：`unzip -Z1 <jar> | grep -c '^tianshu/shaded_v19_0_0/'` >0 且 `grep -c '^dlink/'` =0、关键包无未重定位残留（如 flight-core-shaded 的 `^io/grpc/`=0）。
- JNI：jar 内含 `<name>/<arch>/lib*_jni.*`；JDK8 下 `System.load` 成功。
- 17 个构件齐全：逐一 `ls ~/.m2/.../<version>/*-shaded.jar` / `.jar`。

## 7. 常见坑

- zsh 标量变量不按空白分词 → 多文件参数用数组 `files=(...)` 或显式列表。
- BSD/macOS sed 不支持 `\b` → 用 perl 负向后顾 `(?<![a-zA-Z0-9_.])`。
- `mvn ... | grep` 的退出码是 grep 的 → 用日志里 `BUILD SUCCESS/FAILURE` 判定。
- `createDependencyReducedPom=true` + `shadedArtifactAttached=true` 会剥离主(plain)构件仍需要的传递依赖 → vector 设 false。
- github release 限速 → gh-proxy.com；apache jfrog 镜像已死。
- Java11 字节码的构建插件（spotless）在 JDK8 连类都加载不了，skip 参数无效 → 解绑 execution。
- adbc enforcer 要 Maven3.9 → skip。
- 跨 shaded jar 同一三方库必须用同一重定位前缀+同一版本（否则类路径冲突）。
