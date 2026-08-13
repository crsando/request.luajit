local core = require("request.core")
local Driver = require("request.driver")
local Error = require("request.error")
local Headers = require("request.headers")
local Options = require("request.options")
local Response = require("request.response")
local Task = require("request.task")

local Session = {}
Session.__index = Session

local function default_reporter(message)
    io.stderr:write(tostring(message), "\n")
end

local function new_gc_guard(driver)
    local guard = newproxy(true)

    getmetatable(guard).__gc = function()
        if driver then
            driver:abandon()
            driver = nil
        end
    end

    return guard
end

local function disarm_gc_guard(guard)
    if guard then
        getmetatable(guard).__gc = nil
    end
end

local function request_error(completion)
    local kind = "curl"
    local message = completion.message

    if completion.cancelled then
        kind = "cancelled"
        message = completion.cancel_reason or message
    elseif completion.buffer_error == "limit" then
        kind = "limit"
        message = string.format("response %s exceeded its configured limit", completion.buffer)
    elseif completion.buffer_error then
        kind = "internal"
        message = string.format(
            "response %s buffer failed: %s",
            completion.buffer,
            completion.buffer_error
        )
    elseif completion.curl_code == core.CURLE_OPERATION_TIMEDOUT then
        kind = "timeout"
    end

    return Error.new({
        kind = kind,
        code = completion.curl_code,
        name = completion.curl_name,
        message = message or "request failed",
        url = completion.url,
        phase = "transfer",
    })
end

function Session.new(options)
    if options ~= nil and type(options) ~= "table" then
        error("session options must be a table", 2)
    end
    options = options or {}

    if options.cookies ~= nil and type(options.cookies) ~= "boolean" then
        error("cookies must be a boolean", 2)
    end
    if options.require_async_dns ~= nil and type(options.require_async_dns) ~= "boolean" then
        error("require_async_dns must be a boolean", 2)
    end
    if options.on_callback_error ~= nil and type(options.on_callback_error) ~= "function" then
        error("on_callback_error must be a function", 2)
    end

    local session_option_names = {
        cookies = true,
        max_host_connections = true,
        max_total_connections = true,
        on_callback_error = true,
        require_async_dns = true,
    }
    for name in pairs(options) do
        if not session_option_names[name] and not Options.is_request_option(name) then
            error("unknown session option: " .. tostring(name), 2)
        end
    end

    for _, name in ipairs({ "max_total_connections", "max_host_connections" }) do
        local value = options[name]
        if value ~= nil and
            (type(value) ~= "number" or value < 0 or value ~= math.floor(value) or
                value > 2147483647) then
            error(name .. " must be a non-negative integer", 2)
        end
    end

    if options.require_async_dns and not core.capabilities().async_dns then
        error("this libcurl build does not provide asynchronous DNS", 2)
    end

    local self = setmetatable({
        _active = {},
        _early_completions = {},
        _defaults = {},
        _closed = false,
        _fatal_error = nil,
        on_callback_error = options.on_callback_error or default_reporter,
    }, Session)

    for key, value in pairs(options) do
        if key ~= "cookies" and key ~= "max_total_connections" and
            key ~= "max_host_connections" and key ~= "on_callback_error" and
            key ~= "require_async_dns" then
            self._defaults[key] = value
        end
    end

    local driver_options = {
        cookies = options.cookies ~= false,
        max_total_connections = options.max_total_connections,
        max_host_connections = options.max_host_connections,
    }

    self._driver = Driver.new(
        driver_options,
        function(completion)
            self:_complete(completion)
        end,
        function(err)
            self:_fatal(err)
        end,
        function(err)
            self:_report(err)
        end
    )
    self._gc_guard = new_gc_guard(self._driver)

    return self
end

function Session:_report(message)
    local ok, err = pcall(self.on_callback_error, message)
    if not ok then
        default_reporter(err)
    end
end

function Session:_fatal(message)
    if not self._fatal_error then
        self._fatal_error = Error.new({
            kind = "internal",
            message = tostring(message),
            phase = "event",
        })
        self._closed = true
    end
end

function Session:_build_response(completion)
    local parsed, parse_err = Headers.parse(completion.headers_raw or "")
    if not parsed then
        return nil, Error.new({
            kind = "protocol",
            message = parse_err,
            url = completion.url,
            phase = "headers",
        })
    end

    return Response.new({
        status_code = completion.status_code or parsed.status_code,
        reason = parsed.reason,
        ok = (completion.status_code or parsed.status_code) < 400,
        http_version = completion.http_version or parsed.http_version,
        url = completion.url,
        headers = parsed.headers,
        body = completion.body or "",
        history = parsed.history,
        trailers = parsed.trailers,
        metrics = completion.metrics or {},
    })
end

function Session:_complete(completion)
    local transfer_id = completion.transfer_id
    local task = transfer_id and self._active[transfer_id] or completion.task

    if not task then
        if transfer_id then
            self._early_completions[transfer_id] = completion
        end
        return
    end

    if transfer_id then
        self._active[transfer_id] = nil
    end

    local response
    local err
    if completion.synthetic_error then
        err = completion.synthetic_error
    elseif self._fatal_error then
        err = self._fatal_error
    elseif completion.cancelled or completion.curl_code ~= 0 or completion.buffer_error then
        err = request_error(completion)
    else
        response, err = self:_build_response(completion)
    end

    task:_resolve(response, err)
end

function Session:request(method, url, options, callback)
    if type(options) == "function" and callback == nil then
        callback = options
        options = nil
    end
    if self._closed then
        error("session is closed", 2)
    end

    local merged = Options.merge(self._defaults, options)
    local normalized = Options.normalize(method, url, merged)
    local task = Task.new(self, callback)

    task:_set_reporter(function(message)
        self:_report(message)
    end)

    local transfer, transfer_id_or_err, fatal_err = self._driver:add(normalized)
    if not transfer then
        self._driver:defer({
            task = task,
            synthetic_error = Error.new({
                kind = "internal",
                message = tostring(transfer_id_or_err),
                url = normalized.url,
                phase = "setup",
            }),
        })
        if fatal_err then
            self._driver:_fatal(fatal_err)
        end
        return task
    end

    local transfer_id = transfer_id_or_err
    self._active[transfer_id] = task
    task._transfer_id = transfer_id
    task._transfer = transfer

    local early = self._early_completions[transfer_id]
    if early then
        self._early_completions[transfer_id] = nil
        self:_complete(early)
    end
    if fatal_err then
        self._driver:_fatal(fatal_err)
    end
    return task
end

function Session:_cancel(task, reason)
    local transfer = task._transfer
    local transfer_id = task._transfer_id

    if not transfer or not transfer_id or not self._active[transfer_id] then
        return false
    end

    return self._driver:cancel(transfer, reason)
end

function Session:close(callback)
    if callback ~= nil and type(callback) ~= "function" then
        error("close callback must be a function", 2)
    end

    self._closed = true
    disarm_gc_guard(self._gc_guard)
    self._gc_guard = nil
    self._driver:close(callback)
end

function Session:is_closed()
    return self._closed
end

for _, method in ipairs({ "get", "head", "post", "put", "patch", "delete" }) do
    Session[method] = function(self, url, options, callback)
        return self:request(string.upper(method), url, options, callback)
    end
end

return Session
