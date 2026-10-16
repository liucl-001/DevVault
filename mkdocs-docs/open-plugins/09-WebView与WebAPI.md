# 09 · WebView 与 Web API：把 C++ 成员函数暴露成 HTTP 接口

切片软件的很多界面用 Web 技术实现。OpenPlugins 提供两条配套能力：一是自研的跨平台 `wxWebView` 组件，二是把 C++ 成员函数变成 REST 风格 Web API 的整套模板机制。本章把这两块讲透。

## 9.1 为什么要自造 wxWebView

`WebView/` 是一个**独立的 wxWebView 实现/增强模块**，文档 `docs/directory.md` 的原话是：

> wxWebView 组件：默认 wxWidgets 自带的太老，也不方便定制修改。

它在 `webview.h` 基础上按平台提供了底层引擎：

| 平台 | 后端实现 |
| ---- | ---- |
| Windows | `msw/webview_edge.*`（WebView2 / Edge Chromium）、`msw/private/webview_ie.*`（IE 兼容） |
| macOS | `osx/webview_webkit.*`、`osx/webview_chromium.*` |
| GTK/Linux | `gtk/webview_webkit.cpp`、`gtk/webview_webkit2.cpp`（WebKit2） |

同时提供 `webviewarchivehandler` / `webviewfshandler`（资源与文件系统处理器）。`CMakeLists.txt` 里 `ENABLE_WEBVIEW` 开关控制是否编译（第 1 章已见）。由于要承载"自定义 scheme + 拦截请求 + 注入 JS"等能力，仓库选择把 WebView 做成独立可控的组件。

## 9.2 Web API 的三层模型

插件里暴露 Web API 的核心模型是**三件套**（`plugins_sdk/webview/`）：

```
wxWebView 页面 (前端 JS)
   │ 发起 HTTP 请求到自定义 scheme（如 acapi://）
   ▼
WebviewApiHandler   ← wxWebViewHandler 子类，负责分发
   ├── RouterBase    （路由表：Method + pattern → HandlerBase）
   └── InstanceBase* （业务实例集，插件业务逻辑的载体）
         └── 每个实例 Init(RouterBase&) 时注册路由
```

```cpp
class WebviewApiHandler : public wxWebViewHandler {
public:
  template <typename _Ty, typename... Args> _Ty *AddInstanceT(Args &&...args) {
    _Ty *instance = new _Ty(std::forward<Args>(args)...);
    AddInstance(instance);
    return instance;
  }
  void AddInstance(InstanceBase *instance);
  void StartRequest(wxWebViewHandlerRequest &request,
                    wxSharedPtr<wxWebViewHandlerResponse> response) override;
private:
  wxSharedPtr<RouterBase> m_router;
  std::vector<InstanceBase *> m_instances;
};
```

- `WebviewApiHandler(scheme)`：绑定一个自定义 scheme（如 `"api"`）；
- `AddInstanceT<T>()`：模板创建业务实例并托管；
- 请求进来走 `StartRequest` → 交给 `RouterBase` 匹配路由 → 分发到 `HandlerBase`。

## 9.3 路由：RouterBase

`RouterBase` 支持完整的 HTTP 方法枚举（`docs/mechanism.md`）：

```cpp
class RouterBase {
public:
  enum METHOD_TYPE {
    MethodGET = 0,     // 数据查询
    MethodPOST,        // 数据创建
    MethodDELETE,      // 数据删除
    MethodPUT,         // 数据更新
    MethodOPTIONS      // CORS 预检
  };
  virtual bool RegisterHandler(METHOD_TYPE method,
                               const wxString &pattern,
                               HandlerBase *handler) = 0;
};
```

路由匹配策略：**精确匹配优先，其次正则匹配**（`detail/router.{hpp,cpp}`），支持复杂路径模式。

## 9.4 极简注册：ADD 宏 + MAKE_URI

业务实例在 `Init(RouterBase&)` 里用一行宏注册路由：

```cpp
#define MAKE_URI(module, func) "/api/v1/" #module "/" #func

#define ADD(method, type, module, func, ...)                                   \
  RegisterHandler(                                                             \
      RouterBase::BOOST_PP_CAT(Method, method), MAKE_URI(module, func),        \
      ::Anycubic::Plugins::SDK::handler::WrapperMember<                        \
          ::Anycubic::Plugins::SDK::handler::condition<                        \
              RouterBase::BOOST_PP_CAT(Method, method)>(true, false)>(         \
          &type::func, this, {__VA_ARGS__},                                    \
          ::Anycubic::Plugins::SDK::handler::condition<                        \
              RouterBase::BOOST_PP_CAT(Method, method)>(                       \
              ::Anycubic::Plugins::SDK::handler::GetQuery,                     \
              ::Anycubic::Plugins::SDK::handler::GetBody)))
```

