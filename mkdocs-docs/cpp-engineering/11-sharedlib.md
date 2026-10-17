# 共享库实战语法：生产工程里用到的 Groovy

> 本节解决：声明式 `pipeline {}` 骨架会写了之后，真实生产流水线靠什么复用？——共享库 `vars/` 函数。本节把 生产工程里实际用到的 Groovy 语法点完整过一遍：`def call()`、闭包传参、三平台命令封装、函数间协作、凭证传递，**每个语法点都有真实出处**。

## 为什么流水线要拆共享库

先看这套共享库服务的规模：SDK 构建、QT 应用、依赖编译、代码签名、符号上传、资源打包等——如果每套都从头写，会出现什么？

- 清理环境、拉代码、打包、发通知、提取符号——**90% 的代码逐字重复**；
- 改一次通知格式，N 个文件都要改，漏一个行为就不一致；
- 每个文件的 300 行里，真正有项目差异的只有十几行编译命令。

共享库（Shared Library）就是答案：**把公共逻辑抽到一个独立 Git 仓库，所有流水线用一行 `@Library` 引用**。

```
base_lib/                        # 共享库仓库（库名 base_lib）
└── vars/                        # 目录名固定：vars 下的文件自动暴露为全局函数
    ├── createSymbols.groovy     # 三平台符号提取
    ├── winSignFile.groovy       # Windows 代码签名往返
    ├── commitGit.groovy         # 制品提交回 Git
    ├── sendNotification.groovy  # 企业微信通知
    ├── uploadPackage.groovy     # 制品上传，返回下载 URL
    ├── uploadSymbols.groovy     # 符号上传
    ├── zip.groovy / unzip.groovy / compressArchive.groovy / expandArchive.groovy
    ├── execute.groovy           # 跨平台命令统一入口
    ├── removeDir.groovy / artifacts.groovy / funcTest.groovy
    └── ...
```

```groovy
// 任意 Jenkinsfile 第一行引用，之后就能直接调所有 vars 函数
@Library('base_lib@master') _;
```

**关键认知**：声明式 `pipeline {}` 是"框架"，`vars/` 是"函数库"。`vars/xxx.groovy` 文件会暴露为全局函数 `xxx()`——这就是 Jenkins 的变量/函数自动映射机制。**你的流水线复杂度应该往 vars/ 里收，而不是堆在 Jenkinsfile 里**。

## 1. `def call()`：文件名即函数名

机制：Jenkins 执行 `createSymbols(a, b)` 时，实际是调用 `vars/createSymbols.groovy` 里的 `call()` 方法。**`call()` 的参数就是函数的参数，返回值就是函数的返回值**。四种写法覆盖工程里的全部形态：

### 形态一：全参数（最常用）

```groovy
// vars/createSymbols.groovy
def call(String search_dir, String symbols_dir) {
    if (!search_dir || !symbols_dir) {
        error("search_dir and symbols_dir parameters are required")   // 参数校验：早失败
    }
    echo "开始创建符号文件: search_dir=${search_dir}, symbols_dir=${symbols_dir}"
    dir(search_dir) { /* ... */ }
}
```

### 形态二：带默认值

```groovy
// vars/sendNotification.groovy
def call(String status, String stage, String message, String robot = '<wecom_robot_key>') {
    // 前三个必传，robot 不传用默认值——不同项目可用不同机器人，同项目不用每次写
}

// vars/uploadPackage.groovy
def call(String branch, String directory, String buildNumber = '') {
    // 空串默认值 + 运行时兜底
    if (buildNumber) { url += "&build=${buildNumber}" }
}
```

### 形态三：带返回值（函数不只能 echo，还能把结果交回流水线）

```groovy
// vars/uploadPackage.groovy：上传后返回下载 URL 列表
def call(String branch, String directory, String buildNumber = '') {
    def urls = []
    dir(directory) {
        if (isUnix()) {
            def output = sh(returnStdout: true, script: """...curl 上传并解析 JSON...""")
            urls = output.trim().split('\n').findAll { it }   // 空行过滤
        } else {
            def output = powershell(returnStdout: true, script: """...""")
            urls = output.trim().split('\n').findAll { it }
        }
    }
    urls.each { echo "下载URL: ${it}" }
    return urls
}
```

### 形态四：文件内的私有辅助函数

