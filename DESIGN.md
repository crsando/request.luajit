# request.luajit 设计方案

## 1. 目标

本项目提供一个面向 LuaJIT 的异步 HTTP/HTTPS 客户端库。网络协议、连接复用、
TLS、代理和 HTTP/2 等能力由 libcurl 提供；事件循环由 luv 提供。库使用 libcurl
multi socket API，把 libcurl 请求的 socket 关注事件映射到 `uv_poll`，把 libcurl
请求的超时时间映射到一个单次触发的 `uv_timer`。

首个稳定版本的目标如下：

- 支持并发 HTTP/HTTPS 请求，调用方无需轮询。
- 支持 GET、HEAD、POST、PUT、PATCH、DELETE 和自定义方法。
- 支持 query、请求头、字符串或 form 请求体、重定向、代理、TLS 和常用超时设置。
- 默认缓冲完整响应体，并设置可配置的响应头和响应体大小上限。
- 提供类似 Python Requests 的模块级快捷方法，以及回调和协程 `await` 两种完成方式。
- 提供可靠的取消、关闭、错误传播和资源回收语义。
- 不接管事件循环；`uv.run()` 仍由应用程序调用。

首个版本不包含以下能力：

- 流式上传以及带背压的流式下载。
- WebSocket、SSE 的长期流式接口和服务端功能。
- 跨线程共享一个 session 或 request task。
- libcurl 不支持的协议。即使本机 libcurl 支持其他协议，本库也只允许 HTTP/HTTPS。

## 2. 依赖和兼容范围

- LuaJIT 2.1，使用 Lua 5.1 C API。
- libcurl 7.68 或更高版本。
- luv 1.44 或更高版本。
- 第一阶段正式支持 Linux 和 macOS。

libcurl 是本项目的原生 C 依赖。从源码编译时，目标机器必须安装 libcurl 开发包，而不只是
`curl` 命令行程序。开发包至少应提供：

- `curl/curl.h` 和相关 libcurl 头文件。
- 动态或静态链接库，例如 Linux 上的 `libcurl.so`、macOS 上的 `libcurl.dylib`。
- 推荐提供 `libcurl.pc`，供 pkg-config 返回头文件、链接目录和间接依赖参数。

编译完成后，运行机器不再需要头文件或 pkg-config，但默认动态链接模式仍需要 ABI 兼容的
libcurl 运行库及其 TLS、压缩和 HTTP/2 等间接依赖。安装 `curl` 命令行程序不保证开发包
已经安装，也不保证该程序和本模块最终加载的是同一份 libcurl。

Windows 不在当前兼容范围内；构建、事件桥接和 CI 只承诺 Linux 与 macOS。

异步 DNS 是否会阻塞取决于 libcurl 的构建方式。库在启动时读取
`curl_version_info()`；如果没有 `CURL_VERSION_ASYNCHDNS`，HTTP 传输仍然是事件驱动的，
但 DNS 解析可能短暂阻塞事件循环。该信息通过 `request.capabilities()` 暴露，并可用
`require_async_dns = true` 要求初始化在缺少异步 DNS 时失败。

模块必须在 `curl_global_init()` 成功后检查实际加载的 libcurl，而不能只相信编译时头文件：

- 运行期版本不低于 7.68.0。
- protocol 列表同时包含 `http` 和 `https`。
- HTTPS 能力包含 `CURL_VERSION_SSL`。
- `CURL_VERSION_ASYNCHDNS`、HTTP/2、HTTP/3、brotli 和 zstd 作为可选 capability 暴露。

编译期与运行期版本不满足最低要求时，`require("request.core")` 应返回包含实际版本和最低
版本的明确错误。缺少异步 DNS 默认只报告 capability，不阻止模块加载。

## 3. 总体架构

采用 Lua 驱动层加 C 核心层，而不是直接通过 LuaJIT FFI 调用 libcurl：

```text
Application
    |
    v
request.lua                         快捷方法、session、参数校验、状态机、结果分发
    |
    +--> request/driver.lua         CURL poll/timer 与 luv handle 的映射
    |
    +--> request/headers.lua        响应头结构和解析
    |
    v
request.core (C module)             CURLM/CURL、回调、缓冲区和资源所有权
    |
    v
libcurl multi socket API
```

C 核心不直接链接或调用 libuv。它只在 libcurl 的 socket/timer 回调中受保护地调用
两个内部 Lua 回调；内部 Lua 回调再操作 luv。这样不依赖 luv 未公开的 C API，也不会
错误地创建另一个 libuv loop。

不采用纯 FFI 的主要原因是：libcurl 会长期保存多个回调和用户数据指针，FFI callback
的生命周期、异常边界和 GC 管理容易出错。C 模块可以保证任何 Lua 错误都不会以
longjmp 的形式越过 libcurl 栈帧，也更容易实现二进制安全的缓冲区和确定的资源释放。

## 4. 模块划分

建议目录结构如下：

