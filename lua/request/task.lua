local Task = {}
Task.__index = Task
local next_task_id = 0

function Task.new(session, callback)
    if callback ~= nil and type(callback) ~= "function" then
        error("callback must be a function", 2)
    end

    next_task_id = next_task_id + 1

    return setmetatable({
        _id = next_task_id,
        _session = session,
        _callback = callback,
        _consumer = callback and "callback" or nil,
        _state = "active",
        _settled = false,
        _cancel_requested = false,
    }, Task)
end

function Task:state()
    return self._state
end

function Task:cancel(reason)
    if self._settled or self._cancel_requested then
        return false
    end
    if reason ~= nil and type(reason) ~= "string" then
        error("cancel reason must be a string", 2)
    end
    if reason and reason:find("\0", 1, true) then
        error("cancel reason must not contain NUL", 2)
    end

    if not self._session:_cancel(self, reason) then
        return false
    end

    self._cancel_requested = true
    self._state = "cancelled"
    return true
end

function Task:await()
    local thread = coroutine.running()

    if not thread then
        error("await() must be called from a yieldable coroutine", 2)
    end
    if self._consumer then
        error("task result already has a consumer", 2)
    end

    self._consumer = "await"
    if self._settled then
        return self._response, self._error
    end

    self._waiter = thread
    return coroutine.yield()
end

function Task:_resolve(response, err)
    if self._settled then
        return
    end

    self._settled = true
    self._response = response
    self._error = err
    if err and err.kind == "cancelled" then
        self._state = "cancelled"
    elseif self._state ~= "cancelled" then
        self._state = "done"
    end

    local callback = self._callback
    local waiter = self._waiter
    local reporter = self._report_error

    self._callback = nil
    self._waiter = nil
    self._report_error = nil
    self._transfer = nil
    self._session = nil

    if callback then
        local ok, callback_err = xpcall(function()
            callback(response, err)
        end, debug.traceback)

        if not ok then
            reporter(callback_err)
        end
    elseif waiter then
        local status = coroutine.status(waiter)
        if status ~= "suspended" then
            reporter(string.format(
                "task %d cannot resume coroutine in %s state",
                self._id,
                status
            ))
            return
        end

        local ok, resume_err = coroutine.resume(waiter, response, err)
        if not ok then
            reporter(string.format(
                "task %d coroutine failed: %s\n%s",
                self._id,
                tostring(resume_err),
                debug.traceback(waiter)
            ))
        end
    end
end

function Task:_set_reporter(reporter)
    self._report_error = reporter
end

return Task
