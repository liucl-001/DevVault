# 流水线里引用 Docker：agent docker 的完整用法

> 本节解决：构建镜像搭好了（第 14 章），怎么在 Jenkins 流水线里真正用起来——agent docker 的三种用法、三平台并行怎么引用不同镜像、Windows 容器有哪些坑。

## 镜像搭好了，怎么让流水线用上

第 14 章我们把编译器装进了镜像（`gccbuild:ubuntu`、`msvcbuilder:vs2019`），但镜像只是"资源"，要让构建真正跑在镜像里，得让 Jenkins 知道"这个 stage 用哪个镜像跑"——这就是 `agent { docker }`。

先看一个三平台并发的完整示例（真实生产流水线骨架）：

```groovy
// 来源：生产部署素材（脱敏）
pipeline {
    agent none
    stages {
        stage('并发构建') {
            parallel {
                stage("MacOS 构建") {
                    agent { label 'macos' }          // macOS 直接用物理节点
                    stages { stage('开始构建') {
                        steps { script { buildStage('macos') } }
                    } }
                }
                stage("Linux 构建") {
                    agent {
                        docker {
                            label 'linux'
                            image '<registry>/gccbuild:ubuntu'   // Linux 跑在 gcc 镜像里
                            alwaysPull true
                        }
                    }
                    stages { stage('开始构建') {
                        steps { script { buildStage('linux') } }
                    } }
                }
                stage("Windows 构建") {
                    agent {
                        docker {
                            label 'windows'
                            image '<registry>/msvcbuilder:vs2019' // Windows 跑在 MSVC 镜像里
                            alwaysPull true
                        }
                    }
                    stages { stage('开始构建') {
                        steps { script { buildStage('windows') } }
                    } }
                }
            }
        }
    }
}
```

这个示例是"流水线引用 Docker"的标准模板，拆开看有三个决策：

## 决策一：哪个平台用容器、哪个用物理机

| 平台 | 方式 | 原因 |
|---|---|---|
| Linux | docker 镜像（gccbuild） | 容器化最成熟，镜像即环境 |
| Windows | docker 镜像（msvcbuilder） | MSVC/Qt/SDK 已固化成镜像，多项目共享 |
| macOS | 物理节点（label 'macos'） | macOS 容器不普及（许可证/虚拟化限制），直接打标签用物理机 |

**不是所有平台都要容器化**。macOS 用物理节点 + 标签，Windows/Linux 用镜像——这是生产环境的现实取舍：能容器化的容器化，不能的用标签精确管理。

## 决策二：镜像从哪来、怎么保持最新

```groovy
image '<registry>/gccbuild:ubuntu'   // 私有仓库地址
alwaysPull true                       // 每次构建都拉取
```

两个关键点：

1. **镜像来自私有仓库**（第 15 章部署的 registry）：构建机从 `<registry>` 拉镜像，而不是 Docker Hub——内网拉取快、版本可控、不依赖外网。
2. **`alwaysPull true` 必须开**：默认情况下，镜像一旦在节点上存在，Jenkins 就复用本地镜像不重新拉取。这会导致：你更新了镜像（比如升级了编译器），节点上还是旧镜像，构建结果和本地不一致。`alwaysPull` 显式要求每次拉最新——**这是"环境即代码"的最后一块拼图**。

## 决策三：Windows 容器有哪些坑

Windows 容器是这套方案里坑最多的部分，真实踩坑记录：

**坑 1：Windows Docker 只能映射 C 盘**

```text
工作目录只能配置在 C 盘，其他盘符会导致容器无法启动！
```

这是 Windows 容器引擎的限制：卷映射不支持任意盘符。如果你的 Jenkins 从节点工作目录在 D/E 盘，docker agent 直接起不来。

**解法：mklink 目录链接**

```shell
# 用目录链接把 C 盘路径指向其他盘，骗过 Docker 的盘符检查
mklink /D C:\jenkins E:\jenkins
```

把 C 盘的 `jenkins` 目录链接到 E 盘的实际存储——空间和盘符限制同时解决。

**坑 2：Windows Docker 登录权限问题**

Windows 容器拉私有仓库镜像时可能遇到权限问题，Jenkins 以服务账号运行、凭证进不去 Windows 的 Credential Manager。解法是装社区版本，不安装desktop版本:
```powershell
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1" -o install-docker-ce.ps1
.\install-docker-ce.ps1
```


**坑 3：`agent { docker }` 与物理节点的选择不是"会不会"的问题**

第 10 章提过：Windows 构建如果**依赖签名/证书等本机环境**（比如调用本地签名服务器、访问本机证书存储），用 `agent { docker }` 反而要处理容器内外凭证链路，得不偿失——这时候用 `label 'windows && vs2019'` 直接跑物理节点更稳。**容器化是手段，不是目的**：环境能固化的才固化，涉及本机资源的保留物理节点。

## 进阶：agent docker 的其他形态

除了顶层 `agent`，还可以在 stage 级别局部指定（多平台流水线里更常见）：

```groovy
stage("依赖编译") {
    agent {
        docker {
            image '<registry>/gccbuild:ubuntu'
            args '--user root'        // 容器内以 root 运行（构建需要写权限）
            alwaysPull true
        }
    }
    steps { ... }
}
```

`args` 用来传 docker run 参数：`--user root` 解决容器内写权限、`-v` 可以挂载额外目录。注意**局部 agent 的 stage 会占独立的 workspace**，与顶层 agent 的 workspace 不共享——需要传递的产物要显式用 `copyArtifacts` 或归档。

## 小结

- `agent { docker }` 把构建环境从"节点状态"变成"镜像引用"：`label` 选节点、`image` 选环境、`alwaysPull` 保最新；
- 三平台并行的现实组合：Linux/Windows 用镜像、macOS 用物理节点标签；
- Windows 容器三个坑：只能映射 C 盘（`mklink` 解决）、登录权限（自定义 credential helper）、本机资源场景考虑退回物理节点；
- 容器化是手段不是目的：环境能固化的才固化，本机依赖的保留物理节点。

> 延伸：私有镜像仓库怎么部署（第 15 章）、镜像怎么管理（第 17 章）、构建镜像本身怎么搭（第 14 章）——三章连起来就是完整的"镜像 → 仓库 → 流水线"链路。