```text
lua/
    request.lua
    request/
        driver.lua
        error.lua
        headers.lua
        options.lua
        response.lua
        session.lua
        task.lua
src/
    request_core.c
    request_buffer.c
    request_buffer.h
tests/
    fixtures/
    integration_spec.lua
    testlib.lua
    unit_spec.lua
CMakeLists.txt
request-scm-1.rockspec
```

各模块职责：

- `request.lua`：导出快捷方法和 session API，规范化参数，维护状态并分发完成回调。
- `request/driver.lua`：持有 `uv_poll`、curl timer 和分发 timer，桥接事件标志。
- `request/headers.lua`：解析原始响应头行，提供大小写无关且保留重复字段的查询接口。
- `request/error.lua`：构造结构化错误并实现 `__tostring`。
- `request_core.c`：封装 CURLM 和 CURL easy handle，安装所有 libcurl 回调，收集结果。
- `request_buffer.*`：带溢出检查和大小上限的动态字节缓冲区。

## 5. 公共 API

公共 API 参考 Python Requests 的使用习惯：最常见的调用不要求用户先创建对象，方法名、
URL 和选项彼此分开；需要保存 cookie 或设置公共参数时，再显式创建 session。由于本库是
异步库，请求返回的是 task，而不是立即返回 response。

### 5.1 模块级快捷方法

```lua
local request = require("request")
local uv = require("luv")

request.get("https://example.com/api/items", {
    params = {
        page = 2,
        limit = 20,
    },
}, function(response, err)
    if err then
        print(err)
        return
    end

    print(response.status_code)
    print(response.headers["content-type"])
    print(response.body)
end)

uv.run()
```

模块导出：

```lua
request.request(method, url [, options] [, callback])
request.get(url [, options] [, callback])
request.head(url [, options] [, callback])
request.post(url [, options] [, callback])
request.put(url [, options] [, callback])
request.patch(url [, options] [, callback])
request.delete(url [, options] [, callback])
```

`options` 可省略，第二个参数是函数时自动视为 callback。所有方法都返回 task。参数类型、
URL 格式或互斥选项不合法属于编程错误，立即抛出 Lua error；请求被接受后的 DNS、连接、
TLS、HTTP、超时和取消错误则只通过 callback 或 `await()` 返回。这样每次调用只有一条
运行期错误通道。

模块级方法在每个 Lua state 中惰性创建一个默认 session，以获得连接复用；它默认不在
请求间保存 cookie，行为保持近似无状态。默认 session 在空闲时没有已激活或已 ref 的
luv handle，因此不会阻止 `uv.run()` 退出。

### 5.2 协程写法

```lua
local function main()
    local response, err = request.get("https://example.com/health"):await()
    if err then
        print(err)
        return
    end

    print(response.status_code)
end

coroutine.wrap(main)()
uv.run()
```

`await()` 只能在可 yield 的协程内调用。如果 task 已结束，它立即返回已保存的结果；否则
挂起当前协程。成功返回 `response, nil`，失败返回 `nil, err`。同一个 task 只允许 callback
或一个 await 等待者消费结果，重复等待立即抛出错误。

库不会在普通函数中隐式 yield，也不提供名字看似同步、实则驱动整个 loop 的接口。
调用方始终拥有 `uv.run()` 和 `uv.stop()`。

### 5.3 请求选项

```lua
request.post("https://example.com/items", {
    params = {
        verbose = true,
    },
    headers = {
        ["content-type"] = "application/json",
        ["accept"] = "application/json",
    },
    data = [[{"name":"demo"}]],
    timeout = {
        connect = 5,
        total = 30,
    },
    allow_redirects = true,
}, callback)
```

常用选项采用与 Python Requests 接近的命名：

| 选项 | 含义 |
| --- | --- |
| `params` | 追加到 URL 的 query map 或有序键值数组 |
| `headers` | 请求头 map 或有序 `{ name, value }` 数组 |
| `data` | 二进制安全的字符串请求体，或 form map |
| `timeout` | 总超时秒数，或 `{ connect, total }` |
| `allow_redirects` | 是否跟随重定向 |
| `max_redirects` | 最大重定向次数 |
| `auth` | `{ username, password }` 基本认证参数 |
| `proxy` | proxy URL；`false` 表示禁用环境代理 |
| `verify` | `true`、`false` 或 CA bundle 路径 |
| `cert` | client cert 路径，或 `{ cert, key }` |
| `max_body_bytes` | 本次响应体大小上限 |
| `max_header_bytes` | 本次响应头大小上限 |

`timeout` 使用秒是为了贴近 Requests；可以是小数，进入 C 核心前向上换算为毫秒。默认
`allow_redirects = true`，只有 `head()` 默认是 false。重定向协议始终限制为 HTTP/HTTPS。

`params` 和 form `data` 对数组值编码为重复键；需要严格控制顺序时使用：

```lua
params = {
    { "tag", "lua" },
    { "tag", "curl" },
}
```

