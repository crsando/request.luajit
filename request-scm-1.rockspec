package = "request"
version = "scm-1"

source = {
    url = "git+https://github.com/twando/request.luajit.git",
}

description = {
    summary = "Asynchronous HTTP/HTTPS requests for LuaJIT using libcurl and luv",
    homepage = "https://github.com/twando/request.luajit",
    license = "MIT",
}

dependencies = {
    "lua >= 5.1, < 5.2",
    "luv >= 1.44",
}

build = {
    type = "cmake",
    variables = {
        CMAKE_BUILD_TYPE = "Release",
        LUA_INCDIR = "$(LUA_INCDIR)",
        REQUEST_LUA_LIBDIR = "$(LIBDIR)",
        REQUEST_LUA_DIR = "$(LUADIR)",
    },
}
