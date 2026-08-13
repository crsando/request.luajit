local bit = require("bit")
local uv = require("luv")
local core = require("request.core")

local Driver = {}
Driver.__index = Driver
local active_drivers = {}

if type(uv.new_poll) ~= "function" or type(uv.new_timer) ~= "function" then
    error("luv with uv_poll and uv_timer support is required")
end

local function weak_reference(value)
    return setmetatable({ value }, {
        __mode = "v",
    })
end

local function defer_callback(callback)
    local timer = assert(uv.new_timer())

    timer:start(0, 0, function()
        timer:stop()
        timer:close(function()
            callback(nil)
        end)
    end)
end

local function event_string(action)
    if action == core.POLL_IN then
        return "r"
    elseif action == core.POLL_OUT then
        return "w"
    elseif action == core.POLL_INOUT then
        return "rw"
    end

    return nil
end

function Driver.new(options, on_completion, on_fatal, on_callback_error)
    local self = setmetatable({
        polls = {},
        closing_handles = {},
        completions = {},
        timer_generation = 0,
        poll_generation = 0,
        dispatch_scheduled = false,
        closing = false,
        closed = false,
        close_error = nil,
        pending_transfers = 0,
        pending_transfer_ids = {},
        on_completion = on_completion,
        on_fatal = on_fatal,
        on_callback_error = on_callback_error,
    }, Driver)

    self.manager = core.new(
        function(socket, action)
            self:_on_socket(socket, action)
        end,
        function(timeout_ms)
            self:_on_timer(timeout_ms)
        end,
        options
    )

    return self
end

function Driver:_retain()
    active_drivers[self] = true
end

function Driver:_release_if_idle()
    if self.pending_transfers == 0 and #self.completions == 0 and
        not self.dispatch_scheduled and not self.closing then
        active_drivers[self] = nil
    end
end

function Driver:_ensure_curl_timer()
    if not self.curl_timer then
        self.curl_timer = assert(uv.new_timer())
        self.curl_timer:unref()
    end

    return self.curl_timer
end

function Driver:_ensure_dispatch_timer()
    if not self.dispatch_timer then
        self.dispatch_timer = assert(uv.new_timer())
        self.dispatch_timer:unref()
    end

    return self.dispatch_timer
end

function Driver:_close_handle(handle, on_closed)
    if not handle or handle:is_closing() then
        return
    end

    self.closing_handles[handle] = true
    handle:close(function()
        self.closing_handles[handle] = nil
        if on_closed then
            on_closed()
        end
        self:_maybe_finish_close()
    end)
end

function Driver:_remove_poll(socket)
    local record = self.polls[socket]

    if not record then
        return
    end

    self.polls[socket] = nil
    record.handle:stop()
    self:_close_handle(record.handle)
end

function Driver:_on_socket(socket, action)
    if action == core.POLL_REMOVE then
        self:_remove_poll(socket)
        return
    end

    local events = event_string(action)
    if not events then
        error("unsupported libcurl poll action: " .. tostring(action))
    end

    local record = self.polls[socket]
    if not record then
        local handle, err = uv.new_poll(socket)
        if not handle then
            error(err)
        end

        self.poll_generation = self.poll_generation + 1
        record = {
            handle = handle,
            generation = self.poll_generation,
        }
        self.polls[socket] = record
    end

    local generation = record.generation
    local ok, err = record.handle:start(events, function(poll_err, observed)
        local current = self.polls[socket]
        if not current or current ~= record or current.generation ~= generation then
            return
        end

        local mask = 0
        if poll_err then
            mask = core.CSELECT_ERR
        else
            if observed and observed:find("r", 1, true) then
                mask = bit.bor(mask, core.CSELECT_IN)
            end
            if observed and observed:find("w", 1, true) then
                mask = bit.bor(mask, core.CSELECT_OUT)
            end
        end

        self:_socket_action(socket, mask)
    end)

    if not ok then
        self:_remove_poll(socket)
        error(err)
    end
end

function Driver:_on_timer(timeout_ms)
    if self.closing then
        return
    end

    self.timer_generation = self.timer_generation + 1
    local generation = self.timer_generation

    if timeout_ms < 0 then
        if self.curl_timer then
            self.curl_timer:stop()
            self.curl_timer:unref()
        end
        return
    end

    local timer = self:_ensure_curl_timer()
    local owner = weak_reference(self)
    timer:stop()
    timer:ref()
    local ok, err = timer:start(math.max(0, timeout_ms), 0, function()
        local driver = owner[1]
        if not driver or generation ~= driver.timer_generation or driver.closing then
            return
        end
        driver:_timeout_action()

        if driver.curl_timer and generation == driver.timer_generation and
            not driver.closing then
            driver.curl_timer:stop()
            driver.curl_timer:unref()
        end
    end)
    if not ok then
        timer:stop()
        timer:unref()
        error(err)
    end
end