`headers` 的 map 值可以是字符串或字符串数组。字段名和值禁止包含 CR、LF 或 NUL；URL、
method、proxy、认证参数和证书路径等传给 libcurl C 字符串选项的值也禁止包含 NUL。未知
option 直接作为参数错误拒绝，避免拼写错误被静默忽略。字符串 `data` 可以包含 `\0`，长度
以显式字节数传给 libcurl。为保持只有 libcurl 和 luv 两项必需依赖，首个版本不内置 JSON
codec；调用方可自行编码后传入 `data`。

### 5.4 Session

需要公共配置、cookie jar 或独立连接池时使用 session：

```lua
local session = request.session({
    headers = {
        ["user-agent"] = "my-service/1.0",
    },
    timeout = 30,
    cookies = true,
    max_body_bytes = 16 * 1024 * 1024,
})

session:get("https://example.com/profile", callback)
session:post("https://example.com/items", {
    data = "name=demo",
}, callback)
```

session 提供和模块完全相同的 `request/get/head/post/put/patch/delete` 方法。session 默认值
与单次请求选项进行浅合并；`headers` 和 `params` 分别合并，单次请求中的同名键优先。
如果 `headers` 或 `params` 使用有序数组形式，单次请求的数组整体替换 session 默认值，
避免破坏重复键的顺序。
显式 session 默认启用 cookie jar，可用 `cookies = false` 禁用。每个 session 对应一个
`CURLM` 和独立连接池，不能跨 Lua state 或线程使用。

```lua
session:close([callback])
session:is_closed()
request.close([callback])
```

`session:close()` 是幂等操作：拒绝新请求、取消活动请求并异步关闭 luv handle。可选
callback 在全部 close callback 完成后以 `callback(err)` 形式调用。`request.close()` 关闭
并丢弃默认 session；以后的模块级请求会创建一个新的默认 session。长期运行程序应显式
关闭自行创建的 session。

### 5.5 Task

快捷方法返回的 task 只暴露三个方法：

```lua
task:cancel([reason])
task:state()                        -- "active", "done" 或 "cancelled"
task:await()
```

`cancel()` 幂等，取消后以 `kind = "cancelled"` 完成。callback 签名固定为
`callback(response, err)`，与 `await()` 返回值顺序一致。即使立即取消，通知也在未来的
事件循环 tick 中发生，不会在发起请求或 `cancel()` 的调用栈中同步执行。

### 5.6 Response

成功响应结构如下：

```lua
{
    status_code = 200,
    reason = "OK",
    ok = true,
    http_version = "2",
    url = "https://example.com/final-url",
    headers = headers_object,
    body = "...",
    history = {},
    trailers = headers_object,
    metrics = {
        total_time = 0.125,
        namelookup_time = 0.004,
        connect_time = 0.021,
        appconnect_time = 0.053,
        starttransfer_time = 0.094,
        redirect_count = 0,
        uploaded_bytes = 42,
        downloaded_bytes = 128,
    },
}
```

`ok` 在状态码小于 400 时为 true。LuaJIT 字符串本身是字节序列，因此不再同时提供容易
混淆的 `content` 和 `text`；`body` 既可以保存文本，也可以保存二进制内容。

最常见的 header 读取直接使用下标，字段名大小写不敏感：

```lua
local content_type = response.headers["content-type"]
local cookies = response.headers:get_all("set-cookie")

for name, value in response.headers:each() do
    print(name, value)
end

response:raise_for_status()
```

下标和 `get()` 对重复字段返回第一个值；需要完整语义时使用 `get_all()`。header 对象保留
原始字段名、顺序和重复值。重定向和 1xx 响应头块保存在 `history`，最终响应后的 trailer
保存在 `trailers`。`raise_for_status()` 在 4xx/5xx 时抛出包含 response 的结构化 HTTP
错误，否则返回 response 本身；它是可选的显式检查，库不会自动抛出 HTTP 状态错误。

当字段名恰好是 `get`、`get_all` 或 `each` 等便利方法名时，下标访问优先返回字段值；此时
可使用 `local Headers = require("request.headers")` 后调用 `Headers.get(headers, name)`、
`Headers.get_all(headers, name)` 或 `Headers.each(headers)`，避免 Lua 方法查找和字段查找的
名字冲突。

### 5.7 Error

所有运行期错误使用同一结构：

```lua
{
    kind = "timeout",
    code = 28,
    name = "CURLE_OPERATION_TIMEDOUT",
    message = "Operation timed out after 30000 milliseconds",
    url = "https://example.com/slow",
    phase = "transfer",
}
```

`kind` 包括 `curl`、`timeout`、`cancelled`、`limit`、`protocol` 和 `internal`；
`raise_for_status()` 另外使用 `http`。error 实现 `__tostring`，所以 `print(err)` 可以
直接得到可读消息。libcurl 错误保留数字 code、符号 name 和 `CURLOPT_ERRORBUFFER` 的
消息；不支持的协议、URL 格式错误和 libcurl 不内置的协议能力归类为 `protocol`。

