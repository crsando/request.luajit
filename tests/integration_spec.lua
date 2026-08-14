local uv = require("luv")
local request = require("request")
local t = require("tests.testlib")

local base_url = assert(os.getenv("REQUEST_TEST_URL"), "REQUEST_TEST_URL is required")
local https_url = os.getenv("REQUEST_TEST_HTTPS_URL")
local mtls_url = os.getenv("REQUEST_TEST_MTLS_URL")
local cert_file = os.getenv("REQUEST_TEST_CA_FILE")
local client_cert_file = os.getenv("REQUEST_TEST_CLIENT_CERT_FILE")
local client_key_file = os.getenv("REQUEST_TEST_CLIENT_KEY_FILE")

local function run_async(callback)
    local finished = false
    local timed_out = false
    local watchdog = assert(uv.new_timer())

    watchdog:start(5000, 0, function()
        timed_out = true
        watchdog:stop()
        watchdog:close()
        uv.stop()
    end)

    coroutine.wrap(function()
        callback()
        finished = true
        watchdog:stop()
        watchdog:close()
    end)()

    uv.run()
    if timed_out then
        error("asynchronous test exceeded 5 seconds")
    end
    t.truthy(finished, "test coroutine did not finish")
    t.truthy(not uv.loop_alive(), "event loop still has active handles")
end

local function await(task)
    local response, err = task:await()
    if err then
        error(tostring(err), 2)
    end
    return response
end

local function handle_count()
    local count = 0

    uv.walk(function()
        count = count + 1
    end)
    return count
end

t.test("GET, query parameters, and response metadata", function()
    run_async(function()
        local response = await(request.get(base_url .. "/get", {
            params = {
                { "tag", "lua" },
                { "tag", "curl" },
            },
        }))

        t.equal(response.status_code, 200)
        t.truthy(response.ok)
        t.matches(response.body, '"tag": %["lua", "curl"%]')
        t.equal(response.headers["content-type"], "application/json")
        t.truthy(response.metrics.total_time >= 0)
        request.close()
    end)
end)

t.test("callback API is asynchronous", function()
    local returned = false
    local called = false

    request.get(base_url .. "/get", function(response, err)
        t.truthy(returned, "callback ran synchronously")
        t.equal(err, nil)
        t.equal(response.status_code, 200)
        called = true
        request.close()
    end)
    returned = true
    uv.run()
    t.truthy(called)
end)

t.test("binary request body and custom methods", function()
    run_async(function()
        local body = "a\0b\255c"
        local response = await(request.patch(base_url .. "/echo", {
            data = body,
        }))

        t.equal(response.body, body)
        t.equal(response.headers["x-method"], "PATCH")

        local get_body = await(request.get(base_url .. "/echo", {
            data = body,
        }))
        t.equal(get_body.body, body)
        t.equal(get_body.headers["x-method"], "GET")

        local custom = await(request.request("PROPFIND", base_url .. "/echo", {
            data = "custom-body",
        }))
        t.equal(custom.body, "custom-body")
        t.equal(custom.headers["x-method"], "PROPFIND")
        request.close()
    end)
end)

t.test("empty, compressed, chunked, informational, and trailer responses", function()
    run_async(function()
        local empty = await(request.get(base_url .. "/empty"))
        t.equal(empty.status_code, 204)
        t.equal(empty.body, "")

        local compressed = await(request.get(base_url .. "/gzip"))
        t.equal(compressed.body, "compressed response")

        local chunked = await(request.get(base_url .. "/chunked"))
        t.equal(chunked.body, "chunk-one-two")

        local informational = await(request.get(base_url .. "/informational"))
        t.equal(informational.status_code, 200)
        t.equal(informational.history[1].status_code, 103)
        t.equal(informational.history[1].headers.link, "</style.css>; rel=preload")

        local trailers = await(request.get(base_url .. "/trailers"))
        t.equal(trailers.body, "trailer-body")
        t.equal(trailers.trailers["x-trailer"], "available")
        request.close()
    end)
end)

