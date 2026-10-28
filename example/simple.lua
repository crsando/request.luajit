local request = require("request")
local uv = require("luv")

local failed = false

request.get("https://www.baidu.com/", {
    timeout = {
        connect = 5,
        total = 15,
    },
}, function(response, err)
    if err then
        failed = true
        io.stderr:write(tostring(err), "\n")
        request.close()
        return
    end

    io.stdout:write(string.format(
        "HTTP %d %s\n",
        response.status_code,
        response.reason or ""
    ))
    io.stdout:write("URL: ", response.url, "\n")
    io.stdout:write("Content-Type: ", response.headers["content-type"] or "", "\n\n")
    io.stdout:write(response.body)
    if response.body:sub(-1) ~= "\n" then
        io.stdout:write("\n")
    end

    request.close()
end)

uv.run()

if failed then
    os.exit(1)
end
