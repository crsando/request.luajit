local Error = require("request.error")

local Response = {}
Response.__index = Response

function Response.new(fields)
    return setmetatable(fields, Response)
end

function Response:raise_for_status()
    if self.status_code >= 400 and self.status_code <= 599 then
        error(Error.new({
            kind = "http",
            code = self.status_code,
            message = string.format("HTTP %d %s", self.status_code, self.reason or ""),
            url = self.url,
            response = self,
        }), 2)
    end

    return self
end

return Response