```groovy
// vars/winSignFile.groovy——文件内可以定义普通方法，只在当前文件可见
def call(String search_dir, String timestamp_url, String cert_thumbprint) {
    // ...主流程...
    upload_package(package_file)      // 调用本文件私有方法
}

def upload_package(String package_file) {   // 注意：没有 def call，是普通 def 方法
    // 只被本文件内部调用，不暴露为共享库函数
}
```

> 语法要点：**共享库函数入口必须是 `def call`**；文件内其他 `def 方法名` 只是私有辅助函数。想新增一个全局函数？新建一个 `.groovy` 文件即可，命名即函数名。

**工程实践：参数校验用 `error()` 早失败**。`createSymbols`、`zip`、`compressArchive` 都在函数开头校验参数：

```groovy
if (!source_dir || !zip_file) {
    error("source_dir and zip_file parameters are required")
}
```

理由：共享库函数会被流水线调用，调用方传错参数时，**错误必须发生在函数入口**（一眼看到），而不是让脚本跑到一半才以莫名其妙的报错暴露。`error()` 会直接让构建失败，比 `echo` 警告强得多。

## 2. 闭包与作用域：dir / withEnv / timeout / script

Groovy 的闭包（Closure）是 Jenkins 流水线的核心语法。**闭包 = 一段可以被传入、被延迟执行的代码块**。生产工程里四种最常见的用法：

### 用法一：`dir {}` 切换工作目录

```groovy
// 三个平台共用一个逻辑，差异用参数区分（生产 Jenkinsfile）
dir(env.SRC_DIR) {
    checkout([...])          // 在这个目录下执行
    if (plat == 'linux') {
        sh "sed -i 's|https://github.com/|${env.GHPROXY}https://github.com/|g' CMakeLists.txt"
    }
}
// 出块后回到原工作目录
```

`dir {}` 是闭包最经典的用法：**块内代码的工作目录被临时切换，块结束自动还原**，不需要手动 cd/pushd/popd。

### 用法二：闭包作为参数（最值得抄的写法）

```groovy
// 生产 Jenkinsfile 尾部——把"每个组合要执行的逻辑"传进函数
def foreachBuild(String platform, Closure call) {
    def arch_list = platform == 'macos' ? ['arm64', 'x86_64'] : ['x86_64']
    ["Debug", "RelWithDebInfo"].each { buildType ->
        arch_list.each { arch ->
            call(arch, buildType)          // 函数内通过 call 执行传入的闭包
        }
    }
}

// 调用方：编译 stage 里
foreachBuild(plat, { arch, buildType ->
    def build_dir = "${WORKSPACE}/${env.BUILD_DIR}/sdk/${buildType}_${arch}"
    removeDir(build_dir)
    // ...cmake 配置与编译...
})
```

**为什么这么设计**：macOS 要编 `arm64` + `x86_64` 两套架构 × Debug/RelWithDebInfo 两种构建类型，共 4 个组合。把"遍历组合"抽成 `foreachBuild`，把"每个组合干什么"用闭包传入——**循环逻辑只写一遍，每个 stage 的差异收敛到闭包内部**。这正是第 10 章 `buildStage` 能保持干净的原因。

### 用法三：`withEnv {}` 临时注入环境变量

```groovy
// vars/execute.groovy——给命令注入工具链 PATH
def call(String command) {
    if (isUnix()) {
        withEnv(['PATH+EXTRA=/usr/local/bin:/opt/homebrew/bin']) {
            sh (script: """#!/bin/bash
            ${command}
            """)
        }
    } else {
        withEnv(['PATH+EXTRA=C:\\Program Files (x86)\\Windows Kits\\10\\Debuggers\\x64']) {
            powershell (script: command)
        }
    }
}
```

`PATH+EXTRA=` 是 Jenkins 环境变量的特殊写法：**在现有 PATH 后面追加，而不是覆盖**。Windows 节点把 Debuggers 目录加进去，`symstore`、`cdb` 等调试工具才能被直接调用，不用写全路径。

### 用法四：`script {}` 包住脚本式代码

```groovy
stage('统一提交仓库') {
    steps {
        script {                    // 声明式里写 Groovy 逻辑，必须包 script {}
            commitGit("${env.CACHE_DIR}/*_binary.zip", params.SDK_GIT_REPO, ...)
        }
    }
}
```

**作用域注意点**（写共享库最容易踩的认知坑）：
- `script {}` 块内 `def` 的变量**只在当前块内可见**，块外访问不到；
- 闭包能捕获外层变量（上面 `foreachBuild` 的 `arch`、`buildType` 对闭包内可见）——这是闭包的优势；
- `env.*` / `params.*` / `WORKSPACE` 全局可读，**跨 stage 传值优先用它们，而不是 def 变量**。

