local methods = {}

local function normalize_name(name)
    if type(name) ~= "string" then
        return nil
    end

    return string.lower(name)
end

function methods:get(name, default)
    local values = self._map[normalize_name(name)]

    if not values or values[1] == nil then
        return default
    end

    return values[1]
end

function methods:get_all(name)
    local values = self._map[normalize_name(name)]
    local result = {}

    if not values then
        return result
    end

    for index = 1, #values do
        result[index] = values[index]
    end

    return result
end


function methods:each()
    local index = 0

    return function()
        index = index + 1
        local item = self._list[index]
        if item then
            return item.name, item.value
        end
    end
end


local metatable = {
    __index = function(self, key)
        local method = methods[key]
        if method then
            return method
        end

        return methods.get(self, key)
    end,
}

local M = {}

function M.new(items)
    local headers = {
        _list = {},
        _map = {},
    }

    for index = 1, #(items or {}) do
        local item = items[index]
        local name = item.name
        local value = item.value
        local normalized = normalize_name(name)
        local values = headers._map[normalized]

        headers._list[#headers._list + 1] = {
            name = name,
            value = value,
        }

        if not values then
            values = {}
            headers._map[normalized] = values
        end
        values[#values + 1] = value
    end

    return setmetatable(headers, metatable)
end

local function trim(value)
    return (value:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
end

local function parse_status_line(line)
    local version, status, reason = line:match("^HTTP/(%S+)%s+(%d%d%d)%s*(.*)$")

    if not version then
        return nil
    end

    return {
        http_version = version,
        status_code = tonumber(status),
        reason = reason,
        items = {},
    }
end

function M.parse(raw)
    local blocks = {}
    local current

    for line in (raw .. "\n"):gmatch("(.-)\r?\n") do
        local status = parse_status_line(line)

        if status then
            if current then
                blocks[#blocks + 1] = current
            end
            current = status
        elseif line == "" then
            if current then
                blocks[#blocks + 1] = current
                current = nil
            end
        elseif current then
            if line:match("^[ \t]") then
                local previous = current.items[#current.items]
                if not previous then
                    return nil, "header continuation has no preceding field"
                end
                previous.value = previous.value .. " " .. trim(line)
            else
                local name, value = line:match("^([^:]+):(.*)$")
                if not name then
                    return nil, "malformed response header: " .. line
                end
                current.items[#current.items + 1] = {
                    name = trim(name),
                    value = trim(value),
                }
            end
        else
            local name, value = line:match("^([^:]+):(.*)$")
            if name and #blocks > 0 then
                local trailer = blocks[#blocks]
                trailer.trailers = trailer.trailers or {}
                trailer.trailers[#trailer.trailers + 1] = {
                    name = trim(name),
                    value = trim(value),
                }
            elseif line ~= "" then
                return nil, "response header does not start with an HTTP status line"
            end
        end
    end

    if current then
        blocks[#blocks + 1] = current
    end
    if #blocks == 0 then
        return nil, "response did not contain an HTTP status line"
    end

    local final_index
    for index = #blocks, 1, -1 do
        local block = blocks[index]
        if block.status_code >= 200 then
            final_index = index
            break
        end
    end

    if not final_index then
        return nil, "response did not contain a final HTTP status"
    end

    local final = blocks[final_index]
    local history = {}
    for index = 1, final_index - 1 do
        local block = blocks[index]
        history[#history + 1] = {
            status_code = block.status_code,
            reason = block.reason,
            http_version = block.http_version,
            headers = M.new(block.items),
        }
    end

    return {
        status_code = final.status_code,
        reason = final.reason,
        http_version = final.http_version,
        headers = M.new(final.items),
        trailers = M.new(final.trailers or {}),
        history = history,
    }
end

return M