用户 callback 在 task 状态和 native 资源完成清理后才执行。callback 异常交给 session
的 `on_callback_error`；默认输出带 traceback 的错误，但不破坏其他请求。默认 session
使用模块字段 `request.on_callback_error`。

## 6. C 核心设计

### 6.1 manager

manager userdata 的核心字段概念如下：

```c
typedef struct request_multi {
    lua_State *lua;
    CURLM *multi;
    CURLSH *share;
    request_transfer_t *transfers;
    int callback_owner_index;
    int action_depth;
    bool closed;
} request_multi_t;
```

它负责：

- 创建并配置 `CURLM`。
- 安装 `CURLMOPT_SOCKETFUNCTION` 和 `CURLMOPT_TIMERFUNCTION`。
- 通过活动 task 和 transfer registry 引用防止 transfer userdata 被 Lua GC 提前回收。
- 包装 `curl_multi_add_handle()`、`curl_multi_socket_action()`、
  `curl_multi_info_read()` 和 `curl_multi_remove_handle()`。
- 检测递归调用；在 libcurl action 尚未返回时禁止再次进入同一个 manager。
- 保存内部 Lua 回调的错误，确保 Lua longjmp 不越过 libcurl 的 C 栈。

socket/timer Lua 回调保存在 manager userdata 的环境表中，而不是以永久 registry 引用
保存。这样 manager 在 libcurl 操作期间能强引用回调，但不可达的空闲 session 不会因为
`manager -> callback -> driver -> manager` 的 registry 根而永久存活。每次进入可能触发
libcurl callback 的 C 方法时，将 manager 当前所在的 `lua_State` 和栈索引绑定到操作；
不能永久保存首次创建 manager 的 coroutine 栈指针，因为后续事件通常从 luv 主线程进入。

C 核心向 Lua driver 提供以下最小内部接口，具体名字可以在实现时调整，但边界不应扩大：

```lua
local manager = core.new(socket_callback, timer_callback, options)
local transfer, err = manager:add(options)
local completions, err = manager:socket_action(socket, event_mask)
local completions, err = manager:timeout_action()
local completion, err = manager:cancel(transfer, reason)
local completions, err = manager:close()
```

`core` 导出 poll/action bitmask 常量，Lua 层不硬编码 libcurl 的枚举数值。上述方法都是
同步的 native 操作，但只返回内部完成项，不执行用户代码。`socket_action()` 和
`timeout_action()` 在 C 层防御性地处理 `CURLM_CALL_MULTI_PERFORM`，然后一次性排空
`curl_multi_info_read()`。所有 `CURLMcode` 和 `CURLcode` 都必须检查，不能只依赖
`running_handles` 的值。

`CURLMOPT_SOCKETDATA` 和 `CURLMOPT_TIMERDATA` 都指向 manager。socket callback 将 socket
和 `CURL_POLL_*` 状态传给 Lua，timer callback 将 timeout 毫秒数传给 Lua。Linux/macOS
阶段无需使用 `curl_multi_assign()`，因为 poll 生命周期由 Lua 的 socket map 管理；后续
如果使用 `socketp` 优化查找，仍必须由 generation 防止已复用描述符命中旧对象。

### 6.2 transfer

每个 transfer userdata 拥有：

- 一个 `CURL *easy`。
- 请求 header 的 `curl_slist`。
- 对请求 body Lua 字符串的 registry 引用，保证传输期间指针稳定。
- 响应 body、响应头行的 native 动态缓冲区。
- `CURL_ERROR_SIZE` 错误缓冲区。
- 大小限制、OOM、超限、取消等状态标志。
- 请求状态以及所属 manager 指针。

`CURLOPT_PRIVATE` 保存 transfer 指针，用于从 `CURLMsg` 找回对象；manager 同时在 Lua
registry 中强引用 transfer，不能只依赖裸指针保证生命周期。

write/header callback 只向 native 缓冲区写入，不执行用户 Lua 代码。扩容必须检查
`size_t` 加法和乘法溢出，`realloc()` 失败时保留旧指针，并以短写使 libcurl 中止请求。
超出配置上限时设置明确标志，最终报告 `kind = "limit"`，而不是含糊地报告
`CURLE_WRITE_ERROR`。

完成时，C 层依次执行：

1. 从 `curl_multi_info_read()` 取出 `CURLMSG_DONE`。
2. 从 multi 移除 easy handle。
3. 通过 `curl_easy_getinfo()` 收集状态码、最终 URL、HTTP 版本和时间指标。
4. 将 body 和原始 header 行转换为 Lua 值。
5. 释放 easy handle、header list、body 引用和 native 缓冲区。
6. 把完成项返回 Lua 分发队列。

必须先固定完整结果并释放 native 传输资源，再调用用户 callback 或恢复协程。

### 6.3 libcurl 全局初始化

native 模块以进程级 once 机制调用 `curl_global_init(CURL_GLOBAL_DEFAULT)`。模块不会在
任意 Lua state GC 时调用 `curl_global_cleanup()`，因为同一进程中的其他模块可能仍在
使用 libcurl，而且动态模块卸载时机不可可靠判断。该策略应在 API 文档中明确。