## 3. 三平台命令封装：isUnix 分发与内嵌脚本转义

C++ 流水线跑在 Linux / Windows / macOS 上，同一个意图往往要写三份命令。共享库的职责就是**把"同一意图、三份实现"封装在函数内部**，调用方永远只写一行。

### 3.1 最高频模式：`isUnix()` 分发

```groovy
// vars/zip.groovy——同一函数，两套实现
def call(String source_dir, String zip_file) {
    if (!source_dir || !zip_file) {
        error("source_dir and zip_file parameters are required")
    }
    dir(source_dir) {
        if (isUnix()) {
            sh """
                zip -q -9 -r '${zip_file}' * || true
            """
        } else {
            powershell """
                compress-archive -Path * -DestinationPath '${zip_file}' -Force -CompressionLevel Optimal
                exit 0
            """
        }
    }
}
```

`isUnix()` 是 Jenkins 内置判断（Linux/macOS 返回 true，Windows 返回 false）。**注意 `|| true` / `exit 0`**：`zip` 在没有匹配文件时返回非零码，`Compress-Archive` 在 PowerShell 里偶发退出码异常——显式兜底，避免"命令本身成功、退出码误导构建失败"。

### 3.2 捕获命令输出：`returnStdout: true`

```groovy
// 三平台取 CPU 核数（生产 Jenkinsfile，编译 stage）
// Linux / macOS：
number=\$(nproc)                                     // macOS 用 system_profiler 解析
cmake --build ${build_dir} --config ${buildType} --parallel \${number}

// Windows：wmic 取逻辑核数（bat 里 for 变量要写 %%）
for /f "skip=1 tokens=2 delims==" %%a in ('wmic cpu get NumberOfLogicalProcessors /value') do set cpu=%%a
```

```groovy
// 把输出变成值：uploadPackage 里用 python3 解析上传接口的 JSON 响应
def output = sh(returnStdout: true, script: """
    response=\$(curl -s -X POST -F "file=@\$file" --connect-timeout ${timeoutSec} '${url}')
    download_url=\$(echo "\$response" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['url'])" 2>/dev/null || echo '')
    [ -n "\$download_url" ] && echo "\$download_url"
""")
urls = output.trim().split('\n').findAll { it }
```

**`returnStdout: true` 让命令的 stdout 成为 Groovy 变量**，然后 `trim().split('\n').findAll { it }` 是清洗三件套：去首尾空白 → 按行切分 → 过滤空行。

### 3.3 内嵌脚本的转义三连（写共享库必背）

Groovy 里用三引号 `"""` 写多行 bash / PowerShell 时，**所有 `$` 都会被 Groovy 先做字符串插值**。要让 bash / PowerShell 自己解释 `$`，必须转义。这是 生产工程踩得最频繁的坑：

| 场景 | 写法 | 出处 |
|---|---|---|
| bash 变量 | `\$file`、`\$(command)` | createSymbols、uploadPackage、compressArchive |
| PowerShell 变量 | `\$_`、`\$progressPreference` | uploadSymbols、funcTest、winSignFile |
| bat for 变量 | `%%a`（不是 `%a`） | 生产 Jenkinsfile 取核数 |

```groovy
// 反例：不转义会怎样
sh """echo $HOME"""          // Groovy 先插值：值被替换或为空
// 正例
sh """echo \$HOME"""         // bash 自己解释 $HOME
```

同理，Groovy 想插值的变量**不要**转义：`"${WORKSPACE}"`、`${url}`、`${timeoutSec}` 直接写。**一句话规则：Groovy 的变量不转义，bash/PowerShell 的变量必须转义**。

### 3.4 同一意图、三份实现（C++ 跨平台的日常）

```groovy
// 生产 Jenkinsfile 代码拉取 stage：替换 GitHub 下载地址为代理
if (plat == 'linux') {
    sh "sed -i 's|https://github.com/|${env.GHPROXY}https://github.com/|g' CMakeLists.txt"
} else if (plat == 'windows') {
    powershell """ \$content = Get-Content -Raw CMakeLists.txt
    \$content -replace 'https://github.com/', '${env.GHPROXY}https://github.com/' | Set-Content CMakeLists.txt -Encoding UTF8
    """
} else if (plat == 'macos') {
    sh "sed -i '' 's|https://github.com/|${env.GHPROXY}https://github.com/|g' CMakeLists.txt"
}
```

