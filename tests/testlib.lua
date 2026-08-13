local M = {
    count = 0,
}

local function render(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

function M.equal(actual, expected, message)
    if actual ~= expected then
        error(string.format(
            "%s\nexpected: %s\nactual:   %s",
            message or "values differ",
            render(expected),
            render(actual)
        ), 2)
    end
end

function M.truthy(value, message)
    if not value then
        error(message or "expected a truthy value", 2)
    end
end

function M.matches(value, pattern, message)
    if type(value) ~= "string" or not value:match(pattern) then
        error(string.format(
            "%s\npattern: %s\nactual:  %s",
            message or "value does not match",
            pattern,
            render(value)
        ), 2)
    end
end

function M.raises(callback, pattern)
    local ok, err = pcall(callback)
    if ok then
        error("expected callback to raise", 2)
    end
    if pattern and not tostring(err):match(pattern) then
        error(string.format("error %q does not match %q", tostring(err), pattern), 2)
    end
end

function M.test(name, callback)
    io.write("[TEST] ", name, " ... ")
    io.flush()
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then
        io.write("FAIL\n", err, "\n")
        os.exit(1)
    end

    M.count = M.count + 1
    io.write("OK\n")
end

function M.done()
    print(string.format("%d tests passed", M.count))
end

return M
