# 完整 CI/CD 闭环：从提交到三平台发布

> 本节解决：前 19 章都是零件，这一章组装——一次代码提交如何走完全链路：Webhook 触发 → 三平台并行 → 依赖缓存 → 编译 → 打包 → 符号 → 制品提交 → 下游发布 → 通知。

## 零件都有了，怎么组装成一条流水线

前 19 章我们造了这些零件：

- **环境**：Docker（第 2 章）、Jenkins 主从节点（第 3/4 章）、C++ 工具链（第 1 章）；
- **构建**：CMake 工程骨架（第 5 章）、并发编译（第 6 章）、依赖缓存（第 8 章）；
- **流水线**：Pipeline 语法（第 9 章）、C++ 流水线（第 10 章）、并行（第 7 章）、共享库（第 12 章）；
- **容器**：构建镜像（第 14 章）、私有仓库（第 15 章）、compose 编排（第 16 章）、镜像管理（第 17 章）、流水线引用 Docker（第 18 章）。

这一节把它们串成一条完整链路——**从开发者 `git push` 到三平台产物交付**，中间不需要任何人干预。

## 全景：一次提交的完整旅程

```
开发者 git push
    ↓
GitLab Webhook（GenericTrigger，第 9 章）
    ↓
[Jenkins 主节点] 分配任务
    ↓
┌───────────────────── 三平台并行（第 7 章）─────────────────────┐
│  Linux (docker agent gccbuild)    Windows (msvcbuilder)    macOS (label) │
│   ├─ 环境清理（第 8 章）            ├─ 同左                 ├─ 同左      │
│   ├─ 拉代码 + 代理替换              ├─ 同左                 ├─ 同左      │
│   ├─ vcpkg 环境（finished 缓存）    ├─ 同左                 ├─ 同左      │
│   ├─ 依赖编译（架构×构建类型矩阵）    ├─ 同左                 ├─ 同左      │
│   ├─ SDK 编译（--parallel nproc）   ├─ vcvars64 + wmic      ├─ system_profiler │
│   ├─ 打包 zip + md5                ├─ 同左                 ├─ 同左      │
│   └─ 调试符号（createSymbols）      └─ symstore             └─ dSYM      │
└──────────────────────────────────────────────────────────────┘
    ↓ 三平台全部成功
[统一提交] commitGit 制品入 SDK 仓库（第 10 章）
    ↓
[符号上传] uploadSymbols → nginx 符号服务（第 19 章）
    ↓
[下游触发] build(job: '<pdb_commit_job>'/'<rc_builder_job>', wait: false)
    ↓
[通知] sendNotification 企业微信（第 12 章）
    ↓
[崩溃定位] 调试器按 Build ID/UUID/PDB 从符号服务下载符号（第 19 章）
```

## 组装：一条完整的 Jenkinsfile 骨架

把第 10/12/19 章的代码拼起来，就是完整闭环（脱敏后）：

```groovy
@Library('base_lib@master') _;
pipeline {
    agent none
    triggers {
        GenericTrigger(
            token: '<webhook_token>',
            genericVariables: [
                [key: 'BRANCH_NAME', value: '$.ref', regexpFilter: 'refs/heads/'],
                [key: 'GIT_REPO',    value: '$.project.http_url']
            ]
        )
    }
    parameters {
        string(name: 'BRANCH_NAME', defaultValue: 'master')
        booleanParam(name: 'CLEAN_BUILD', defaultValue: false, description: '全量重编依赖')
    }
    environment {
        BUILD_DIR = 'Build'; INSTALL_DIR = 'Install'; CACHE_DIR = 'CACHE'
        VCPKG_ROOT_DIR = 'VCPKG'; DEPS_INSTALL_DIR = 'DEPS_INSTALL'
    }
    stages {
        stage('并发构建') {
            parallel {
                stage("Linux")   { agent { docker { label 'linux'; image '<registry>/gccbuild:ubuntu'; alwaysPull true } }
                                   steps { script { buildStage('linux') } } }
                stage("Windows") { agent { docker { label 'windows'; image '<registry>/msvcbuilder:vs2019'; alwaysPull true } }
                                   steps { script { buildStage('windows') } } }
                stage("macOS")   { agent { label 'macos' }
                                   steps { script { buildStage('macos') } } }
            }
        }
        stage('统一提交仓库') {
            agent { label 'linux' }
            when { beforeAgent true; expression { currentBuild.currentResult == 'SUCCESS' } }
            steps { script {
                commitGit("${CACHE_DIR}/*_binary.zip", params.SDK_GIT_REPO,
                          params.SDK_BRANCH_NAME, params.CREDENTIALS_ID, "${WORKSPACE}/SDK")
            } }
        }
    }
    post {
        success {
            build(job: '<pdb_commit_job>', parameters: [
                string(name: 'UPSTREAM_BUILD_NUMBER', value: "${BUILD_NUMBER}"),
                string(name: 'UPSTREAM_SUB_DIRECTORY', value: env.CACHE_DIR)
            ], wait: false)
            sendNotification('SUCCESS', 'SDK', "编译完成，已提交 ${params.SDK_BRANCH_NAME}")
        }
        failure { sendNotification('FAILURE', 'SDK', '构建失败') }
    }
}
```

`buildStage` 就是第 10 章的函数（清理 → 拉取 → vcpkg → 依赖 → 编译 → 打包 → 符号），整条链路的复杂度全被它收敛。

## 链路中的关键设计（前文知识串联）

1. **提交与发布解耦**（第 10/20 章）：构建流水线只产出制品，`<pdb_commit_job>`/`<rc_builder_job>` 是独立下游任务——单点失败不影响已完成的构建；
2. **缓存分层**（第 8 章）：`finished` 哨兵 + `CLEAN_BUILD` 开关，日常构建快、发版构建稳；
3. **制品可追溯**（第 10/20 章）：产物带 `BUILD_NUMBER` + 平台名 + MD5 + fingerprint，下游拿到产物能回溯来源构建；
4. **失败必通知**（第 12 章）：每个失败路径 `sendNotification`，半夜构建挂了也有人知道；
5. **镜像即环境**（第 14/18 章）：三平台环境固化成镜像，`alwaysPull` 保证更新生效。


## 小结

- 完整闭环 = Webhook 触发 → 三平台并行 → 缓存编译 → 打包符号 → 制品提交 → 符号上传（第 19 章）→ 下游发布 → 通知 → 崩溃符号化定位；
- 组装的关键是把复杂度收敛进 `buildStage` 和共享库，主流水线保持可读；
- 提交与发布解耦、缓存分层、制品可追溯、失败必通知、镜像即环境——五条设计原则贯穿全书；
- 补上实战数据，这一章就是全册最有说服力的"验收报告"。


** 资源

有些源码放在：[https://gitee.com/goccoder/cpp-engineering-starter](https://gitee.com/goccoder/cpp-engineering-starter)，如果有更多合理需求可以在仓库里找我，我尽量提供帮助

> 完结：至此，一套 C++ 项目从代码提交到三平台发布的完整工程化体系搭建完成。回头看，所有零件都来自真实生产环境——这也是最大价值所在。