## 7. libcurl 与 luv 的事件桥接

### 7.1 socket callback

libcurl 通过 socket callback 给出以下关注状态：

| libcurl 状态 | luv poll 事件 |
| --- | --- |
| `CURL_POLL_IN` | `"r"` |
| `CURL_POLL_OUT` | `"w"` |
| `CURL_POLL_INOUT` | `"rw"` |
| `CURL_POLL_REMOVE` | stop 并 close 对应 poll handle |

C callback 使用 `lua_pcall()` 同步调用内部 driver，不允许该 Lua 回调 yield。这里不能把
REMOVE 简单排队到 `curl_multi_socket_action()` 返回以后：libcurl 可能在 socket callback
返回后立即关闭 socket，而 libuv 此时仍可能监视该描述符。同步执行 `poll:stop()` 可以
保证 socket 生命周期顺序正确。

内部 driver 维护：

```lua
self.polls[socket] = {
    handle = poll,
    generation = generation,
    events = "rw",
}
```

每次新建 poll 都递增 generation。poll callback 先核对 map 中的对象和 generation，
再调用 libcurl；这样 fd 被操作系统快速复用时，旧 handle 的迟到 callback 不会作用到
新连接。REMOVE 时先从 `polls` 删除，再 stop/close；正在 close 的对象由
`closing_handles` 强引用到 close callback 为止。

luv poll callback 到 libcurl action 的映射如下：

| luv 结果 | `curl_multi_socket_action()` bitmask |
| --- | --- |
| readable | `CURL_CSELECT_IN` |
| writable | `CURL_CSELECT_OUT` |
| readable + writable | 两者按位或 |
| poll error | `CURL_CSELECT_ERR` |

每次 socket action 返回后都必须立即读取全部 `CURLMSG_DONE`，但用户完成回调只加入 Lua
分发队列，不在 libcurl action 的调用栈中执行。

### 7.2 timer callback

一个 `CURLM` 只对应一个按需创建并复用的 luv timer。libcurl timer callback 的参数处理
如下：

- `timeout_ms < 0`：停止当前 timer。
- `timeout_ms == 0`：用 0 毫秒的单次 timer 安排到下一次 loop tick，禁止递归调用 curl。
- `timeout_ms > 0`：stop 后用该延迟重新启动单次 timer。

timer 到期后调用：

```c
curl_multi_socket_action(
    multi,
    CURL_SOCKET_TIMEOUT,
    0,
    &running_handles
);
```

timer 同样携带 generation，忽略重设或停止前已经排队的旧 callback。不能以固定周期
轮询 `curl_multi_perform()`，否则会造成额外延迟或空转。

停止后的 timer 使用 `uv_unref()`，重新启动前使用 `uv_ref()`；完成分发 timer 采用相同
规则。因此空闲 session 可以保留连接池和可复用 timer，但不会阻止 `uv.run()` 退出。
timer callback 对 driver 使用弱引用，避免 stopped handle 通过 callback 形成自引用。

加入第一个 easy handle 时，libcurl 通常通过 timer callback 请求 `timeout_ms == 0`。
driver 据此安排 0 毫秒 timer，由下一次 loop tick 的 `timeout_action()` 启动传输。即使
某个 libcurl 版本没有发出该回调，`manager:add()` 也必须返回“需要 kick”标志，driver
仍以相同的 0 毫秒 timer 启动，不能在公共 request 方法中递归执行传输。

### 7.3 回调错误

socket/timer 的内部 Lua 回调由 `lua_pcall()` 保护。失败时 C callback 复制错误对象，
返回 libcurl 规定的失败值；最外层 native 方法随后返回 `nil, err`。driver 把 session
转为失败关闭状态，取消所有活动请求，并确保已创建的 luv handle 被 stop/close。

任何 libcurl callback 都不会直接调用用户 callback。这样用户代码无法在 libcurl 栈内
取消、添加请求或递归进入同一个 CURLM。

## 8. 请求生命周期和并发

task 状态机如下：

```text
new --add_handle--> active --CURLMSG_DONE--> completing --> done
 |                     |
 +--setup failure      +--cancel/close--> completing --> cancelled
```

- 公共 Lua 参数校验在创建 task 前完成，失败时直接抛出参数错误。
- `new` 期间的 native setup 失败转换为异步完成错误，task 仍按一次通知规则结束。
- `active` 由 manager 强引用，普通 Lua GC 不会取消请求。
- `completing` 已从 multi 移除且结果固定，但尚未执行用户通知。
- `done` 和 `cancelled` 都是终态，重复取消无效果。

同一个 session 的所有方法只能在创建它的 Lua state 和线程上调用。事件回调也必须来自
同一个 luv loop。libcurl 内部可以使用异步 DNS 线程，但这些线程不能进入 Lua。