function Driver:_queue_many(completions)
    for index = 1, #(completions or {}) do
        local completion = completions[index]
        local transfer_id = completion.transfer_id
        if not transfer_id or self.pending_transfer_ids[transfer_id] then
            if transfer_id then
                self.pending_transfer_ids[transfer_id] = nil
                self.pending_transfers = self.pending_transfers - 1
            end
            self.completions[#self.completions + 1] = completion
        end
    end

    if #self.completions > 0 then
        self:_retain()
        self:_schedule_dispatch()
    else
        if not self.closing and self.dispatch_timer then
            self.dispatch_timer:stop()
            self.dispatch_timer:unref()
        end

        if self.closing then
            self:_maybe_finish_close()
        else
            self:_release_if_idle()
        end
    end
end

function Driver:defer(item)
    self:_queue_many({ item })
end

function Driver:_schedule_dispatch()
    if self.dispatch_scheduled or self.closed then
        return
    end

    local timer = self:_ensure_dispatch_timer()
    local owner = weak_reference(self)
    timer:ref()
    self.dispatch_scheduled = true
    local ok, err = timer:start(0, 0, function()
        local driver = owner[1]
        if not driver then
            return
        end

        driver.dispatch_scheduled = false
        driver:_dispatch()
    end)
    if not ok then
        self.dispatch_scheduled = false
        self:_fatal(err)
    end
end

function Driver:_dispatch()
    local completion = table.remove(self.completions, 1)

    if completion then
        self.on_completion(completion)
    end

    if #self.completions > 0 then
        self:_schedule_dispatch()
    elseif not self.closing and self.dispatch_timer then
        self.dispatch_timer:stop()
        self.dispatch_timer:unref()
        self:_release_if_idle()
    else
        self:_maybe_finish_close()
    end
end

function Driver:_action_result(completions, err)
    if not completions then
        self:_fatal(err)
        return
    end

    self:_queue_many(completions)
    if err then
        self:_fatal(err)
    end
end

function Driver:_socket_action(socket, mask)
    if self.closing or not self.manager then
        return
    end

    self:_action_result(self.manager:socket_action(socket, mask))
end

function Driver:_timeout_action()
    if self.closing or not self.manager then
        return
    end

    self:_action_result(self.manager:timeout_action())
end

function Driver:add(options)
    if self.closing or not self.manager then
        return nil, "session is closed"
    end

    local transfer, transfer_id_or_err, needs_kick_or_fatal, fatal_err =
        self.manager:add(options)
    if transfer then
        self.pending_transfers = self.pending_transfers + 1
        self.pending_transfer_ids[transfer_id_or_err] = true
        self:_retain()
        if needs_kick_or_fatal and not fatal_err then
            local ok, err = pcall(self._on_timer, self, 0)
            if not ok then
                fatal_err = err
            end
        end
    elseif needs_kick_or_fatal then
        fatal_err = transfer_id_or_err
    end

    return transfer, transfer_id_or_err, fatal_err
end

function Driver:cancel(transfer, reason)
    if self.closing or not self.manager then
        return false
    end

    local completion, err = self.manager:cancel(transfer, reason)
    if completion then
        self:defer(completion)
    end
    if err then
        self:_fatal(err)
        return completion ~= nil
    end
    return completion ~= nil
end

function Driver:_fatal(err)
    if self.closed then
        return
    end

    self.on_fatal(tostring(err or "internal event driver error"))
    self:close()
end

function Driver:abandon()
    if self.closed or self.closing then
        return
    end

    self.closing = true
    self.closed = true
    self.completions = {}
    self.pending_transfers = 0
    self.pending_transfer_ids = {}
    active_drivers[self] = nil

    if self.manager then
        pcall(function()
            self.manager:close()
        end)
        self.manager = nil
    end

    for socket in pairs(self.polls) do
        local record = self.polls[socket]
        self.polls[socket] = nil
        pcall(function()
            record.handle:stop()
        end)
        if not record.handle:is_closing() then
            record.handle:close()
        end
    end

    for _, name in ipairs({ "curl_timer", "dispatch_timer" }) do
        local handle = self[name]
        self[name] = nil
        if handle then
            pcall(function()
                handle:stop()
            end)
            if not handle:is_closing() then
                handle:close()
            end
        end
    end
end

function Driver:close(callback)
    if self.closed then
        if callback then
            defer_callback(function()
                local ok, callback_err = xpcall(function()
                    callback(self.close_error)
                end, debug.traceback)
                if not ok then
                    self.on_callback_error(callback_err)
                end
            end)
        end
        return
    end
    if self.closing then
        if callback then
            self.close_callbacks[#self.close_callbacks + 1] = callback
        end
        return
    end

    self.closing = true
    self.close_callbacks = callback and { callback } or {}
    self.timer_generation = self.timer_generation + 1

    local completions = {}
    if self.manager then
        local manager_completions, err = self.manager:close()
        self.manager = nil
        if manager_completions then
            completions = manager_completions
        end
        if err then
            self.close_error = tostring(err)
            self.on_fatal(tostring(err))
        end
    end

    for socket in pairs(self.polls) do
        self:_remove_poll(socket)
    end

    if self.curl_timer then
        local timer = self.curl_timer
        self.curl_timer = nil
        timer:stop()
        self:_close_handle(timer)
    end

    self:_queue_many(completions)
end

function Driver:_maybe_finish_close()
    if not self.closing or self.closed or #self.completions > 0 or self.dispatch_scheduled then
        return
    end
    if next(self.polls) or next(self.closing_handles) or self.curl_timer then
        return
    end
    local callbacks = self.close_callbacks
    local function finish()
        self.closed = true
        active_drivers[self] = nil
        for index = 1, #callbacks do
            local ok, err = xpcall(function()
                callbacks[index](self.close_error)
            end, debug.traceback)
            if not ok then
                self.on_callback_error(err)
            end
        end
    end

    if self.dispatch_timer then
        local timer = self.dispatch_timer
        self.dispatch_timer = nil
        timer:stop()
        timer:close(finish)
    elseif #callbacks > 0 then
        defer_callback(finish)
    else
        finish()
    end
end

return Driver