t.test("HEAD and form request bodies", function()
    run_async(function()
        local head = await(request.head(base_url .. "/get"))
        t.equal(head.status_code, 200)
        t.equal(head.body, "")

        local form = await(request.post(base_url .. "/echo", {
            data = {
                { "name", "hello world" },
                { "tag", "lua" },
                { "tag", "curl" },
            },
        }))
        t.equal(form.body, "name=hello%20world&tag=lua&tag=curl")
        t.equal(
            form.headers["x-request-content-type"],
            "application/x-www-form-urlencoded"
        )
        request.close()
    end)
end)

t.test("redirect history and HTTP status semantics", function()
    run_async(function()
        local redirected = await(request.get(base_url .. "/redirect"))
        t.equal(redirected.status_code, 200)
        t.equal(redirected.body, "redirected")
        t.equal(#redirected.history, 1)
        t.equal(redirected.history[1].status_code, 302)

        local not_followed = await(request.get(base_url .. "/redirect", {
            allow_redirects = false,
        }))
        t.equal(not_followed.status_code, 302)
        t.equal(#not_followed.history, 0)

        local head = await(request.head(base_url .. "/redirect"))
        t.equal(head.status_code, 302)

        local response, err = request.get(base_url .. "/redirect-loop", {
            max_redirects = 2,
        }):await()
        t.equal(response, nil)
        t.equal(err.name, "CURLE_TOO_MANY_REDIRECTS")

        response, err = request.get(base_url .. "/redirect-file"):await()
        t.equal(response, nil)
        t.equal(err.kind, "protocol")
        t.equal(err.name, "CURLE_UNSUPPORTED_PROTOCOL")

        local missing = await(request.get(base_url .. "/status/404"))
        t.equal(missing.status_code, 404)
        t.equal(missing.ok, false)
        t.raises(function()
            missing:raise_for_status()
        end, "HTTP 404")
        request.close()
    end)
end)

t.test("an explicit HTTP proxy is passed to libcurl", function()
    run_async(function()
        local response = await(request.get("http://proxy-target.invalid/get", {
            proxy = base_url,
        }))

        t.equal(response.status_code, 200)
        t.matches(response.body, '"method": "GET"')
        request.close()
    end)
end)

t.test("duplicate response headers", function()
    run_async(function()
        local response = await(request.get(base_url .. "/duplicate-headers"))
        local values = response.headers:get_all("x-value")

        t.equal(values[1], "one")
        t.equal(values[2], "two")
        request.close()
    end)
end)

t.test("concurrent requests", function()
    run_async(function()
        local tasks = {}

        for index = 1, 12 do
            tasks[index] = request.get(base_url .. "/delay?seconds=0.01")
        end
        for index = 1, #tasks do
            local response = await(tasks[index])
            t.equal(response.status_code, 200)
        end

        request.close()
    end)
end)

t.test("session connection limits are enforced by libcurl", function()
    run_async(function()
        await(request.get(base_url .. "/concurrency/reset"))

        local session = request.session({
            cookies = false,
            max_host_connections = 1,
            max_total_connections = 1,
        })
        local tasks = {}
        for index = 1, 6 do
            tasks[index] = session:get(base_url .. "/concurrency/delay?seconds=0.02")
        end
        for index = 1, #tasks do
            await(tasks[index])
        end

        local maximum = await(session:get(base_url .. "/concurrency/max"))
        t.equal(maximum.body, "1")
        session:close()
        request.close()
    end)
end)

t.test("timeout and cancellation", function()
    run_async(function()
        local response, err = request.get(base_url .. "/delay?seconds=0.2", {
            timeout = 0.02,
        }):await()
        t.equal(response, nil)
        t.equal(err.kind, "timeout")
        t.equal(err.name, "CURLE_OPERATION_TIMEDOUT")

        local task = request.get(base_url .. "/delay?seconds=0.2")
        task:cancel("test cancellation")
        response, err = task:await()
        t.equal(response, nil)
        t.equal(err.kind, "cancelled")
        t.equal(task:state(), "cancelled")
        request.close()
    end)
end)

t.test("response size limit", function()
    run_async(function()
        local response, err = request.get(base_url .. "/large?size=4096", {
            max_body_bytes = 128,
        }):await()

        t.equal(response, nil)
        t.equal(err.kind, "limit")

        response, err = request.get(base_url .. "/large-header?size=4096", {
            max_header_bytes = 256,
        }):await()
        t.equal(response, nil)
        t.equal(err.kind, "limit")
        t.matches(err.message, "header")
        request.close()
    end)
end)

t.test("a prematurely closed response is a transfer error", function()
    run_async(function()
        local response, err = request.get(base_url .. "/close-early"):await()

        t.equal(response, nil)
        t.equal(err.kind, "curl")
        t.truthy(err.code ~= 0)
        request.close()
    end)
end)

t.test("explicit session shares cookies and connections", function()
    run_async(function()
        local session = request.session({
            cookies = true,
        })

        await(session:get(base_url .. "/cookie/set"))
        local cookie = await(session:get(base_url .. "/cookie/check"))
        t.matches(cookie.body, "session=available")

        local first = await(session:get(base_url .. "/connection"))
        local second = await(session:get(base_url .. "/connection"))
        t.equal(first.body, second.body)
        session:close()
    end)
end)

t.test("default session does not share cookies", function()
    run_async(function()
        await(request.get(base_url .. "/cookie/set"))
        local cookie = await(request.get(base_url .. "/cookie/check"))
        t.equal(cookie.body, "")
        request.close()
    end)
end)

t.test("callback failures are isolated", function()
    local reported
    local completed = false
    local session = request.session({
        cookies = false,
        on_callback_error = function(message)
            reported = tostring(message)
        end,
    })

    session:get(base_url .. "/get", function()
        error("intentional callback failure")
    end)
    session:get(base_url .. "/get", function(response, err)
        t.equal(err, nil)
        t.equal(response.status_code, 200)
        completed = true
        session:close()
    end)

    uv.run()
    t.truthy(completed)
    t.matches(reported, "intentional callback failure")
end)

t.test("callbacks can create and cancel requests without recursive curl actions", function()
    local session = request.session({
        cookies = false,
    })
    local completed = 0

    session:get(base_url .. "/get", function(response, err)
        t.equal(err, nil)
        t.equal(response.status_code, 200)
        completed = completed + 1

        local cancelled = session:get(base_url .. "/delay?seconds=0.2", function(
            cancelled_response,
            cancelled_err
        )
            t.equal(cancelled_response, nil)
            t.equal(cancelled_err.kind, "cancelled")
            completed = completed + 1
        end)
        t.truthy(cancelled:cancel("cancelled from callback"))

        session:get(base_url .. "/get", function(next_response, next_err)
            t.equal(next_err, nil)
            t.equal(next_response.status_code, 200)
            completed = completed + 1
            session:close()
        end)
    end)

    uv.run()
    t.equal(completed, 3)
end)

t.test("active requests retain an otherwise unreachable session", function()
    local called = false
    local weak = setmetatable({}, {
        __mode = "v",
    })

    do
        local session = request.session({
            cookies = false,
        })
        weak.session = session

        local task = session:get(base_url .. "/delay?seconds=0.02", function(response, err)
            t.equal(err, nil)
            t.equal(response.status_code, 200)
            called = true
        end)
        weak.task = task
    end

    collectgarbage()
    collectgarbage()
    uv.run()
    t.truthy(called)

    collectgarbage()
    collectgarbage()
    uv.run("nowait")
    collectgarbage()
    collectgarbage()
    uv.run("nowait")
    t.equal(weak.session, nil)
    t.equal(weak.task, nil)
    t.equal(handle_count(), 0)
end)

t.test("close is idempotent and callback is asynchronous", function()
    local session = request.session({
        cookies = false,
    })
    local returned = false
    local first = false

    session:close(function(err)
        t.truthy(returned)
        t.equal(err, nil)
        first = true
    end)
    returned = true
    uv.run()
    t.truthy(first)

    returned = false
    local second = false
    session:close(function(err)
        t.truthy(returned)
        t.equal(err, nil)
        second = true
    end)
    returned = true
    uv.run()
    t.truthy(second)
end)

t.test("close callback failures use the session error reporter", function()
    local reported
    local session = request.session({
        cookies = false,
        on_callback_error = function(message)
            reported = tostring(message)
        end,
    })

    session:close(function()
        error("intentional close callback failure")
    end)
    uv.run()
    t.matches(reported, "intentional close callback failure")
end)

t.test("closing a session cancels active requests", function()
    run_async(function()
        local session = request.session({
            cookies = false,
        })
        local task = session:get(base_url .. "/delay?seconds=0.2")

        session:close()
        local response, err = task:await()
        t.equal(response, nil)
        t.equal(err.kind, "cancelled")
        t.equal(task:state(), "cancelled")
    end)
end)

t.test("garbage collection closes an idle session", function()
    local weak = setmetatable({}, {
        __mode = "v",
    })

    run_async(function()
        local session = request.session({
            cookies = false,
        })
        weak.session = session

        await(session:get(base_url .. "/get"))
        session = nil
    end)

    collectgarbage()
    collectgarbage()
    uv.run("nowait")
    collectgarbage()

    t.equal(weak.session, nil)
    t.equal(handle_count(), 0)
end)

t.test("repeated create, request, and close cycles release all handles", function()
    local callbacks = 0

    for _ = 1, 100 do
        local session = request.session({
            cookies = false,
        })
        session:get(base_url .. "/delay?seconds=0.1", function(response, err)
            t.equal(response, nil)
            t.equal(err.kind, "cancelled")
            callbacks = callbacks + 1
        end)
        session:close()
    end

    uv.run()
    collectgarbage()
    collectgarbage()
    t.equal(callbacks, 100)
    t.equal(handle_count(), 0)
end)

t.test("basic authentication", function()
    run_async(function()
        local response = await(request.get(base_url .. "/auth", {
            auth = { "user", "pass" },
        }))
        t.equal(response.status_code, 200)
        request.close()
    end)
end)

if https_url then
    t.test("HTTPS verification", function()
        run_async(function()
            local verified = await(request.get(https_url .. "/get", {
                verify = cert_file,
            }))
            t.equal(verified.status_code, 200)

            local insecure = await(request.get(https_url .. "/get", {
                verify = false,
            }))
            t.equal(insecure.status_code, 200)

            local response, err = request.get(https_url .. "/get"):await()
            t.equal(response, nil)
            t.equal(err.kind, "curl")

            local mismatched_url = https_url:gsub("localhost", "127.0.0.1")
            response, err = request.get(mismatched_url .. "/get", {
                verify = cert_file,
            }):await()
            t.equal(response, nil)
            t.equal(err.kind, "curl")
            request.close()
        end)
    end)
end

if mtls_url then
    t.test("client certificates support mutual TLS", function()
        run_async(function()
            local response, err = request.get(mtls_url .. "/get", {
                verify = cert_file,
            }):await()
            t.equal(response, nil)
            t.equal(err.kind, "curl")

            response = await(request.get(mtls_url .. "/get", {
                verify = cert_file,
                cert = {
                    cert = client_cert_file,
                    key = client_key_file,
                },
            }))
            t.equal(response.status_code, 200)
            request.close()
        end)
    end)
end

t.done()