取消活动请求时调用 `curl_multi_remove_handle()`，随后收集 socket/timer 更新并释放 easy
资源。取消完成通知进入统一分发队列。用户 callback 中允许安全地发起或取消其他请求，
因为此时已经离开 libcurl action。

连接数通过 `CURLMOPT_MAX_TOTAL_CONNECTIONS` 和
`CURLMOPT_MAX_HOST_CONNECTIONS` 配置，由 libcurl 负责等待连接和复用连接。若 libcurl
支持 multiplex，默认启用 HTTP/2 multiplex，但不强制服务器使用特定 HTTP 版本。

显式 session 启用 cookie 时创建一个 `CURLSH`，设置 `CURL_LOCK_DATA_COOKIE`，并让该
session 的所有 easy handle 使用 `CURLOPT_SHARE` 和 `CURLOPT_COOKIEFILE = ""`。默认
session 不启用 cookie engine。所有访问发生在同一个事件循环线程；若未来允许跨线程，
必须先补充 share lock callback。

## 9. 请求选项映射

基础安全选项对每个 easy handle 固定设置：

- `CURLOPT_NOSIGNAL = 1L`。
- `CURLOPT_PROTOCOLS_STR = "http,https"`，旧版 libcurl 使用等价 bitmask。
- `CURLOPT_REDIR_PROTOCOLS_STR = "http,https"`。
- `CURLOPT_SSL_VERIFYPEER = 1L`。
- `CURLOPT_SSL_VERIFYHOST = 2L`。
- `CURLOPT_ACCEPT_ENCODING = ""`，让 libcurl 使用其支持的内容编码。
- write、header 和 error buffer callback/userdata。

`CURLOPT_PROTOCOLS_STR` 和 `CURLOPT_REDIR_PROTOCOLS_STR` 从 libcurl 7.85.0 开始提供，而本
项目最低版本是 7.68.0。因此必须同时使用编译期宏和运行期版本进行保护：新版本使用
字符串选项，旧版本使用 `CURLOPT_PROTOCOLS`、`CURLOPT_REDIR_PROTOCOLS` 以及
`CURLPROTO_HTTP | CURLPROTO_HTTPS`。其他高于最低版本才出现的 API 遵循相同规则，不能
因为编译机器头文件较新，就假定运行机器的 libcurl 也支持。

Lua 层先把简洁选项规范化，再映射到 libcurl：

| Lua 选项 | libcurl 设置 |
| --- | --- |
| `timeout.connect` | 秒转毫秒后设置 `CURLOPT_CONNECTTIMEOUT_MS` |
| `timeout.total` 或数字 `timeout` | 秒转毫秒后设置 `CURLOPT_TIMEOUT_MS` |
| `allow_redirects` | `CURLOPT_FOLLOWLOCATION` |
| `max_redirects` | `CURLOPT_MAXREDIRS` |
| `proxy` | `CURLOPT_PROXY` |
| `verify` 为路径 | `CURLOPT_CAINFO` |
| `cert` 为路径或 table | `CURLOPT_SSLCERT` / `CURLOPT_SSLKEY` |
| `verify` 为 boolean | verify peer/host，默认必须为 true |
| `auth` | `CURLOPT_USERNAME` / `CURLOPT_PASSWORD` |

默认允许 libcurl 读取系统 proxy 环境变量。`proxy = false` 时显式设置空 proxy，保证不
使用环境代理。`verify = false` 必须由调用方明确给出，文档中标为仅供受控测试。

HTTP 状态码本身不属于传输错误。包括 4xx 和 5xx 在内，只要成功取得合法 HTTP 响应，
callback 都得到 `response, nil`；用户通过 `status_code` 或 `ok` 判断业务结果。这与 Python
Requests 一致，也使响应 body 和 header 在错误状态码下仍然可用。

响应体限制作用于 libcurl 解压后的字节，响应头限制作用于所有状态行、重定向头、1xx
头和 trailer 的总和。

## 10. 响应头解析

C header callback 保留 libcurl 提供的完整行和边界，不尝试在 callback 中做复杂解析。
Lua 层在传输结束后执行以下规则：

1. 状态行开始一个新的响应头块。
2. 空行结束当前头块。
3. 第一个冒号之前是字段名，之后去除可选的首尾空白作为字段值。
4. 字段名以小写形式建立索引，同时保留原始名称、顺序和重复项。
5. 为兼容旧服务器，首字符为空白的行可作为上一字段的 continuation；没有上一字段则报
   `protocol` 错误。
6. 最后一个非 1xx、非代理 CONNECT 的状态块作为最终 headers；此前状态块进入 history。
7. 最终 headers 之后没有状态行的字段块作为 trailers。

解析不能用简单的 `name -> value` map 覆盖字段，因为 `Set-Cookie` 等字段不能安全合并。

## 11. 关闭和资源所有权

资源关系如下：

```text
session
    +-- native manager / CURLM
    +-- optional CURLSH cookie store
    +-- curl timer
    +-- completion dispatch timer
    +-- polls[socket]
    +-- active requests
            +-- transfer / CURL easy
            +-- curl_slist
            +-- request body registry ref
            +-- response buffers
```

