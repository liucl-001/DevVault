# 私有镜像仓库：Registry 部署与镜像管理

> 本节解决：构建镜像（第 14 章）得有地方存——私有 Registry 怎么部署、客户端怎么配、镜像命名与版本策略怎么做。

## 镜像建好了，放哪

第 14 章我们建了 `gccbuild:ubuntu`、`msvcbuilder:vs2019` 构建镜像，但镜像在本地只有构建机自己能用——流水线要在多台节点上拉取（第 18 章 `agent { docker }`），就必须有一个**所有节点都能访问的私有镜像仓库**。Docker Registry 就是干这个的：内网部署、无外网依赖、版本可控。

## 第一步：Registry 部署（compose 一键起）

Registry 本身也是一个镜像，用 docker compose 部署：

```yaml
# 来源：生产部署素材（脱敏）
services:
  registry:
    image: registry:${REGISTRY_VERSION}          # 版本走 .env 管理
    volumes:
      - /data/docker_volumes/registry:/var/lib/registry   # 镜像数据挂数据盘
    ports:
      - "${REGISTRY_PORT}:5000"
    user: "1000:1000"                            # 非 root 运行
    environment:
      TZ: Asia/Shanghai
    restart: unless-stopped
```

配合 `.env`：

```env
REGISTRY_VERSION=3.1.1
REGISTRY_PORT=5000
```

加上 registry UI——**这就是"最简搭建"的完整版**：私有仓库只有这两个服务（无数据库、无依赖），一份 YAML 两条服务即可：

```yaml
# 来源：生产部署素材（脱敏）
  registry:
    image: registry:${REGISTRY_VERSION}
    volumes:
      - /data/docker_volumes/registry:/var/lib/registry
    ports:
      - "${REGISTRY_PORT}:5000"
    user: "1000:1000"                  # 非 root 运行
    environment: { TZ: Asia/Shanghai }
    restart: unless-stopped
  registry-ui:
    image: joxit/docker-registry-ui:${REGISTRY_UI_VERSION}
    ports:
      - "${REGISTRY_UI_PORT}:80"
    environment:
      - REGISTRY_URL=http://<registry>:${REGISTRY_PORT}   # 指向你的私有仓库
      - DELETE_IMAGES=false           # 允许在 UI 删除镜像；团队不熟就关（防手滑）
      - SINGLE_REGISTRY=true          # 单仓库模式（最省心）
```

三个 UI 环境变量决定了使用体验：

- **`REGISTRY_URL`**：UI 要连接的仓库地址——容器内用服务名，浏览器访问走宿主机端口；
- **`DELETE_IMAGES`**：是否允许在 UI 里删除镜像——**默认 false（只读）最安全**。误删 tag 会让下游构建拉不到镜像，且删除不可恢复，所以除非团队明确需要在线清理，否则保持关闭；
- **`SINGLE_REGISTRY=true`**：只展示单个仓库，界面最简，不做多仓库切换的复杂 UI——自用最省心。

**三个必配项**：
- **数据卷挂 /data**：镜像数据动辄几十 GB，必须放数据盘；
- **`restart: unless-stopped`**：仓库挂了所有构建都拉不到镜像，必须保活；
- **`user: "1000:1000"`**：registry 以非 root 运行——镜像仓库面向内网，降权是基本安全姿势。

**零依赖提示**：registry 和 registry-ui 互不依赖、不需要数据库——这就是"最简单"的含义：`.env` 填 4 个变量（REGISTRY_VERSION/REGISTRY_PORT/REGISTRY_UI_VERSION/REGISTRY_UI_PORT），`docker compose up -d` 就有一个带 Web 界面的私有仓库。

## 第二步：客户端配置（insecure-registries）

Registry 默认走 HTTP（内网环境不配 HTTPS），所有要用它的节点（Jenkins 主节点 + 从节点）都要在 Docker 配置里加白名单：

```json
// /etc/docker/daemon.json（Ubuntu/Linux）
// C:\ProgramData\docker\config\daemon.json（Windows）
{
  "insecure-registries": ["<registry>:5000"],
  "data-root": "/var/lib/docker/data"
}
```

```bash
systemctl daemon-reload && systemctl restart docker
```

**不配的后果**：`docker pull <registry>:5000/msvcbuilder:vs2019` 直接报 `certificate signed by unknown authority`——这是拉私有镜像最常见的错误，90% 是忘配 insecure-registries。

## 第三步：镜像命名与版本策略

镜像名即寻址地址，命名规范直接决定运维体验。生产建议：

```text
<registry>:5000/<项目>/<镜像名>:<版本>
```

真实案例（第 14/18 章）：

```text
<registry>:5000/gccbuild:ubuntu          # Linux 构建镜像
<registry>:5000/msvcbuilder:vs2019       # Windows VS2019 构建镜像
<registry>:5000/msvcbuilder:vs2022       # Windows VS2022 构建镜像
<registry>:5000/msvcbuilder:cache-vs2019 # buildkit 缓存镜像（第 14 章 compose 里用）
```

策略要点：

1. **tag 即版本**：`vs2019`/`vs2022` 区分编译器版本；`ubuntu` 标识基础系统——tag 必须能让人一眼知道"这是什么环境"；
2. **缓存镜像单独 tag**：buildkit 缓存（`cache-vs2019`）和正式镜像分开，避免缓存层污染正式镜像；
3. **版本升级用新 tag，不覆盖旧 tag**：`vs2019` 升到 `vs2019-v2` 而不是覆盖——旧 tag 还在，回滚就是改回 tag 一行事。

## 第四步：拉取策略（流水线配合）

仓库就位后，流水线里的拉取行为（第 18 章详述）：

```groovy
agent {
    docker {
        image '<registry>:5000/msvcbuilder:vs2019'
        alwaysPull true    // 每次构建拉最新，镜像更新立即生效
    }
}
```

**`alwaysPull true` 必须开**：不开的话节点复用本地缓存镜像，你更新了镜像（比如编译器升级）构建还在用旧的——"镜像更新了但行为没变"是最难排查的玄学。

## 小结

- 私有 Registry = 镜像的家：**最简搭建只有两个服务**（registry + registry-ui，无需数据库），compose 一键部署；
- UI 三变量定体验：REGISTRY_URL 指向仓库、DELETE_IMAGES 防手滑、SINGLE_REGISTRY 单仓库模式；
- 客户端三平台配 `insecure-registries` 白名单，漏配 = 拉镜像报证书错误；
- 命名规范 `<registry>/<项目>/<镜像>:<版本>`，tag 即版本、缓存镜像单独 tag、升级不覆盖旧 tag；
- 流水线里 `alwaysPull true` 保证镜像更新立即生效。

> 延伸：仓库有了，镜像怎么管理（第 17 章凭证/故障）、流水线怎么拉取使用（第 18 章）、buildkit 缓存怎么用仓库加速镜像构建（第 14 章）。

