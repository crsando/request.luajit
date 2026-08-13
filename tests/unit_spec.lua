local t = require("tests.testlib")
local core = require("request.core")
local Headers = require("request.headers")
local Options = require("request.options")
local Session = require("request.session")
local Task = require("request.task")
local uv = require("luv")

t.test("query and form encoding", function()
    local options = Options.normalize("post", "http://localhost/path?base=1", {
        params = {
            { "tag", "lua jit" },
            { "tag", "curl" },
        },
        data = {
            name = "hello world",
        },
    })

    t.equal(options.method, "POST")
    t.equal(options.url, "http://localhost/path?base=1&tag=lua%20jit&tag=curl")
    t.equal(options.body, "name=hello%20world")
    t.equal(options.headers[1], "content-type: application/x-www-form-urlencoded")
end)

t.test("timeout normalization", function()
    local options = Options.normalize("GET", "https://example.com", {
        timeout = {
            connect = 0.0011,
            total = 1.25,
        },
    })

    t.equal(options.connect_timeout_ms, 2)
    t.equal(options.timeout_ms, 1250)
end)

t.test("header injection is rejected", function()
    t.raises(function()
        Options.normalize("GET", "https://example.com", {
            headers = {
                value = "safe\r\ninjected: true",
            },
        })
    end, "CR or LF")

    t.raises(function()
        Options.normalize("GET", "https://example.com", {
            headers = {
                ["bad header"] = "value",
            },
        })
    end, "header name must be a valid HTTP token")
end)

t.test("C string options reject embedded NUL bytes", function()
    for _, case in ipairs({
        {
            callback = function()
                Options.normalize("GET", "https://example.com/a\0b")
            end,
            pattern = "url must not contain NUL",
        },
        {
            callback = function()
                Options.normalize("GET", "https://example.com", {
                    headers = {
                        value = "a\0b",
                    },
                })
            end,
            pattern = "header value must not contain NUL",
        },
        {
            callback = function()
                Options.normalize("GET", "https://example.com", {
                    proxy = "http://proxy.invalid\0ignored",
                })
            end,
            pattern = "proxy must not contain NUL",
        },
    }) do
        t.raises(case.callback, case.pattern)
    end
end)

t.test("custom methods must be valid HTTP tokens", function()
    local options = Options.normalize("custom-method", "https://example.com")

    t.equal(options.method, "CUSTOM-METHOD")
    t.raises(function()
        Options.normalize("BAD METHOD", "https://example.com")
    end, "valid HTTP token")
    t.raises(function()
        Options.normalize("GET\r\nInjected: yes", "https://example.com")
    end, "valid HTTP token")
end)

t.test("boolean options are type checked", function()
    t.raises(function()
        Options.normalize("GET", "https://example.com", {
            allow_redirects = "yes",
        })
    end, "allow_redirects must be a boolean")

    t.raises(function()
        Options.merge({}, "not a table")
    end, "options must be a table")

    t.raises(function()
        Options.normalize("GET", "https://example.com", {
            allow_redirect = true,
        })
    end, "unknown request option: allow_redirect")
end)

t.test("response header blocks and duplicates", function()
    local parsed = assert(Headers.parse(table.concat({
        "HTTP/1.1 100 Continue\r\n",
        "x-first: one\r\n",
        "\r\n",
        "HTTP/1.1 200 OK\r\n",
        "x-value: one\r\n",
        "x-value: two\r\n",
        "\r\n",
    })))

    t.equal(parsed.status_code, 200)
    t.equal(parsed.headers["X-Value"], "one")
    t.equal(#parsed.headers:get_all("x-value"), 2)
    t.equal(parsed.history[1].status_code, 100)
end)

t.test("await rejects the main Lua thread", function()
    local task = Task.new({}, nil)

    t.raises(function()
        task:await()
    end, "yieldable coroutine")
end)

t.test("a settled task can be awaited and cancellation is idempotent", function()
    local cancellation_count = 0
    local task = Task.new({
        _cancel = function()
            cancellation_count = cancellation_count + 1
            return true
        end,
    })

    t.truthy(task:cancel("done"))
    t.equal(task:cancel("again"), false)
    t.equal(cancellation_count, 1)
    task:_resolve(nil, {
        kind = "cancelled",
    })

    local response
    local err
    coroutine.wrap(function()
        response, err = task:await()
    end)()
    t.equal(response, nil)
    t.equal(err.kind, "cancelled")
end)

t.test("session options merge maps", function()
    local merged = Options.merge({
        headers = {
            accept = "application/json",
            ["X-Shared"] = "default",
        },
    }, {
        headers = {
            ["x-shared"] = "request",
            extra = "yes",
        },
    })

    t.equal(merged.headers.accept, "application/json")
    t.equal(merged.headers["X-Shared"], nil)
    t.equal(merged.headers["x-shared"], "request")
    t.equal(merged.headers.extra, "yes")
end)

t.test("integer limits are validated", function()
    t.raises(function()
        Options.normalize("GET", "https://example.com", {
            max_body_bytes = 1.5,
        })
    end, "non%-negative integer")

    t.raises(function()
        Options.normalize("GET", "https://example.com", {
            max_redirects = -1,
        })
    end, "non%-negative integer")

    t.raises(function()
        Options.normalize("GET", "https://example.com", {
            max_body_bytes = math.huge,
        })
    end, "non%-negative integer")
end)

t.test("a libcurl event callback failure is reported as manager-fatal", function()
    local manager = core.new(function()
        error("intentional socket callback failure")
    end, function()
        error("intentional timer callback failure")
    end, {
        cookies = false,
    })
    local transfer, callback_err, fatal = manager:add(
        Options.normalize("GET", "http://127.0.0.1:1/")
    )

    t.equal(transfer, nil)
    t.truthy(fatal)
    t.matches(callback_err, "intentional timer callback failure")
    local completions = assert(manager:close())
    t.equal(#completions, 0)
end)

t.test("a fatal add callback error closes the session and completes its task", function()
    local real_new = core.new
    core.new = function(_, _, options)
        return real_new(function()
            error("intentional socket callback failure")
        end, function()
            error("intentional timer callback failure")
        end, options)
    end

    local ok, session_or_err = pcall(Session.new, {
        cookies = false,
    })
    core.new = real_new
    if not ok then
        error(session_or_err)
    end

    local session = session_or_err
    local task = session:get("http://127.0.0.1:1/")
    local response
    local err
    coroutine.wrap(function()
        response, err = task:await()
    end)()
    uv.run()

    t.truthy(session:is_closed())
    t.equal(response, nil)
    t.equal(err.kind, "internal")
    t.matches(err.message, "intentional timer callback failure")
    t.truthy(not uv.loop_alive())
end)

t.done()