显式关闭顺序为：

1. session 标记为 closing，拒绝新请求。
2. 从 multi 移除全部 easy handle，将 task 标记为 cancelled 并加入完成队列。
3. stop 并 close curl timer 和全部 poll handle，以 Lua 强引用等待 close callback。
4. 清理 CURL easy、CURLM、CURLSH、slist、buffer 和 registry 引用。
5. 使用 completion dispatch timer 在未来的 loop tick 分发全部 task 完成通知。
6. 完成队列清空后 close dispatch timer；全部 luv close callback 执行完毕后，最后调用
   session close callback。

native userdata 的 `__gc` 是异常路径的最后保障，不能代替正常的 `session:close()`。
活动 poll callback 会强引用 session，因此有活动 I/O 时 session 不会先于 luv handle
被回收。
所有 cleanup 函数必须允许部分初始化并可重复进入。

LuaJIT 层使用 `newproxy(true)` 为 session 建立 GC 哨兵。正常 close 时解除哨兵；如果用户
丢弃未关闭的 session，哨兵只执行无用户通知的 native/luv 清理，作为异常路径最后保障。

## 12. 构建方案

### 12.1 系统依赖安装

项目源码不内置 libcurl。另一台机器从源码编译前，应使用系统包管理器安装 C 编译工具、
CMake、pkg-config 和 libcurl 开发包。常见系统的参考命令如下：

```sh
# Ubuntu / Debian，默认推荐 OpenSSL backend
sudo apt install build-essential cmake pkg-config libcurl4-openssl-dev

# Fedora / RHEL
sudo dnf install gcc cmake pkgconf-pkg-config libcurl-devel

# Alpine
sudo apk add build-base cmake pkgconf curl-dev

# macOS / Homebrew
brew install cmake pkg-config curl
```

Debian 系也可以使用 `libcurl4-gnutls-dev`。本项目不依赖具体 TLS backend，只要求该
libcurl 构建支持 HTTPS。Homebrew 的 curl 可能是 keg-only，无法自动找到时使用：

```sh
cmake -S . -B build \
    -DCMAKE_PREFIX_PATH="$(brew --prefix curl)"
```

或者将 `$(brew --prefix curl)/lib/pkgconfig` 加入 `PKG_CONFIG_PATH`。这些是构建环境参数，
不应在项目源码中硬编码 `/usr/include`、Homebrew prefix 或特定 TLS 库路径。

### 12.2 CMake 查找规则

使用 CMake 作为底层构建系统，LuaRocks rockspec 调用 CMake。优先用 pkg-config 创建
imported target，让 libcurl 自己声明必要的编译和链接参数：

```cmake
find_package(PkgConfig QUIET)

if(PkgConfig_FOUND)
    pkg_check_modules(
        LIBCURL
        QUIET
        IMPORTED_TARGET
        libcurl>=7.68
    )
endif()

if(TARGET PkgConfig::LIBCURL)
    set(REQUEST_LIBCURL_TARGET PkgConfig::LIBCURL)
else()
    find_package(CURL 7.68 REQUIRED)
    set(REQUEST_LIBCURL_TARGET CURL::libcurl)
endif()

target_link_libraries(
    request_core
    PRIVATE
    ${REQUEST_LIBCURL_TARGET}
)
```

构建规则还包括：

- 源码统一使用 `#include <curl/curl.h>`，不写绝对头文件路径。
- pkg-config 不可用时，可回退到 CMake `find_package(CURL 7.68 REQUIRED)`。
- 如果用户同时安装多份 libcurl，允许通过 `CMAKE_PREFIX_PATH` 或 `PKG_CONFIG_PATH` 选择。
- 从 LuaRocks/LuaJIT 环境获取 Lua 头文件和模块安装目录。
- C 模块输出为 `request/core.so`，不硬编码平台后缀。
- luv 是 LuaRocks 运行时依赖；C 核心不链接 libuv。
- C 代码采用 C99，只使用 Lua 5.1 可用 API 或项目内兼容 helper。

配置阶段检查最低 libcurl 版本和必需的 multi socket API。配置错误必须说明缺少的是开发
包、头文件、库还是最低版本，而不能只输出普通的 linker failure。

### 12.3 LuaRocks 约定

rockspec 将 luv 声明为 Lua 运行时依赖：

```lua
dependencies = {
    "lua >= 5.1",
    "luv >= 1.44",
}
```

不使用 LuaRocks `external_dependencies` 检查 libcurl。该机制通常只检查 `/usr/include`
等固定目录，在 Debian/Ubuntu multiarch 布局中可能漏掉
`/usr/include/<triplet>/curl/curl.h`，从而在开发包已安装时误报缺失。libcurl 的头文件、
库、最低版本和 multi socket API 统一由 CMake/pkg-config 检查；实际加载版本和 capability
仍由 `curl_version_info()` 检查。

### 12.4 链接和发布策略

