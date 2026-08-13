local Error = {}
Error.__index = Error

function Error:__tostring()
    local prefix = self.kind or "request"

    if self.url then
        return string.format("%s error for %s: %s", prefix, self.url, self.message)
    end

    return string.format("%s error: %s", prefix, self.message)
end

local M = {}

function M.new(fields)
    return setmetatable(fields, Error)
end

return M

