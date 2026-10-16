# OpenPlugins 插件化架构深度解析 · 系列文章（十章）

> 面向对象：C++ 桌面应用开发者、插件架构研究者
> 内容来源：`E:\src\open-plugins` 仓库（AnycubicSlicerNext 的插件化基础库，Mulan PSL v2）

本系列基于对 `open-plugins` 仓库源码与文档的完整通读撰写，沿「**为什么要插件化 → 架构怎么分层 → 契约如何定义 → 运行时如何加载 → 依赖如何解析 → 插件之间如何通信 → 数据如何序列化 → 包如何分发与校验 → Web 能力如何接入 → 配套工程体系如何支撑**」的主线推进，共十章。

## 阅读顺序与章节关系

```
第 1 章  定位与全景        （Why + 目录地图）
第 2 章  架构分层          （What：四大核心模块 + 支撑模块）
第 3 章  插件契约          （接口 / 元数据 / C ABI）
第 4 章  加载与生命周期    （打包校验 → 加载 → 实例化 → 生命周期事件）
第 5 章  依赖解析          （多轮迭代初始化，处理依赖 DAG）
第 6 章  函数路由与内存流  （插件间通信主通道）
第 7 章  序列化机制        （通信协议底层）
第 8 章  插件包与安全      （Zip + AES 签名 + MD5 校验）
第 9 章  WebView 与 Web API（wxWebView + REST 风格路由）
第10 章  配套工程体系      （事件 / i18n / 日志 / XRC / CMake / 测试）
```

第 3~5 章构成「插件如何在运行时被管起来」的主链，第 6~7 章构成「插件之间怎么传数据」的主链，第 8~9 章是独立的能力专题，第 10 章是支撑体系的横切梳理。每章结尾附「本章要点」与「代码定位」方便回查。

## 章节列表

| 章节 | 文件 | 主题 |
| ---- | ---- | ---- |
| 01 | `01-项目定位与全景.md` | 定位、技术栈、仓库地图 |
| 02 | `02-架构分层.md` | 分层职责与协作关系 |
| 03 | `03-插件契约.md` | Plugin / PluginHost / PluginInfo / C ABI |
| 04 | `04-加载与生命周期.md` | 包校验、加载、实例化、生命周期事件 |
| 05 | `05-依赖解析.md` | 依赖声明与多轮初始化 |
| 06 | `06-函数路由与内存流通信.md` | Router / IStream / OStream / dispatch_call |
| 07 | `07-序列化机制.md` | 类型分类与 pack/unpack 协议 |
| 08 | `08-插件包与安全.md` | Zip、AES 签名、MD5 完整性 |
| 09 | `09-WebView与WebAPI.md` | wxWebView、RouterBase、ADD 宏 |
| 10 | `10-配套工程体系.md` | 事件、i18n、日志、XRC、CMake、测试 |

## 关键代码定位索引

| 主题 | 关键文件 |
| ---- | ---- |
| 插件接口 | `plugins_base/plugins.hxx` |
| 插件元数据 / C ABI | `plugins_base/plugins_base.hxx` |
| 函数包装 / 调用 | `plugins_base/funcation.hxx`、`function_traits.hxx`、`pack.hxx` |
| 内存流 | `plugins_base/plugins_stream.hxx` |
| i18n 宏 | `plugins_base/i18n.hxx`、`i18n_helper.hxx` |
| 管理器接口 | `plugins_manager/plugins_manager.hxx` |
| 管理器实现 | `plugins_manager/detail/plugins_manager_impl.{hpp,cpp}` |
| 库加载（动态/静态） | `plugins_manager/detail/LibraryBase.{hxx,cpp}` |
| 函数路由 | `plugins_manager/detail/router.{hpp,cpp}` |
| 插件包 / 签名 / 压缩 | `plugins_manager/detail/package.{hxx,cpp}` |
| 事件系统 | `plugins_sdk/event/plugin_event.hxx` |
| Web API 处理器 | `plugins_sdk/webview/webview_api_handler.{hxx,cpp}` |
| Web API 路由 | `plugins_sdk/webview/detail/router.{hpp,cpp}` |
| Web API 模板实现 | `docs/mechanism.md`（完整代码） |
| wxWebView 封装 | `WebView/include/*`、`WebView/src/*` |
| 加密 | `utility/encrypt/aes.{hxx,cpp}`、`rsa.{hxx,cpp}` |
| 编解码 | `utility/codec/{md5,base64,bin2ascii}.{hxx,cpp}` |
| 日志 | `easy_log/log.{hxx,cpp}`、`stackstrace.{hxx,cpp}` |
| CMake 体系 | `cmake/{basic,build,generate,subdir}.cmake` |
| 示例插件 | `plugins/{app,tabbook,utility,luatest}/` |
