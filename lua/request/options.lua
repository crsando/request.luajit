local M = {}
local MAX_C_LONG = 2147483647
local MAX_BUFFER_SIZE = 4294967295
local request_option_names = {
    allow_redirects = true,
    auth = true,
    cert = true,
    data = true,
    headers = true,
    max_body_bytes = true,
    max_header_bytes = true,
    max_redirects = true,
    params = true,
    proxy = true,
    timeout = true,
    verify = true,
}

local function argument_error(level, message)
    error(message, level + 1)
end

local function check_string(value, name, level)
    if type(value) ~= "string" then
        argument_error(level + 1, name .. " must be a string")
    end

    return value
end

local function check_c_string(value, name, level)
    check_string(value, name, level + 1)
    if value:find("\0", 1, true) then
        argument_error(level + 1, name .. " must not contain NUL")
    end

    return value
end

local function check_http_token(value, name, level)
    check_c_string(value, name, level + 1)
    if value == "" then
        argument_error(level + 1, name .. " must be a valid HTTP token")
    end

    for index = 1, #value do
        local byte = value:byte(index)
        local alphanumeric =
            (byte >= 48 and byte <= 57) or
            (byte >= 65 and byte <= 90) or
            (byte >= 97 and byte <= 122)
        local punctuation = byte == 33 or byte == 35 or byte == 36 or byte == 37 or
            byte == 38 or byte == 39 or byte == 42 or byte == 43 or byte == 45 or
            byte == 46 or byte == 94 or byte == 95 or byte == 96 or byte == 124 or
            byte == 126

        if not alphanumeric and not punctuation then
            argument_error(level + 1, name .. " must be a valid HTTP token")
        end
    end

    return value
end

local function scalar_string(value, name, level)
    local value_type = type(value)

    if value_type == "string" or value_type == "number" then
        return tostring(value)
    end
    if value_type == "boolean" then
        return value and "true" or "false"
    end

    argument_error(level + 1, name .. " must contain string, number, or boolean values")
end

