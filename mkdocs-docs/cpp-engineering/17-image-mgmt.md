# 镜像管理与常见故障：凭证、清理与排错

> 本节解决：镜像多了怎么管——私有仓库凭证机制、镜像清理、三平台容器故障（端口/盘符/权限/keychain）怎么排。

## 镜像管理的核心是"凭证"和"故障"

镜像越来越多，两个问题就会冒出来：**拉私有镜像时凭证从哪来**（CI 环境不能每次交互输密码）、**容器/镜像出问题时怎么快速定位**。这一节把凭证机制讲透，再给一份三平台故障清单。

## 凭证机制：docker-credential 协议

`docker login` 存的凭证不是明文文件，而是通过**凭证助手（credential helper）**读写——Docker CLI 与助手通过标准输入输出通信，协议只有几个命令：

```text
命令：add / get / delete / list / version
输入：stdin 传 JSON（{"ServerURL": "...", "Username": "...", "Secret": "..."}）
输出：stdout 返回 JSON 结果，错误写 stderr
```

生产环境有个特殊场景：**CI 构建机不想持久化凭证**（安全考虑），或者 Windows 节点上 Jenkins 服务账号访问不了 Credential Manager——这时可以用一个"空实现"助手（内存存储，退出即清）：

```go
// docker-credential-desktop 空实现（生产辅助工具的设计）
// 实现 Credential Helper 协议：add/get/delete/list/version
// 所有凭证仅存内存 Map，进程退出全部丢失
// URL 匹配：先精确匹配，再近似匹配（自动补全 scheme/port/path）
```

适用场景：不需要 `docker login` 的环境、CI 占位符、防止凭证持久化。**注意**：空实现意味着重启后要重新登录，只适合拉公共镜像或凭证另有来源的 CI 环境。

## 常见故障清单（按平台）

### Linux

```bash
# 故障1：端口冲突
# "Bind for 0.0.0.0:80 failed: port is already allocated"
docker stop $(docker ps -aq)
systemctl stop docker
rm /var/lib/docker/network/files/local-kv.db   # 清网络脏状态
systemctl start docker

# 故障2：拉私有镜像证书错误
# "certificate signed by unknown authority" → 忘配 insecure-registries（第 15 章）
# 配完 /etc/docker/daemon.json 记得：systemctl daemon-reload && systemctl restart docker
```

### Windows 容器

```text
故障1：docker agent 起不来，工作目录在其他盘符
→ Windows 容器仅能映射 C 盘，工作目录必须 C 盘
→ 解法：mklink /D C:\jenkins E:\jenkins（第 2/4 章）

故障2：登录权限问题
→ Jenkins 服务账号访问不了 Credential Manager
→ 解法：自定义 docker-credential-desktop（上文）
```

### macOS 节点

```bash
# 故障：流水线里操作 GUI/签名相关需要解锁 keychain
security unlock-keychain -p <password> login.keychain
# （macOS 签名任务 cron 触发，见生产签名流水线）
```

macOS 节点跑签名（Developer ID）时，Jenkins 后台进程没有 keychain 解锁权限，签名工具会失败——**cron 定时触发 + 无人值守的场景，必须先解锁 keychain**（这是生产签名任务的核心前置步骤）。

## 镜像清理与存储

镜像数据只增不减，三个治理手段：

```bash
# 1. 悬空镜像清理（<none> 标签，构建产生的垃圾层）
docker image prune -f

# 2. 全部未使用镜像清理（谨慎，CI 里可能误删要用的缓存）
docker image prune -a

# 3. Registry 存储治理（生产）
#    Registry 数据在 /var/lib/registry，可配 GC 或定期清理旧 tag
#    镜像命名/tag 策略见第 15 章：升级用新 tag 不覆盖，配合清理
```

CI 场景特别注意：**`docker image prune -a` 可能误删 buildkit 缓存镜像**（第 14 章的 `cache-vs2019`），清完下一次镜像构建直接从头跑几十分钟——清理策略要和缓存策略配合，别一刀切。

## 小结

- 凭证走 Credential Helper 协议（add/get/delete/list），CI 可用空实现（内存存储）防持久化；
- Linux 故障：端口冲突清网络状态、证书错误配 insecure-registries；
- Windows 容器：只能映射 C 盘（mklink 解决）、登录权限用自定义凭证助手；
- macOS：签名场景先 `security unlock-keychain`；
- 镜像清理要和 buildkit 缓存策略配合，别误删缓存镜像。

> 延伸：凭证/镜像都通了，流水线里怎么用镜像（第 18 章）、镜像仓库怎么部署（第 15 章）、镜像本身怎么建（第 14 章）。