注意 macOS 的 `sed -i ''`：BSD sed 的 `-i` 后必须跟备份后缀参数，和 Linux GNU sed 不一样——**这就是为什么平台差异要收敛在函数/分支里，而不是散落在 9 套 Jenkinsfile 中**。

## 4. 函数间协作：往返模式与下游触发

共享库的价值不只是"一个函数一件事"，更是**函数之间怎么组合**。

### 4.1 往返模式：winSignFile 的签名链路

Windows 代码签名要走外部签名服务器，本地文件必须"送出去 → 签完 → 拿回来"。生产工程把它拆成清晰的往返：

```groovy
// vars/winSignFile.groovy（脱敏，主流程）
def call(String search_dir, String timestamp_url, String cert_thumbprint) {
    def cachedir = "${WORKSPACE}/sign_cache"
    def package_file = "${WORKSPACE}/sign/tmp.tar.bz2"
    removeDir(cachedir)

    // ① 收集：把目录下所有 exe/dll 复制到临时目录（PowerShell 递归）
    // ② 打包：compressArchive(cachedir, package_file)      ← 调用另一个共享库函数
    // ③ 上传签名：upload_package(package_file)             ← 文件内私有函数
    // ④ 解包还原：expandArchive(package_file, cachedir)    ← 调用另一个共享库函数
    // ⑤ 移回原目录（PowerShell 递归）
    removeDir(cachedir)
}
```

**语法要点**：
- 共享库函数之间可以直接互相调用（`compressArchive(...)` / `expandArchive(...)`），不需要额外声明；
- 大函数拆成"收集 → 压缩 → 上传 → 解包 → 还原"五步，每一步可单独调试、单独复用；
- 临时目录用完 `removeDir` 清掉——**不留垃圾是共享库的卫生习惯**。

### 4.2 触发下游：build()

```groovy
// vars/commitGit.groovy：制品提交后触发下游提交任务
def call(String key, String gitRepo, String branchName, String credentialsId,
         String workDir, String extract_dir = "", String SDKName = "",
         String build_number = "", String job_name = "", Boolean is_split = false) {
    if (build_number == "") { build_number = "${BUILD_NUMBER}" }   // 空串兜底
    if (job_name == "")     { job_name = "${JOB_NAME}" }

    build(job: '<commit_job>',
        parameters: [
            string(name: 'UPSTREAM_JOB_NAME', value: job_name),
            string(name: 'UPSTREAM_BUILD_NUMBER', value: build_number),
            string(name: 'SDK_GIT_REPO', value: gitRepo),
            // ...
        ],
        wait: true)
}
```

`build()` 是流水线串联的标准姿势。**两个细节值得抄**：
- `build_number == ""` 时回退到 `env.BUILD_NUMBER`——参数可选 + 环境变量兜底；
- `wait: true` 表示等下游跑完（commitGit 场景需要确认提交成功）；Jenkinsfile 里的下游触发用 `wait: false`（触发完就继续，不阻塞）。

### 4.3 跨 job 拿制品：copyArtifacts

```groovy
// vars/uploadSymbols.groovy：从另一个 job 的某次构建里拿符号包
def call(String jobName, String buildNumber, String directory, Boolean isRelease = true) {
    def cacheDir = 'symbols'
    removeDir(cacheDir)
    copyArtifacts filter: "${directory}/*symbols.zip",
                 fingerprintArtifacts: true,
                 selector: specific(buildNumber),     // 精确到某次构建
                 target: cacheDir,
                 projectName: jobName
    // ...上传符号到符号服务...
}
```

**跨 job 协作链**：C++ 流水线编完符号 → `copyArtifacts` 按 `specific(buildNumber)` 精确取 → 上传符号服务。`buildNumber` 就是上下游之间的"接口协议"。

## 5. 环境与凭证：env / params / withCredentials

### 5.1 env.* 和 params.* 怎么分工

```groovy
// 生产 Jenkinsfile——顶部配置一览
environment {                    // env.*：路径、仓库等"少变"配置
    BUILD_DIR = 'Build'
    INSTALL_DIR = 'Install'
    CACHE_DIR  = 'CACHE'
    VCPKG_ROOT_DIR = 'VCPKG'
    GHPROXY = 'https://gh-proxy.com/'
}
parameters {                     // params.*：每次构建可能变的输入
    string(name: 'BRANCH_NAME', defaultValue: 'master', description: 'SDK分支名称')
    booleanParam(name: 'CLEAN_BUILD', defaultValue: false, description: '清洁编译,开这个编译时间非常长，想好再点')
    string(name: 'CREDENTIALS_ID', defaultValue: '<credentials-id>', description: 'SDK仓库凭证ID')
}
```

