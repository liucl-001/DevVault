# Docker 环境搭建：三平台安装、远程访问与国内源

> 本节解决：CI/CD 的地基——Docker 怎么装、怎么开 TCP 远程访问（Jenkins 节点要用）、daemon.json 怎么配、目录权限与容器工作目录问题怎么排。


## 一切从环境开始

不管你的流水线设计得多漂亮，构建最终跑在"环境"上：节点机器、容器运行时、网络。Docker 就是这套体系的地基——Jenkins 主节点、从节点、构建镜像（第 14 章）、私有仓库（第 15 章）全都建立在 Docker 之上。

这一节把 Docker 环境搭建的关键动作讲清楚：**安装→ 开远程 → 配 daemon.json → 排故障**。每个动作后面都跟着"为什么"。

## 第一步：安装

### Linux（Ubuntu）

用系统包管理装 docker-ce（国内用清华源）：

```bash
sudo apt-get install -y docker.io    # 或 docker-ce
sudo systemctl restart docker
```

### Windows（关键坑：SSH 访问）

**Windows 节点通过 SSH 访问时，Docker Desktop 有权限问题**——生产推荐用微软官方的 Install-DockerCE 脚本：

```powershell
Invoke-WebRequest -UseBasicParsing `
    "https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1" `
    -o install-docker-ce.ps1
.\install-docker-ce.ps1
```

> `daemon.json` 位置：`C:\ProgramData\docker\config\daemon.json`

## 第二步：开 TCP 远程访问（CI 的关键）

**为什么必须开？** Jenkins 从节点要远程调用 Docker 构建（`agent { docker }` 就是在节点上拉起容器），默认的 Docker 只监听本地 socket，Jenkins 节点无法远程调用。生产做法是让 dockerd 同时监听 TCP 端口：

修改 `/usr/lib/systemd/system/docker.service` 文件，找到 `ExecStart` 行，添加 TCP 监听：

```conf
ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375 --containerd=/run/containerd/containerd.sock
```

```bash
# 重启 Docker 服务
sudo systemctl daemon-reload && sudo systemctl restart docker
```

**安全提醒**：`-H tcp://0.0.0.0:2375` 是明文无认证的远程调用——**只应在内网 CI 环境开，绝不能暴露到公网**。Jenkins 节点配置里也用这个地址（见第 4 章 Linux 节点的 `DOCKER_HOST` 环境变量）。

## 第三步：daemon.json 配置

### Linux
`/etc/docker/daemon.json` 文件：
```json
{
  "data-root": "/data/docker",              // 数据目录挪到大盘（新版用 data-root，不是 graph）
  "insecure-registries": ["<registry>:5000"]   // 私有仓库白名单（第 15 章）
}
```

> 注意：新版 Docker 数据目录用 `data-root`。

### Windows

`C:\ProgramData\docker\config\daemon.json`：

```json
{
  "insecure-registries": ["<registry>:5000"]
}
```

## 第四步：目录权限与容器工作目录

### 目录权限（Linux）

compose.yaml 里 `user` 字段要和当前用户 ID 对应（否则容器内文件权限不对）：

```bash
# 查看当前用户 ID
id
# 假设输出 1000:1000，compose.yaml 里写：
#   user: "1000:1000"
# 数据目录也要对应授权：
sudo chown -R 1000:1000 /data/docker_volumes
```

### 容器工作目录（Windows 关键坑）

**Docker 容器里只有 C 盘**——Jenkins 工作目录如果在 E 盘，容器里找不到，构建直接失败。解法：符号链接：

```bat
:: 把 E 盘的 Jenkins 目录链到 C 盘
mklink /D C:\jenkins E:\jenkins
```

### Linux docker.sock 权限

节点用 `agent { docker }` 时，报 `/var/run/docker.sock: permission denied`：

- 根因：Jenkins 进程用户没在 docker 组；
- 解法：节点环境变量配 `DOCKER_HOST=tcp://<node>:2375`（用 TCP 而不是 unix socket，见第二步）。

## 第五步：故障处理

### 端口冲突

```bash
# Bind for 0.0.0.0:80 failed: port is already allocated
docker stop $(docker ps -aq)
systemctl stop docker
rm /var/lib/docker/network/files/local-kv.db   # 清掉脏网络状态
systemctl start docker
```

### 服务重置

```bash
docker compose down -v
# 注意：下载的插件不会被删，必要时手动清数据目录
sudo rm -rf /data/docker_volumes/jenkins/*
```

## 小结

- Docker 是 CI 体系的地基：主节点、从节点、构建镜像、私有仓库全建立在它之上；
- **三平台安装**：Linux 用包管理，Windows 用 Install-DockerCE（SSH 访问避坑）；
- **TCP 远程访问**是 Jenkins 节点调用 Docker 的前提，只开内网、勿暴露公网；
- **daemon.json**：`data-root` 挪数据盘 + `insecure-registries` 私有仓库白名单；
- **目录权限**：user 1000:1000 + chown 数据目录；
- **Windows 容器只有 C 盘**：工作目录用 mklink 符号链接到 C 盘；
- **Linux docker.sock 权限**：改用 TCP（DOCKER_HOST）而不是 unix socket。

> 延伸：Docker 装好后，下一步部署 Jenkins 主节点（第 3 章）、配从节点（第 4 章），然后就能拉取第 14 章的构建镜像跑流水线了。