local function percent_encode(value)
    return (value:gsub("([^A-Za-z0-9_.~-])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function is_array(value)
    return type(value) == "table" and value[1] ~= nil
end

local function append_pair(result, name, value, level)
    name = scalar_string(name, "parameter name", level + 1)

    if type(value) == "table" then
        for index = 1, #value do
            append_pair(result, name, value[index], level + 1)
        end
        return
    end

    result[#result + 1] = percent_encode(name) .. "=" .. percent_encode(
        scalar_string(value, "parameter value", level + 1)
    )
end

local function encode_pairs(values, level)
    local result = {}

    if is_array(values) then
        for index = 1, #values do
            local pair = values[index]
            if type(pair) ~= "table" or pair[1] == nil or pair[2] == nil then
                argument_error(level + 1, "ordered parameters must contain { name, value } pairs")
            end
            append_pair(result, pair[1], pair[2], level + 1)
        end
    else
        for name, value in pairs(values) do
            append_pair(result, name, value, level + 1)
        end
    end

    return table.concat(result, "&")
end

local function append_query(url, params, level)
    if params == nil then
        return url
    end
    if type(params) ~= "table" then
        argument_error(level + 1, "params must be a table")
    end

    local encoded = encode_pairs(params, level + 1)
    if encoded == "" then
        return url
    end

    local base, fragment = url:match("^(.-)(#.*)$")
    if not base then
        base = url
        fragment = ""
    end

    local separator = base:find("?", 1, true) and "&" or "?"
    return base .. separator .. encoded .. fragment
end

local function validate_header_part(value, name, level)
    check_c_string(value, name, level + 1)
    if value:find("[\r\n]") then
        argument_error(level + 1, name .. " must not contain CR or LF")
    end
end

local function add_header(result, name, value, level)
    check_http_token(name, "header name", level + 1)
    validate_header_part(value, "header value", level + 1)
    result[#result + 1] = name .. ": " .. value
end

local function normalize_headers(headers, level)
    local result = {}

    if headers == nil then
        return result
    end
    if type(headers) ~= "table" then
        argument_error(level + 1, "headers must be a table")
    end

    if is_array(headers) then
        for index = 1, #headers do
            local item = headers[index]
            if type(item) ~= "table" then
                argument_error(level + 1, "ordered headers must contain tables")
            end

            local name = item.name or item[1]
            local value = item.value or item[2]
            add_header(result, name, value, level + 1)
        end
        return result
    end

    for name, value in pairs(headers) do
        if type(value) == "table" then
            for index = 1, #value do
                add_header(result, name, value[index], level + 1)
            end
        else
            add_header(result, name, value, level + 1)
        end
    end

    return result
end

local function merge_map(defaults, overrides, normalize_key)
    local result = {}
    local keys = {}

    if type(defaults) == "table" then
        for key, value in pairs(defaults) do
            result[key] = value
            keys[normalize_key and normalize_key(key) or key] = key
        end
    end
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            local normalized = normalize_key and normalize_key(key) or key
            local previous = keys[normalized]
            if previous ~= nil and previous ~= key then
                result[previous] = nil
            end
            result[key] = value
            keys[normalized] = key
        end
    end

    return result
end

function M.merge(defaults, options)
    local result = {}

    if options ~= nil and type(options) ~= "table" then
        argument_error(2, "options must be a table")
    end

    for key, value in pairs(defaults or {}) do
        result[key] = value
    end
    for key, value in pairs(options or {}) do
        result[key] = value
    end

    if defaults and defaults.headers and options and options.headers and
        not is_array(defaults.headers) and not is_array(options.headers) then
        result.headers = merge_map(defaults.headers, options.headers, string.lower)
    end

    if defaults and defaults.params and options and options.params and
        not is_array(defaults.params) and not is_array(options.params) then
        result.params = merge_map(defaults.params, options.params)
    end

    return result
end

function M.is_request_option(name)
    return request_option_names[name] == true
end

local function validate_option_names(options, level)
    for name in pairs(options) do
        if not request_option_names[name] then
            argument_error(level + 1, "unknown request option: " .. tostring(name))
        end
    end
end

local function milliseconds(value, name, level)
    if type(value) ~= "number" or value < 0 or value ~= value or
        value * 1000 > MAX_C_LONG then
        argument_error(level + 1, name .. " must be a non-negative number")
    end

    return math.ceil(value * 1000)
end

local function non_negative_integer(value, name, level, maximum)
    if type(value) ~= "number" or value ~= value or value == math.huge or
        value == -math.huge or value < 0 or value ~= math.floor(value) or
        (maximum and value > maximum) then
        argument_error(level + 1, name .. " must be a non-negative integer")
    end

    return value
end

local function normalize_timeout(target, timeout, level)
    if timeout == nil then
        return
    end

    if type(timeout) == "number" then
        target.timeout_ms = milliseconds(timeout, "timeout", level + 1)
        return
    end
    if type(timeout) ~= "table" then
        argument_error(level + 1, "timeout must be a number or table")
    end

    if timeout.connect ~= nil then
        target.connect_timeout_ms = milliseconds(
            timeout.connect,
            "timeout.connect",
            level + 1
        )
    end
    if timeout.total ~= nil then
        target.timeout_ms = milliseconds(timeout.total, "timeout.total", level + 1)
    end
end

local function normalize_auth(target, auth, level)
    if auth == nil then
        return
    end
    if type(auth) ~= "table" then
        argument_error(level + 1, "auth must be { username, password }")
    end

    target.username = check_c_string(auth.username or auth[1], "auth username", level + 1)
    target.password = check_c_string(auth.password or auth[2], "auth password", level + 1)
end

local function normalize_verify(target, verify, level)
    if verify == nil or verify == true then
        target.verify_tls = true
    elseif verify == false then
        target.verify_tls = false
    elseif type(verify) == "string" then
        target.verify_tls = true
        target.ca_file = check_c_string(verify, "CA bundle path", level + 1)
    else
        argument_error(level + 1, "verify must be true, false, or a CA bundle path")
    end
end

local function normalize_cert(target, cert, level)
    if cert == nil then
        return
    end
    if type(cert) == "string" then
        target.client_cert = check_c_string(cert, "client certificate", level + 1)
        return
    end
    if type(cert) ~= "table" then
        argument_error(level + 1, "cert must be a path or { cert, key }")
    end

    target.client_cert = check_c_string(
        cert.cert or cert[1],
        "client certificate",
        level + 1
    )
    target.client_key = check_c_string(cert.key or cert[2], "client key", level + 1)
end

local function normalize_body(target, data, headers, level)
    if data == nil then
        return headers
    end

    if type(data) == "string" then
        target.body = data
        return headers
    end
    if type(data) ~= "table" then
        argument_error(level + 1, "data must be a string or form table")
    end

    target.body = encode_pairs(data, level + 1)
    local has_content_type = false
    for index = 1, #headers do
        if string.lower(headers[index]):match("^content%-type%s*:") then
            has_content_type = true
            break
        end
    end
    if not has_content_type then
        headers[#headers + 1] = "content-type: application/x-www-form-urlencoded"
    end
    return headers
end

function M.normalize(method, url, options)
    local result = {}
    local headers

    check_http_token(method, "method", 2)
    check_c_string(url, "url", 2)
    if not url:lower():match("^https?://") then
        argument_error(2, "url must use http:// or https://")
    end
    if options ~= nil and type(options) ~= "table" then
        argument_error(2, "options must be a table")
    end
    options = options or {}
    validate_option_names(options, 2)

    result.method = string.upper(method)
    result.url = append_query(url, options.params, 2)
    headers = normalize_headers(options.headers, 2)
    result.headers = normalize_body(result, options.data, headers, 2)
    normalize_timeout(result, options.timeout, 2)
    normalize_auth(result, options.auth, 2)
    normalize_verify(result, options.verify, 2)
    normalize_cert(result, options.cert, 2)

    if options.allow_redirects == nil then
        result.follow_redirects = result.method == "HEAD" and 0 or 1
    else
        if type(options.allow_redirects) ~= "boolean" then
            argument_error(2, "allow_redirects must be a boolean")
        end
        result.follow_redirects = options.allow_redirects and 1 or 0
    end

    result.max_redirects = non_negative_integer(
        options.max_redirects or 10,
        "max_redirects",
        2,
        MAX_C_LONG
    )
    if options.max_body_bytes ~= nil then
        result.max_body_bytes = non_negative_integer(
            options.max_body_bytes,
            "max_body_bytes",
            2,
            MAX_BUFFER_SIZE
        )
    end
    if options.max_header_bytes ~= nil then
        result.max_header_bytes = non_negative_integer(
            options.max_header_bytes,
            "max_header_bytes",
            2,
            MAX_BUFFER_SIZE
        )
    end

    if options.proxy == false then
        result.proxy = ""
    elseif options.proxy ~= nil then
        result.proxy = check_c_string(options.proxy, "proxy", 2)
    end

    return result
end

return M