宏解构：

| 片段 | 作用 |
| ---- | ---- |
| `BOOST_PP_CAT(Method, method)` | 把 `GET/POST/...` 拼成枚举值 `MethodGET` |
| `MAKE_URI(module, func)` | 生成路径 `/api/v1/<module>/<func>` |
| `condition<Method>(true,false)` | 编译期按 method 选择模式：GET→query，其它→body |
| `&type::func, this` | 目标成员函数与实例 |
| `{__VA_ARGS__}` | 参数名列表（告诉框架从 query/body 里取哪些字段） |
| `GetQuery / GetBody` | 从请求里取参数字符串的方式 |

使用示例（`docs/mechanism.md`）：

```cpp
class UserApi : public InstanceBase {
public:
  std::vector<User> GetUserList() { return users; }
  User CreateUser(const std::string &name, int age) { ... }

  bool Init(RouterBase &router) override {
    router.ADD(GET,  UserApi, user, list, "");        // GET  /api/v1/user/list
    router.ADD(POST, UserApi, user, create, "name", "age"); // POST /api/v1/user/create
    return true;
  }
};
```

前端一个 `fetch('/api/v1/user/create', ...)` 就能命中 C++ 函数。

## 9.5 核心包装器：WrapperMember

`WrapperMember` 是把普通成员函数转成 Web API 处理器的核心模板（完整实现见 `docs/mechanism.md`，这里讲骨架）：

```cpp
template <bool query = false, typename Function, typename Self, typename ParamFunc>
HandlerBase *WrapperMember(const Function &func, Self *self,
                           const std::vector<wxString> &param_names,
                           const ParamFunc &get_str) {
  typedef traits::function_traits<Function> func_traits;
  auto wrapper_func = [param_names, func, self, get_str](auto &req, auto res) -> bool {
    typename func_traits::bare_tuple_type args;
    using ret_type = typename func_traits::return_type;
    wxString resBody = R"({"code":500,"msg":"Internal Server Error"})";
    int32_t code = InternalServerError_500;
    try {
      auto body = get_str(req);                       // 取 query 或 body 字符串
      detail::decode<query>(args, body, param_names); // 解码参数到元组
      resBody = detail::create_response(              // 执行并包装标准响应
          std::apply(func, std::tuple_cat(std::make_tuple(self), args)));
      code = OK_200;
    } catch (...) {
      LOG_ERROR(...);
    }
    res->SetContentType("application/json;charset=UTF-8");
    res->SetStatus(code);
    res->Finish(wxSharedPtr<wxWebViewHandlerResponseData>(
        new detail::StringResponseData(resBody)));
    return true;
  };
  return new detail::FunctionHandler(wrapper_func);
}
```

流程与第 6 章 `make_call` 几乎同构，但输入是 HTTP 请求、输出是 JSON 响应：

1. **取参数**：`GetQuery`（`wxURI::Unescape(req.GetRawURI()).GetQuery()`）或 `GetBody`（`req.GetDataString()`）；
2. **解码**：`decode<query>(args, body, param_names)`——按 `param_names` 从 query/JSON 里给参数元组赋值；
3. **执行**：`std::apply(func, std::tuple_cat(std::make_tuple(self), args))`（注入 this）；
4. **响应**：`create_response(result)` 生成 `{code,msg,data}` JSON，设 `application/json;charset=UTF-8`、状态码、完成响应；
5. **异常兜底**：任何异常 → 500 内部错误 JSON。

## 9.6 参数解码引擎：query 与 JSON 双模式

`decode` 按编译期 `query` 标志走两条路：

```cpp
template <bool query, typename... Args>
static void decode(std::tuple<Args...> &tuple, const wxString &str,
                   const std::vector<wxString> &names) {
  if constexpr (query) {
    std::string jsonstr = wxURI::Unescape(str).utf8_string();  // URL 解码
    auto args = parse_query(jsonstr);                          // 解析成 map
    assign_query(tuple, names, args, std::index_sequence_for<Args...>{}); // 批量赋值
  } else {
    auto json = boost::json::parse(str.utf8_string());         // JSON 解析
    assign_json(tuple, names, json, std::index_sequence_for<Args...>{});
  }
}
```

**编译期参数包展开**（`std::index_sequence` + 折叠表达式），对元组每个元素按名字赋值：

```cpp
template <typename Tuple, std::size_t... I>
static void assign_query(Tuple &tuple, const std::vector<wxString> &names,
                         const query_type &list, std::index_sequence<I...>) {
  (assign_query_impl(std::get<I>(tuple), names[I], list), ...);
}
template <typename Tuple, std::size_t... I>
static void assign_json(Tuple &tuple, const std::vector<wxString> &names,
                        const boost::json::value &json, std::index_sequence<I...>) {
  (assign_json_impl(std::get<I>(tuple), names[I], json), ...);
}
```