**取舍**：路径、镜像、代理这类"配置项"放 `environment {}`；分支、凭证 ID、清洁编译开关这类"每次构建的输入"放 `parameters {}`。函数内部统一读 `env.*` / `params.*`，不重复传参。

### 5.2 敏感凭证必须 withCredentials

```groovy
// 生产 Jenkinsfile 依赖编译 stage
withCredentials([
    gitlabApiToken(credentialsId: params.GIT_TOKEN_ID, variable: 'GIT_TOKEN')
]) {
    withEnv(["VCPKG_ROOT=${vcpkg_root}", "PRIVATE_GIT_TOKEN=${GIT_TOKEN}"]) {
        foreachBuild(plat, { arch, buildType ->
            // 依赖编译要用私有 Git 仓库的 token
        })
    }
}
```

**凭证链路**：Jenkins 凭证存储 → `withCredentials` 注入变量 → `withEnv` 传给子进程环境 → 构建脚本读取。**凭证不进代码、不进日志、不进产物**。

## 6. 踩过的坑（真实记录）

1. **Groovy 插值吞掉 bash 变量**：`sh """echo $HOME"""` 里 `$HOME` 被 Groovy 插值替换（通常是空），脚本行为完全不可预期。规则：**Groovy 的变量不转义，bash/PowerShell 的变量必须 `\$`**。
2. **bat 的 `%` 在 Groovy 里写 `%%`**：`for /f ... %a` 写成 `%%a`，否则 Groovy 解析报错或行为错乱（生产 Jenkinsfile 取核数）。
3. **wmic 在新版 Windows 已废弃**：`wmic cpu get NumberOfLogicalProcessors` 在 Windows 11 / Server 2025 可能不可用，生产环境要换 PowerShell `(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors`。
4. **必须先 `call vcvars64.bat` 再编译**：不加载 VC 环境变量，`cl.exe`、`rc.exe` 全找不到，报错五花八门，最误导排查方向。
5. **git dubious ownership**：Jenkins 服务账号 checkout 后 git 拒绝操作，需要在命令前 `git config --global --add safe.directory *`。
6. **BSD sed 与 GNU sed 语法不同**：macOS 的 `sed -i ''` 必须带备份后缀参数，Linux 直接 `sed -i`。
7. **PowerShell 上传不静默进度条会巨慢**：`$progressPreference = 'silentlyContinue'` 必须在 UploadFile 前设置（uploadSymbols / uploadPackage 都有）。
8. **curl 不加 `--fail` 会假成功**：HTTP 4xx/5xx 时 curl 仍返回 0，脚本继续跑以为上传成功——必须 `--fail`（uploadSymbols 里配置了）。
9. **闭包里的变量共享陷阱**：循环里创建闭包，闭包捕获的是变量而非值——`foreachBuild` 通过函数参数 `call(arch, buildType)` 传值，规避了这个问题。
10. **临时目录不清**：签名、上传等中间产物不清理，构建机磁盘会悄悄被吃满——`removeDir` 兜底。

## 设计原则：一步只干一件事

流水线不是"一个大脚本"，而是**有序的一步一步，每步只干一件事**。生产工程里一条构建流水线长这样：

```
[环境清理] → [代码拉取] → [VCPKG 配置] → [依赖编译] → [编译] → [打包] → [符号处理] → [统一提交] → [通知]
```

每一步一个 stage，一个 stage 只做一件事。为什么这个看似朴素的原则，是生产流水线的第一设计原则？

**1. 出错定位从"翻日志"变成"看阶段"**。构建失败时，Jenkins UI 直接告诉你"VCPKG 配置"这一步红了——问题范围瞬间从 300 行缩到这一步。如果所有事情都塞进一个 `build_all.sh`，失败只能从头翻日志，在几百行输出里找线索。

**2. 每一步有明确的产物和验收**。环境清理完 = 目录干净；代码拉取完 = 源码就位；打包完 = zip 存在。每步结束都能检查"这一步真的做完了吗"，而不是等到最后一起失败。

