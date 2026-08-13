local uv = require("luv")
local core = require("request.core")
local Session = require("request.session")

local M = {
    on_callback_error = function(message)
        io.stderr:write(tostring(message), "\n")
    end,
}

local default_session

local function get_default_session()
    if not default_session or default_session:is_closed() then
        default_session = Session.new({
            cookies = false,
            on_callback_error = function(message)
                M.on_callback_error(message)
            end,
        })
    end

    return default_session
end

function M.session(options)
    return Session.new(options)
end

function M.request(method, url, options, callback)
    return get_default_session():request(method, url, options, callback)
end

for _, method in ipairs({ "get", "head", "post", "put", "patch", "delete" }) do
    M[method] = function(url, options, callback)
        return get_default_session()[method](get_default_session(), url, options, callback)
    end
end

function M.close(callback)
    if callback ~= nil and type(callback) ~= "function" then
        error("close callback must be a function", 2)
    end

    local session = default_session
    default_session = nil
    if session then
        session:close(callback)
    elseif callback then
        local timer = assert(uv.new_timer())
        timer:start(0, 0, function()
            timer:stop()
            timer:close(function()
                local ok, err = xpcall(function()
                    callback(nil)
                end, debug.traceback)
                if not ok then
                    M.on_callback_error(err)
                end
            end)
        end)
    end
end

function M.capabilities()
    return core.capabilities()
end

return M