**类型转换**（`transform_query` / `transform_json`）用 `if constexpr` 按类型分发：

```cpp
// query（字符串）→ 类型
template <typename _Ty> static _Ty transform_query(const std::string &val) {
  using ret_type = std::decay_t<_Ty>;
  if constexpr (std::is_same_v<std::string, ret_type>) {
    return val;
  } else if constexpr (std::is_same_v<wxString, ret_type>) {
    return wxString::FromUTF8(val.data(), val.size());
  } else if constexpr (std::is_arithmetic_v<ret_type>) {
    try { return boost::lexical_cast<ret_type>(val); }
    catch (...) { return ret_type(0); }        // 转换失败归零
  } else { assert(false); return ret_type(); }
}
// JSON value → 类型
template <typename _Ty>
static void transform_json(_Ty &&ret, const boost::json::value &val) {
  using ret_type = std::decay_t<_Ty>;
  if constexpr (std::is_same_v<bool, ret_type>)      ret = val;
  else if constexpr (std::is_floating_point_v<ret_type>) ret = val;
  else if constexpr (std::is_arithmetic_v<ret_type>) ret = val.to_number<ret_type>();
  else if constexpr (std::is_same_v<std::string, ret_type>) ret = val.as_string();
  else if constexpr (std::is_same_v<wxString, ret_type>) {
    auto str = val.as_string(); ret = wxString::FromUTF8(str.data(), str.size());
  } else { assert(false); ret = L"77dk"; }
}
```

## 9.7 标准化响应与辅助类型

`detail::Response<T>` 统一响应外壳，`create_response` 负责序列化与 UTF-8 安全转换：

```cpp
template <typename _Ty> struct Response {
  int code = 200;           // HTTP 状态码
  std::string msg = "OK";   // 响应消息
  _Ty data;                 // 业务数据
};

template <typename _Ty> static wxString create_response(_Ty &&val) {
  using data_type = std::decay_t<_Ty>;
  Response<data_type> resp;
  resp.data = std::move(val);
  auto str = object_to_json(resp);                 // iguana/Boost 序列化
  return wxString::FromUTF8(str.data(), str.size());
}
```

辅助类：
- `FunctionHandler`：实现 `HandlerBase`，把 `std::function` 包装成处理器；
- `StringResponseData`：把 `wxString` 包成 `wxWebViewHandlerResponseData`（内部 `wxStringInputStream`），让响应能以流形式交回 WebView。

## 9.8 完整接入姿势

```cpp
// 业务类
class UserApi : public InstanceBase { /* ... 见上文 Init + ADD ... */ };

// 装配
auto api_handler = new WebviewApiHandler("api");
auto user_api = api_handler->AddInstanceT<UserApi>();
webview->RegisterHandler(api_handler);   // NOTE: 不同平台时机不同
```

文档特别标注："不同平台时机是不同的"——因为各平台 WebView 注册 handler 的时机存在差异，需要由宿主在合适的生命周期节点调用 `RegisterHandler`。

## 9.9 技术亮点小结

| 亮点 | 说明 |
| ---- | ---- |
| 编译期类型安全 | 参数/返回值类型在编译期解析，类型不匹配编译期即报错 |
| 极简开发 | `router.ADD(GET, UserApi, user, list)` 一行注册；参数名列表驱动自动映射 |
| 标准化响应 | 统一 `{code,msg,data}` JSON，异常自动降级 500 |
| 双参数模式 | GET 走 query（URL 解码）、POST/PUT/DELETE 走 body（JSON），编译期选择 |
| 编码安全 | `wxString::FromUTF8` 保证 UTF-8 正确转换 |

## 本章要点

- `WebView/` 是自研跨平台 wxWebView 组件（Edge/WebKit/Chromium），因为"默认太老、不便定制"；
- Web API 三件套：`WebviewApiHandler`（分发）+ `RouterBase`（路由）+ `InstanceBase`（业务实例）；
- `ADD` 宏一行注册 REST 风格路由，`MAKE_URI` 生成 `/api/v1/<module>/<func>`；
- `WrapperMember` 把成员函数变成 Web 处理器：取参数 → 解码 → `std::apply` 执行 → 标准 JSON 响应；
- 参数解码支持 query 与 JSON 双模式，`if constexpr` 按类型分发转换。

## 代码定位

- WebView 组件：`WebView/include/*`、`WebView/src/*`
- API 处理器：`plugins_sdk/webview/webview_api_handler.{hxx,cpp}`
- 路由：`plugins_sdk/webview/detail/router.{hpp,cpp}`
- 完整模板实现：`docs/mechanism.md`