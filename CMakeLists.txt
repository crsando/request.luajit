cmake_minimum_required(VERSION 3.16)

project(request_luajit VERSION 0.1.0 LANGUAGES C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

option(REQUEST_ENABLE_SANITIZERS "Enable AddressSanitizer and UndefinedBehaviorSanitizer" OFF)
set(REQUEST_LUA_LIBDIR "" CACHE PATH "Lua native module installation directory")
set(REQUEST_LUA_DIR "" CACHE PATH "Lua source module installation directory")
set(LUA_INCDIR "" CACHE PATH "LuaJIT include directory supplied by LuaRocks")

find_package(PkgConfig QUIET)
find_package(Threads REQUIRED)

if(PkgConfig_FOUND)
    pkg_check_modules(
        LIBCURL
        QUIET
        IMPORTED_TARGET
        libcurl>=7.68
    )
    pkg_check_modules(
        LUAJIT
        QUIET
        IMPORTED_TARGET
        luajit>=2.1
    )
endif()

if(TARGET PkgConfig::LIBCURL)
    set(REQUEST_LIBCURL_TARGET PkgConfig::LIBCURL)
else()
    find_package(CURL 7.68 REQUIRED)
    set(REQUEST_LIBCURL_TARGET CURL::libcurl)
endif()

include(CheckCSourceCompiles)
include(CMakePushCheckState)
cmake_push_check_state(RESET)
set(CMAKE_REQUIRED_LIBRARIES "${REQUEST_LIBCURL_TARGET}")
check_c_source_compiles(
    [=[
        #include <curl/curl.h>

        int main(void)
        {
            CURLM *multi = curl_multi_init();
            int running = 0;

            if (multi == NULL) {
                return 1;
            }
            if (curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION, NULL) != CURLM_OK ||
                curl_multi_setopt(multi, CURLMOPT_TIMERFUNCTION, NULL) != CURLM_OK) {
                curl_multi_cleanup(multi);
                return 1;
            }
            curl_multi_socket_action(multi, CURL_SOCKET_TIMEOUT, 0, &running);
            curl_multi_cleanup(multi);
            return 0;
        }
    ]=]
    REQUEST_HAS_LIBCURL_MULTI_SOCKET_API
)
cmake_pop_check_state()

if(NOT REQUEST_HAS_LIBCURL_MULTI_SOCKET_API)
    message(
        FATAL_ERROR
        "The detected libcurl development package does not provide the required multi socket API"
    )
endif()

if(NOT TARGET PkgConfig::LUAJIT)
    find_path(
        LUAJIT_INCLUDE_DIR
        NAMES luajit.h
        PATH_SUFFIXES luajit-2.1
        HINTS "${LUA_INCDIR}"
        REQUIRED
    )
endif()

add_library(
    request_core
    MODULE
    src/request_buffer.c
    src/request_core.c
)

target_include_directories(request_core PRIVATE src)
target_link_libraries(request_core PRIVATE "${REQUEST_LIBCURL_TARGET}" Threads::Threads)

if(LUA_INCDIR)
    target_include_directories(request_core PRIVATE "${LUA_INCDIR}")
elseif(TARGET PkgConfig::LUAJIT)
    target_include_directories(request_core PRIVATE "${LUAJIT_INCLUDE_DIRS}")
else()
    target_include_directories(request_core PRIVATE "${LUAJIT_INCLUDE_DIR}")
endif()

if(APPLE)
    target_link_options(request_core PRIVATE "LINKER:-undefined,dynamic_lookup")
endif()

target_compile_options(
    request_core
    PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Werror
)

if(REQUEST_ENABLE_SANITIZERS AND CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(
        request_core
        PRIVATE
        -fsanitize=address,undefined
        -fno-omit-frame-pointer
    )
    target_link_options(request_core PRIVATE -fsanitize=address,undefined)
endif()

set_target_properties(
    request_core
    PROPERTIES
    PREFIX ""
    OUTPUT_NAME "core"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/request"
    SKIP_BUILD_RPATH TRUE
)

include(GNUInstallDirs)

if(REQUEST_LUA_LIBDIR)
    set(REQUEST_NATIVE_DESTINATION "${REQUEST_LUA_LIBDIR}/request")
else()
    # Not CMAKE_INSTALL_LIBDIR: on Debian/Ubuntu with prefix /usr that becomes
    # lib/<multiarch>, which is not on LuaJIT's default package.cpath.
    set(REQUEST_NATIVE_DESTINATION "lib/lua/5.1/request")
endif()

if(REQUEST_LUA_DIR)
    set(REQUEST_LUA_DESTINATION "${REQUEST_LUA_DIR}")
else()
    set(REQUEST_LUA_DESTINATION "share/lua/5.1")
endif()

install(TARGETS request_core LIBRARY DESTINATION "${REQUEST_NATIVE_DESTINATION}")
install(FILES lua/request.lua DESTINATION "${REQUEST_LUA_DESTINATION}")
install(
    FILES
        lua/request/driver.lua
        lua/request/error.lua
        lua/request/headers.lua
        lua/request/options.lua
        lua/request/response.lua
        lua/request/session.lua
        lua/request/task.lua
    DESTINATION "${REQUEST_LUA_DESTINATION}/request"
)
