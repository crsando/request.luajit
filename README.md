# request.luajit

Asynchronous HTTP/HTTPS requests for LuaJIT, powered by libcurl's multi socket API and luv.

## Requirements

- LuaJIT 2.1
- luv 1.44 or newer
- libcurl 7.68 or newer, built with HTTP, HTTPS, and TLS support
- CMake 3.16 or newer and a C99 compiler
- pkg-config is recommended

On Ubuntu or Debian, install the build and runtime dependencies with:

```sh
sudo apt install \
    build-essential \
    cmake \
    libcurl4-openssl-dev \
    libluajit-5.1-dev \
    lua-luv \
    luajit \
    pkg-config
```

On macOS with Homebrew:

```sh
brew install cmake pkg-config curl luajit luarocks
luarocks \
    --lua-dir="$(brew --prefix luajit)" \
    --lua-version=5.1 \
    install luv
```

If Homebrew's keg-only curl is not found, add its prefix to `CMAKE_PREFIX_PATH`.

## Build

The Makefile provides a small wrapper around the CMake build:

```sh
make build
make test
sudo make install PREFIX=/usr/local
```

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

LuaRocks can build and install the current checkout with:

```sh
luarocks make request-scm-1.rockspec
```

For a local checkout, configure Lua's module paths before running examples:

```sh
export LUA_PATH="$PWD/lua/?.lua;$PWD/lua/?/init.lua;;"
export LUA_CPATH="$PWD/build/?.so;$PWD/build/?/?.so;;"
```

## Usage

Callback API:

```lua
local request = require("request")
local uv = require("luv")

request.get("https://example.com", function(response, err)
    if err then
        print(err)
        return
    end

    print(response.status_code, response.body)
    request.close()
end)

uv.run()
```

Coroutine API:

```lua
local request = require("request")
local uv = require("luv")

coroutine.wrap(function()
    local response, err = request.get("https://example.com", {
        timeout = {
            connect = 5,
            total = 30,
        },
    }):await()

    if err then
        print(err)
    else
        print(response.status_code, response.body)
    end

    request.close()
end)()

uv.run()
```

Use an explicit session for shared defaults, cookies, or an independent connection pool:

```lua
local session = request.session({
    cookies = true,
    headers = {
        ["user-agent"] = "my-service/1.0",
    },
})

session:get("https://example.com/profile", callback)
```

Common request options:

```lua
request.post("https://example.com/items", {
    params = {
        verbose = true,
    },
    headers = {
        ["content-type"] = "application/json",
    },
    data = [[{"name":"demo"}]],
    timeout = {
        connect = 5,
        total = 30,
    },
    allow_redirects = true,
    max_redirects = 10,
    verify = true,
    proxy = false,
}, callback)
```

`data` accepts a binary-safe string or a form table. `params` and form values are percent encoded.
HTTP 4xx and 5xx responses are returned normally with `response.ok == false`; use
`response:raise_for_status()` when exception-style HTTP status handling is preferred. DNS, connect,
TLS, timeout, cancellation, protocol, and response size failures are returned through `err`.

Each request returns a task with `cancel()`, `state()`, and `await()`. `await()` must be called from
a yieldable coroutine. Neither the module nor a session calls `uv.run()` for the application.
Unknown options and values containing NUL where libcurl expects a C string are rejected before a
request is started. Binary `data` may contain NUL bytes.

The native module initializes libcurl once per process. It intentionally does not call
`curl_global_cleanup()`, because other modules in the same process may still be using libcurl.

The supported request options and lifecycle guarantees are documented in
[DESIGN.md](DESIGN.md).

## Test

The test suite starts HTTP and HTTPS fixture servers bound only to loopback:

```sh
tests/run.sh
```

To include AddressSanitizer and UndefinedBehaviorSanitizer:

```sh
make asan-test
```