**3. 可跳过、可重试、可单独执行**。依赖编译通过后写 `finished` 哨兵，下次直接跳过（第 8 章）；某一步失败，重跑只重做失败的 stage；想单独验证符号提取，只跑那一个 stage 就行。

**4. 与共享库的分工**：stage 管"步骤的组织"（顺序、成败、产物），`vars/` 函数管"单步的能力"（平台差异、命令封装）。一个 stage 内部可以调用多个函数（编译 stage 里 `execute` 配置 + `execute` 编译），但**一个 stage 仍然只对一件事负责**。

对比"在仓库里放一个很强大的脚本"：

| 维度 | 一步只干一件事（Jenkins stage） | 一个大脚本（build_all.sh） |
|---|---|---|
| 失败定位 | UI 直接显示哪个 stage 红了 | 翻几百行日志自己找 |
| 部分重试 | 重跑失败的那个 stage | 整个脚本重跑 |
| 可观测性 | 每个 stage 独立日志、独立耗时 | 一个黑盒 |
| 缓存 / 跳过 | 结合哨兵文件跳过已完成步骤 | 要么全跑、要么手动开关 |
| 交接维护 | 新人看 stage 名就懂整条流程 | 要看脚本内部逻辑 |

**粒度把握**：不是越细越好。stage 的粒度是"逻辑上的一件事"——"依赖编译"是一个 stage（哪怕内部要遍历 4 个架构 × 构建类型组合，用 `foreachBuild` 收敛），"编译"是另一个 stage。把"依赖编译"拆成"编 fmt""编 spdlog""编 nlohmann-json"十几个 stage，反而没有意义。

这个设计原则和第 10 章 `buildStage` 的 stage 序列一一对应——**先想清楚"流水线分几步、每步做什么"，再写代码**。

## 反例：如果不拆共享库会怎样

把 16 个函数全部塞进一个 Jenkinsfile 会得到什么：

```groovy
// 反例示意（不要这样写）
def buildStage(String plat) {
    // 500 行：符号提取逻辑、签名逻辑、通知逻辑、缓存逻辑全部内联
    // 平台分支散落各处，改一处符号格式要在这个函数里找半天
    // 签名 key 硬编码在第 203 行，第 340 行又写了一次
}
```

- 9 套 Jenkinsfile 各有一份 500 行副本，改符号格式 = 改 9 个文件；
- 没有 `def call()` 边界，函数间传参靠全局变量，改一处影响全部；
- 无法单独测试：`createSymbols` 没法脱离流水线验证。

共享库的价值不是"少写几行"，而是**把变化收敛到一处、把不变复用到底**。

## 小结

| 语法点 | 真实出处 | 一句话要点 |
|---|---|---|
| `def call(...)` | 全部 vars/ 函数 | 文件名即函数名，参数即函数参数，返回值即函数返回值 |
| 参数默认值 + 空串兜底 | sendNotification / commitGit | 可选参数，运行时回退到 `env.*` |
| `error()` 参数校验 | createSymbols / zip / compressArchive | 入口早失败，别让错误跑一半才暴露 |
| 闭包 `dir {}` / `withEnv {}` / `timeout {}` | 全部 | 块结束自动还原，无需手动 cd / 还原环境 |
| 闭包作参数 | `foreachBuild(plat, { arch, buildType -> })` | 循环逻辑写一次，差异收敛到闭包内 |
| `isUnix()` 分发 | execute / zip / createSymbols / uploadSymbols | 同一意图三份实现，封装在函数内 |
| `returnStdout: true` | uploadPackage | 命令输出变变量，`trim().split('\n').findAll{}` 清洗 |
| `\$` / `\$_` / `%%` 转义 | createSymbols / uploadSymbols / 生产 Jenkinsfile | Groovy 不转义，bash/PS/bat 必须转义 |
| 函数互相调用 | winSignFile 往返模式 | 拆成收集→压缩→上传→解包→还原，可单步调试 |
| `build()` 下游触发 | commitGit / 生产 post | `wait: true` 等结果，`wait: false` 只触发 |
| `copyArtifacts` 跨 job | uploadSymbols | `specific(buildNumber)` 精确取某次构建制品 |
| `withCredentials` + `withEnv` | 生产依赖编译 | 凭证不进代码，经环境变量传给子进程 |

**核心一句话**：声明式 pipeline 管"流程骨架"，`vars/` 共享库管"能力封装"——把平台差异、凭证处理、缓存判断全部收进函数，Jenkinsfile 保持"一眼能读完"。