首个版本默认动态链接系统 libcurl，不在 rock 中捆绑 libcurl。这样由操作系统负责 TLS
证书、漏洞修复和 ABI 兼容更新，也避免静态链接时手工处理 OpenSSL/GnuTLS、nghttp2、
zlib、brotli、zstd、libidn2 和 libpsl 等传递依赖。

静态链接只作为后续可选构建模式，并且必须满足以下条件：

- libcurl 和全部静态依赖以 position-independent code 编译。
- 使用 `pkg-config --static` 或等价 imported target 获取完整链接参数。
- 发布物包含对应第三方许可证，并有明确的安全升级和重新发布流程。
- CI 在最终产物上验证 TLS、HTTP/2、压缩和 DNS 能力，而不只验证链接成功。

动态构建完成后，发布检查应在 Linux 使用 `ldd request/core.so`，在 macOS 使用
`otool -L request/core.so`，确认最终依赖指向预期 libcurl，且不会从构建机临时目录加载。
如果要发布预编译 rock，必须按操作系统、CPU 架构、LuaJIT ABI 和动态库 ABI 分开构建；
源码 rock 则明确要求目标机器预先安装上述开发包。

## 13. 编码规范

Lua 和 C 源码统一遵循以下规则：

- 只使用空格缩进，一级缩进固定为 4 个空格，禁止 tab。
- 代码行以 100 列为目标上限；长参数列表、条件和字符串在语义边界换行。
- 续行再缩进 4 个空格，避免只靠视觉对齐形成脆弱格式。
- Lua 表的多行字段和 C 的多行参数每行一个，末项保留逗号。
- C 使用 K&R 大括号风格；指针星号靠变量名。
- callback 保持短小，复杂工作放入可单测的普通函数。
- 注释解释生命周期、所有权和非显然约束，不复述代码。

后续实现应提交 `.editorconfig` 和 `.clang-format`，其中至少设置
`indent_size = 4`、`IndentWidth: 4`、`UseTab: Never` 和 `ColumnLimit: 100`。Lua 格式化配置
也必须保持相同缩进和列宽。

## 14. 测试方案

### 14.1 单元测试

- 请求选项规范化、方法和 body 组合。
- header 注入拒绝、重复 header 和多响应头块解析。
- response/error 对象行为。
- task/session 状态转换、幂等取消和重复 close。
- 快捷方法参数省略、session 默认值合并、query/form 编码和 cookie 隔离。
- timer 的负值、零值、重设和 stale generation。
- poll 事件 bitmask、REMOVE、fd 复用和 stale callback。

### 14.2 本地集成测试

测试只访问本机 fixture server，不依赖公网。fixture 覆盖：

- GET、HEAD、各种 request body、二进制 body。
- 分块响应、Content-Length、gzip、空响应和连接提前关闭。
- 1xx、重定向链、重复 header、trailer 和错误格式 header。
- 延迟首字节、整体超时、连接超时和低速响应。
- HTTPS 校验成功、未知 CA、主机名不匹配和显式测试 CA。
- keep-alive 连接复用、多 host 并发和 HTTP/2 multiplex（环境支持时）。
- 活动请求取消、callback 内创建/取消请求、session close。
- body/header 超限以及大量并发请求。

### 14.3 稳定性检查

- 在 ASan、UBSan 下运行 C 集成测试。
- 可用时运行 Valgrind，并检查 Lua registry 引用和 fd 数量无持续增长。
- 循环创建/关闭 session，验证没有 uv handle 阻止事件循环退出。
- 在 callback 中主动抛错，验证其他传输仍可完成且没有跨 C 栈 longjmp。

## 15. 实现阶段划分

1. 建立 CMake/LuaRocks 骨架，实现 buffer、manager 和 transfer 的确定性清理。
2. 完成 socket/timer bridge、单请求 GET 和本地 HTTP 集成测试。
3. 加入快捷方法、并发、取消、超时、请求 body、headers 和结构化错误。
4. 加入重定向、HTTPS、代理、连接限制、metrics 和 capability 查询。
5. 完成协程 API、close 流程、故障注入和 sanitizer 测试。
6. 在后续版本设计基于 `CURL_WRITEFUNC_PAUSE` 的流式下载与背压；在此之前不允许
   `on_data` callback 伪装成可背压的流式接口。

## 16. 验收标准

- 多个请求可以由同一个 luv loop 并发完成，过程中没有定时轮询和 busy loop。
- socket interest 和 timeout 完全由 libcurl callback 驱动。
- 请求完成、失败、取消均只通知一次，且通知发生在 libcurl 调用栈之外。
- 任意中间步骤失败都不会遗留 CURL handle、luv handle、fd 或 Lua registry 引用。
- TLS 校验默认开启，协议默认限制为 HTTP/HTTPS，请求头不能注入 CR/LF。
- 无异步 DNS 的 libcurl 构建会明确暴露能力限制。
- 所有 Lua/C 源码均使用 4 个空格缩进并通过格式检查。
