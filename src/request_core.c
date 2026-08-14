#include "request_buffer.h"

#include <curl/curl.h>
#include <curl/multi.h>
#include <lauxlib.h>
#include <lua.h>
#include <luajit.h>

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(LUAJIT_VERSION_NUM) || LUAJIT_VERSION_NUM < 20100
#error "request.core requires LuaJIT 2.1 or newer"
#endif

#define REQUEST_MANAGER_METATABLE "request.manager"
#define REQUEST_TRANSFER_METATABLE "request.transfer"
#define REQUEST_SOCKET_CALLBACK "socket_callback"
#define REQUEST_TIMER_CALLBACK "timer_callback"
#define REQUEST_DEFAULT_BODY_LIMIT (16U * 1024U * 1024U)
#define REQUEST_DEFAULT_HEADER_LIMIT (256U * 1024U)
#define REQUEST_ERROR_SIZE 512U

typedef struct request_multi request_multi_t;
typedef struct request_transfer request_transfer_t;

struct request_transfer {
    CURL *easy;
    request_multi_t *manager;
    request_transfer_t *previous;
    request_transfer_t *next;
    struct curl_slist *headers;
    request_buffer_t body;
    request_buffer_t header;
    char error[CURL_ERROR_SIZE];
    int self_ref;
    int body_ref;
    uint64_t id;
    bool active;
    bool finished;
};

struct request_multi {
    lua_State *lua;
    CURLM *multi;
    CURLSH *share;
    request_transfer_t *transfers;
    int callback_owner_index;
    int action_depth;
    uint64_t next_transfer_id;
    uint64_t timer_callback_count;
    char callback_error[REQUEST_ERROR_SIZE];
    bool closed;
};

static pthread_once_t request_curl_once = PTHREAD_ONCE_INIT;
static CURLcode request_curl_init_result = CURLE_FAILED_INIT;

static void request_manager_release(request_multi_t *manager);

static void request_curl_global_init(void)
{
    request_curl_init_result = curl_global_init(CURL_GLOBAL_DEFAULT);
}

static request_multi_t *request_check_manager(lua_State *lua, int index)
{
    return luaL_checkudata(lua, index, REQUEST_MANAGER_METATABLE);
}

static request_transfer_t *request_check_transfer(lua_State *lua, int index)
{
    return luaL_checkudata(lua, index, REQUEST_TRANSFER_METATABLE);
}

static void request_set_field_string(lua_State *lua, const char *name, const char *value)
{
    if (value == NULL) {
        return;
    }

    lua_pushstring(lua, value);
    lua_setfield(lua, -2, name);
}

static void request_set_field_number(lua_State *lua, const char *name, lua_Number value)
{
    lua_pushnumber(lua, value);
    lua_setfield(lua, -2, name);
}

static void request_set_field_boolean(lua_State *lua, const char *name, bool value)
{
    lua_pushboolean(lua, value);
    lua_setfield(lua, -2, name);
}

static void request_manager_callback_error(request_multi_t *manager, lua_State *lua)
{
    const char *message = lua_tostring(lua, -1);

    if (message == NULL) {
        message = "internal libcurl event callback failed";
    }

    snprintf(manager->callback_error, sizeof(manager->callback_error), "%s", message);
    lua_pop(lua, 1);
}

static int request_push_manager_callback(request_multi_t *manager, const char *name)
{
    lua_State *lua = manager->lua;

    if (manager->callback_owner_index <= 0 ||
        !lua_isuserdata(lua, manager->callback_owner_index)) {
        snprintf(
            manager->callback_error,
            sizeof(manager->callback_error),
            "libcurl callback ran outside a manager operation");
        return 0;
    }

    lua_getfenv(lua, manager->callback_owner_index);
    lua_getfield(lua, -1, name);
    lua_remove(lua, -2);
    if (!lua_isfunction(lua, -1)) {
        lua_pop(lua, 1);
        snprintf(
            manager->callback_error,
            sizeof(manager->callback_error),
            "manager callback %s is unavailable",
            name);
        return 0;
    }

    return 1;
}

static int request_socket_callback(
    CURL *easy,
    curl_socket_t socket,
    int action,
    void *user_data,
    void *socket_data)
{
    request_multi_t *manager = user_data;
    lua_State *lua = manager->lua;

    (void)easy;
    (void)socket_data;

    if (!request_push_manager_callback(manager, REQUEST_SOCKET_CALLBACK)) {
        return -1;
    }
    lua_pushnumber(lua, (lua_Number)socket);
    lua_pushinteger(lua, action);

    if (lua_pcall(lua, 2, 0, 0) != 0) {
        request_manager_callback_error(manager, lua);
        return -1;
    }

    return 0;
}

static int request_timer_callback(CURLM *multi, long timeout_ms, void *user_data)
{
    request_multi_t *manager = user_data;
    lua_State *lua = manager->lua;

    (void)multi;

    manager->timer_callback_count++;
    if (!request_push_manager_callback(manager, REQUEST_TIMER_CALLBACK)) {
        return -1;
    }
    lua_pushnumber(lua, (lua_Number)timeout_ms);

    if (lua_pcall(lua, 1, 0, 0) != 0) {
        request_manager_callback_error(manager, lua);
        return -1;
    }

    return 0;
}

static size_t request_write_callback(char *data, size_t size, size_t count, void *user_data)
{
    request_transfer_t *transfer = user_data;
    size_t bytes;

    if (size != 0 && count > SIZE_MAX / size) {
        transfer->body.error = REQUEST_BUFFER_OVERFLOW;
        return 0;
    }

    bytes = size * count;
    if (!request_buffer_append(&transfer->body, data, bytes)) {
        return 0;
    }

    return bytes;
}

static size_t request_header_callback(char *data, size_t size, size_t count, void *user_data)
{
    request_transfer_t *transfer = user_data;
    size_t bytes;

    if (size != 0 && count > SIZE_MAX / size) {
        transfer->header.error = REQUEST_BUFFER_OVERFLOW;
        return 0;
    }

    bytes = size * count;
    if (!request_buffer_append(&transfer->header, data, bytes)) {
        return 0;
    }

    return bytes;
}

static void request_manager_link_transfer(
    request_multi_t *manager,
    request_transfer_t *transfer)
{
    transfer->previous = NULL;
    transfer->next = manager->transfers;
    if (manager->transfers != NULL) {
        manager->transfers->previous = transfer;
    }
    manager->transfers = transfer;
}

static void request_manager_unlink_transfer(request_transfer_t *transfer)
{
    request_multi_t *manager = transfer->manager;

    if (transfer->previous != NULL) {
        transfer->previous->next = transfer->next;
    } else if (manager != NULL) {
        manager->transfers = transfer->next;
    }

    if (transfer->next != NULL) {
        transfer->next->previous = transfer->previous;
    }

    transfer->previous = NULL;
    transfer->next = NULL;
}

static void request_transfer_cleanup(lua_State *lua, request_transfer_t *transfer)
{
    if (transfer->active && transfer->manager != NULL && transfer->manager->multi != NULL) {
        curl_multi_remove_handle(transfer->manager->multi, transfer->easy);
        transfer->active = false;
    }

    if (transfer->manager != NULL &&
        (transfer->previous != NULL || transfer->next != NULL ||
         transfer->manager->transfers == transfer)) {
        request_manager_unlink_transfer(transfer);
    }

    if (transfer->easy != NULL) {
        curl_easy_cleanup(transfer->easy);
        transfer->easy = NULL;
    }

    curl_slist_free_all(transfer->headers);
    transfer->headers = NULL;

    if (transfer->body_ref != LUA_NOREF) {
        luaL_unref(lua, LUA_REGISTRYINDEX, transfer->body_ref);
        transfer->body_ref = LUA_NOREF;
    }

    request_buffer_free(&transfer->body);
    request_buffer_free(&transfer->header);
    transfer->manager = NULL;
    transfer->finished = true;
}

static const char *request_http_version_name(long version)
{
    switch (version) {
    case CURL_HTTP_VERSION_1_0:
        return "1.0";
    case CURL_HTTP_VERSION_1_1:
        return "1.1";
    case CURL_HTTP_VERSION_2_0:
        return "2";
#if LIBCURL_VERSION_NUM >= 0x074200
    case CURL_HTTP_VERSION_3:
        return "3";
#endif
    default:
        return "unknown";
    }
}

static const char *request_curl_code_name(CURLcode code)
{
    static const char *const names[] = {
        "CURLE_OK",
        "CURLE_UNSUPPORTED_PROTOCOL",
        "CURLE_FAILED_INIT",
        "CURLE_URL_MALFORMAT",
        "CURLE_NOT_BUILT_IN",
        "CURLE_COULDNT_RESOLVE_PROXY",
        "CURLE_COULDNT_RESOLVE_HOST",
        "CURLE_COULDNT_CONNECT",
        "CURLE_WEIRD_SERVER_REPLY",
        "CURLE_REMOTE_ACCESS_DENIED",
        "CURLE_FTP_ACCEPT_FAILED",
        "CURLE_FTP_WEIRD_PASS_REPLY",
        "CURLE_FTP_ACCEPT_TIMEOUT",
        "CURLE_FTP_WEIRD_PASV_REPLY",
        "CURLE_FTP_WEIRD_227_FORMAT",
        "CURLE_FTP_CANT_GET_HOST",
        "CURLE_HTTP2",
        "CURLE_FTP_COULDNT_SET_TYPE",
        "CURLE_PARTIAL_FILE",
        "CURLE_FTP_COULDNT_RETR_FILE",
        "CURLE_OBSOLETE20",
        "CURLE_QUOTE_ERROR",
        "CURLE_HTTP_RETURNED_ERROR",
        "CURLE_WRITE_ERROR",
        "CURLE_OBSOLETE24",
        "CURLE_UPLOAD_FAILED",
        "CURLE_READ_ERROR",
        "CURLE_OUT_OF_MEMORY",
        "CURLE_OPERATION_TIMEDOUT",
        "CURLE_OBSOLETE29",
        "CURLE_FTP_PORT_FAILED",
        "CURLE_FTP_COULDNT_USE_REST",
        "CURLE_OBSOLETE32",
        "CURLE_RANGE_ERROR",
        "CURLE_HTTP_POST_ERROR",
        "CURLE_SSL_CONNECT_ERROR",
        "CURLE_BAD_DOWNLOAD_RESUME",
        "CURLE_FILE_COULDNT_READ_FILE",
        "CURLE_LDAP_CANNOT_BIND",
        "CURLE_LDAP_SEARCH_FAILED",
        "CURLE_OBSOLETE40",
        "CURLE_FUNCTION_NOT_FOUND",
        "CURLE_ABORTED_BY_CALLBACK",
        "CURLE_BAD_FUNCTION_ARGUMENT",
        "CURLE_OBSOLETE44",
        "CURLE_INTERFACE_FAILED",
        "CURLE_OBSOLETE46",
        "CURLE_TOO_MANY_REDIRECTS",
        "CURLE_UNKNOWN_OPTION",
        "CURLE_SETOPT_OPTION_SYNTAX",
        "CURLE_OBSOLETE50",
        "CURLE_OBSOLETE51",
        "CURLE_GOT_NOTHING",
        "CURLE_SSL_ENGINE_NOTFOUND",
        "CURLE_SSL_ENGINE_SETFAILED",
        "CURLE_SEND_ERROR",
        "CURLE_RECV_ERROR",
        "CURLE_OBSOLETE57",
        "CURLE_SSL_CERTPROBLEM",
        "CURLE_SSL_CIPHER",
        "CURLE_PEER_FAILED_VERIFICATION",
        "CURLE_BAD_CONTENT_ENCODING",
        "CURLE_OBSOLETE62",
        "CURLE_FILESIZE_EXCEEDED",
        "CURLE_USE_SSL_FAILED",
        "CURLE_SEND_FAIL_REWIND",
        "CURLE_SSL_ENGINE_INITFAILED",
        "CURLE_LOGIN_DENIED",
        "CURLE_TFTP_NOTFOUND",
        "CURLE_TFTP_PERM",
        "CURLE_REMOTE_DISK_FULL",
        "CURLE_TFTP_ILLEGAL",
        "CURLE_TFTP_UNKNOWNID",
        "CURLE_REMOTE_FILE_EXISTS",
        "CURLE_TFTP_NOSUCHUSER",
        "CURLE_OBSOLETE75",
        "CURLE_OBSOLETE76",
        "CURLE_SSL_CACERT_BADFILE",
        "CURLE_REMOTE_FILE_NOT_FOUND",
        "CURLE_SSH",
        "CURLE_SSL_SHUTDOWN_FAILED",
        "CURLE_AGAIN",
        "CURLE_SSL_CRL_BADFILE",
        "CURLE_SSL_ISSUER_ERROR",
        "CURLE_FTP_PRET_FAILED",
        "CURLE_RTSP_CSEQ_ERROR",
        "CURLE_RTSP_SESSION_ERROR",
        "CURLE_FTP_BAD_FILE_LIST",
        "CURLE_CHUNK_FAILED",
        "CURLE_NO_CONNECTION_AVAILABLE",
        "CURLE_SSL_PINNEDPUBKEYNOTMATCH",
        "CURLE_SSL_INVALIDCERTSTATUS",
        "CURLE_HTTP2_STREAM",
        "CURLE_RECURSIVE_API_CALL",
        "CURLE_AUTH_ERROR",
        "CURLE_HTTP3",
        "CURLE_QUIC_CONNECT_ERROR",
        "CURLE_PROXY",
        "CURLE_SSL_CLIENTCERT",
        "CURLE_UNRECOVERABLE_POLL",
    };
    int value = (int)code;

    if (value < 0 || (size_t)value >= sizeof(names) / sizeof(names[0])) {
        return NULL;
    }

    return names[value];
}

static void request_push_metrics(lua_State *lua, CURL *easy)
{
    curl_off_t value = 0;
    long redirect_count = 0;

    lua_createtable(lua, 0, 8);

#define REQUEST_TIME_INFO(field, info) \
    do { \
        value = 0; \
        if (curl_easy_getinfo(easy, info, &value) == CURLE_OK) { \
            request_set_field_number(lua, field, (lua_Number)value / 1000000.0); \
        } \
    } while (0)

    REQUEST_TIME_INFO("total_time", CURLINFO_TOTAL_TIME_T);
    REQUEST_TIME_INFO("namelookup_time", CURLINFO_NAMELOOKUP_TIME_T);
    REQUEST_TIME_INFO("connect_time", CURLINFO_CONNECT_TIME_T);
    REQUEST_TIME_INFO("appconnect_time", CURLINFO_APPCONNECT_TIME_T);
    REQUEST_TIME_INFO("starttransfer_time", CURLINFO_STARTTRANSFER_TIME_T);
#undef REQUEST_TIME_INFO

    if (curl_easy_getinfo(easy, CURLINFO_REDIRECT_COUNT, &redirect_count) == CURLE_OK) {
        request_set_field_number(lua, "redirect_count", (lua_Number)redirect_count);
    }

    value = 0;
    if (curl_easy_getinfo(easy, CURLINFO_SIZE_UPLOAD_T, &value) == CURLE_OK) {
        request_set_field_number(lua, "uploaded_bytes", (lua_Number)value);
    }

    value = 0;
    if (curl_easy_getinfo(easy, CURLINFO_SIZE_DOWNLOAD_T, &value) == CURLE_OK) {
        request_set_field_number(lua, "downloaded_bytes", (lua_Number)value);
    }
}

static void request_push_buffer_error(
    lua_State *lua,
    const char *buffer_name,
    request_buffer_error_t error)
{
    const char *name;

    if (error == REQUEST_BUFFER_OK) {
        return;
    }

    switch (error) {
    case REQUEST_BUFFER_LIMIT:
        name = "limit";
        break;
    case REQUEST_BUFFER_OOM:
        name = "oom";
        break;
    case REQUEST_BUFFER_OVERFLOW:
        name = "overflow";
        break;
    default:
        name = "unknown";
        break;
    }

    request_set_field_string(lua, "buffer", buffer_name);
    request_set_field_string(lua, "buffer_error", name);
}

static void request_push_completion(
    lua_State *lua,
    request_transfer_t *transfer,
    CURLcode result,
    bool cancelled,
    const char *cancel_reason)
{
    CURL *easy = transfer->easy;
    char *effective_url = NULL;
    long status_code = 0;
    long http_version = CURL_HTTP_VERSION_NONE;
    const char *message;
    const char *code_name;
    char unknown_code[48];

    lua_createtable(lua, 0, 13);

    request_set_field_number(lua, "transfer_id", (lua_Number)transfer->id);
    request_set_field_number(lua, "curl_code", (lua_Number)result);
    code_name = request_curl_code_name(result);
    if (code_name == NULL) {
        snprintf(unknown_code, sizeof(unknown_code), "CURLE_UNKNOWN_%d", (int)result);
        code_name = unknown_code;
    }
    request_set_field_string(lua, "curl_name", code_name);
    request_set_field_boolean(lua, "cancelled", cancelled);
    request_set_field_string(lua, "cancel_reason", cancel_reason);

    message = transfer->error[0] != '\0' ? transfer->error : curl_easy_strerror(result);
    request_set_field_string(lua, "message", message);

    if (transfer->body.error != REQUEST_BUFFER_OK) {
        request_push_buffer_error(lua, "body", transfer->body.error);
    } else if (transfer->header.error != REQUEST_BUFFER_OK) {
        request_push_buffer_error(lua, "header", transfer->header.error);
    }

    lua_pushlstring(
        lua,
        transfer->body.data != NULL ? transfer->body.data : "",
        transfer->body.size);
    lua_setfield(lua, -2, "body");
    lua_pushlstring(
        lua,
        transfer->header.data != NULL ? transfer->header.data : "",
        transfer->header.size);
    lua_setfield(lua, -2, "headers_raw");

    if (curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status_code) == CURLE_OK) {
        request_set_field_number(lua, "status_code", (lua_Number)status_code);
    }

    if (curl_easy_getinfo(easy, CURLINFO_EFFECTIVE_URL, &effective_url) == CURLE_OK) {
        request_set_field_string(lua, "url", effective_url);
    }

    if (curl_easy_getinfo(easy, CURLINFO_HTTP_VERSION, &http_version) == CURLE_OK) {
        request_set_field_string(lua, "http_version", request_http_version_name(http_version));
    }

    request_push_metrics(lua, easy);
    lua_setfield(lua, -2, "metrics");
}

static CURLMcode request_complete_transfer(
    lua_State *lua,
    request_transfer_t *transfer,
    CURLcode result,
    bool cancelled,
    const char *cancel_reason)
{
    request_multi_t *manager = transfer->manager;
    CURLMcode multi_code = CURLM_OK;

    if (transfer->active) {
        multi_code = curl_multi_remove_handle(manager->multi, transfer->easy);
        transfer->active = false;
    }

    request_push_completion(lua, transfer, result, cancelled, cancel_reason);
    request_manager_unlink_transfer(transfer);
    request_transfer_cleanup(lua, transfer);

    luaL_unref(lua, LUA_REGISTRYINDEX, transfer->self_ref);
    transfer->self_ref = LUA_NOREF;
    return multi_code;
}

static int request_push_manager_error(lua_State *lua, request_multi_t *manager, CURLMcode code)
{
    lua_pushnil(lua);
    if (manager->callback_error[0] != '\0') {
        lua_pushstring(lua, manager->callback_error);
        manager->callback_error[0] = '\0';
    } else {
        lua_pushstring(lua, curl_multi_strerror(code));
    }
    return 2;
}

static int request_drain_messages(lua_State *lua, request_multi_t *manager)
{
    CURLMsg *message;
    int remaining = 0;
    int index = 1;

    lua_createtable(lua, 0, 0);
    while ((message = curl_multi_info_read(manager->multi, &remaining)) != NULL) {
        request_transfer_t *transfer = NULL;
        CURLcode info_code;
        CURLMcode multi_code;

        if (message->msg != CURLMSG_DONE) {
            continue;
        }

        info_code = curl_easy_getinfo(message->easy_handle, CURLINFO_PRIVATE, &transfer);
        if (info_code != CURLE_OK) {
            lua_pushfstring(
                lua,
                "failed to read CURLINFO_PRIVATE: %s",
                curl_easy_strerror(info_code));
            return 2;
        }
        if (transfer == NULL) {
            lua_pushstring(lua, "CURLINFO_PRIVATE did not contain a request transfer");
            return 2;
        }
        if (transfer->finished) {
            continue;
        }

        multi_code = request_complete_transfer(
            lua,
            transfer,
            message->data.result,
            false,
            NULL);
        lua_rawseti(lua, -2, index++);

        if (multi_code != CURLM_OK) {
            lua_pushstring(lua, curl_multi_strerror(multi_code));
            return 2;
        }
    }

    if (manager->callback_error[0] != '\0') {
        lua_pushstring(lua, manager->callback_error);
        manager->callback_error[0] = '\0';
        return 2;
    }

    return 1;
}

static size_t request_get_limit(
    lua_State *lua,
    int options_index,
    const char *name,
    size_t default_value)
{
    lua_Number value;

    lua_getfield(lua, options_index, name);
    if (lua_isnil(lua, -1)) {
        lua_pop(lua, 1);
        return default_value;
    }

    value = luaL_checknumber(lua, -1);
    lua_pop(lua, 1);
    if (value < 0 || value > (lua_Number)SIZE_MAX) {
        luaL_error(lua, "%s is outside the supported range", name);
    }

    return (size_t)value;
}

static CURLcode request_setopt_long(
    lua_State *lua,
    int options_index,
    CURL *easy,
    const char *name,
    CURLoption option)
{
    CURLcode code = CURLE_OK;

    lua_getfield(lua, options_index, name);
    if (!lua_isnil(lua, -1)) {
        code = curl_easy_setopt(easy, option, (long)lua_tonumber(lua, -1));
    }
    lua_pop(lua, 1);
    return code;
}

static CURLcode request_setopt_string(
    lua_State *lua,
    int options_index,
    CURL *easy,
    const char *name,
    CURLoption option)
{
    CURLcode code = CURLE_OK;

    lua_getfield(lua, options_index, name);
    if (lua_isstring(lua, -1)) {
        code = curl_easy_setopt(easy, option, lua_tostring(lua, -1));
    }
    lua_pop(lua, 1);
    return code;
}

static CURLcode request_configure_headers(
    lua_State *lua,
    int options_index,
    request_transfer_t *transfer)
{
    size_t length;
    size_t index;
    CURLcode code = CURLE_OK;

    lua_getfield(lua, options_index, "headers");
    if (lua_isnil(lua, -1)) {
        lua_pop(lua, 1);
        return CURLE_OK;
    }

    length = lua_objlen(lua, -1);
    for (index = 1; index <= length; index++) {
        struct curl_slist *headers;

        lua_rawgeti(lua, -1, (int)index);
        headers = curl_slist_append(transfer->headers, luaL_checkstring(lua, -1));
        lua_pop(lua, 1);
        if (headers == NULL) {
            code = CURLE_OUT_OF_MEMORY;
            break;
        }
        transfer->headers = headers;
    }
    lua_pop(lua, 1);

    if (code == CURLE_OK && transfer->headers != NULL) {
        code = curl_easy_setopt(transfer->easy, CURLOPT_HTTPHEADER, transfer->headers);
    }
    return code;
}

static CURLcode request_configure_body(
    lua_State *lua,
    int options_index,
    request_transfer_t *transfer)
{
    CURLcode code;
    const char *body;
    size_t body_size;

    lua_getfield(lua, options_index, "body");
    if (lua_isnil(lua, -1)) {
        lua_pop(lua, 1);
        return CURLE_OK;
    }

    body = luaL_checklstring(lua, -1, &body_size);
    code = curl_easy_setopt(transfer->easy, CURLOPT_POSTFIELDS, body);
    if (code == CURLE_OK) {
        code = curl_easy_setopt(
            transfer->easy,
            CURLOPT_POSTFIELDSIZE_LARGE,
            (curl_off_t)body_size);
    }

    if (code == CURLE_OK) {
        transfer->body_ref = luaL_ref(lua, LUA_REGISTRYINDEX);
    } else {
        lua_pop(lua, 1);
    }
    return code;
}

static CURLcode request_configure_transfer(
    lua_State *lua,
    int options_index,
    request_transfer_t *transfer)
{
    CURL *easy = transfer->easy;
    CURLcode code;
    const char *url;
    const char *method;

#define REQUEST_SETOPT(option, value) \
    do { \
        code = curl_easy_setopt(easy, option, value); \
        if (code != CURLE_OK) { \
            return code; \
        } \
    } while (0)

    lua_getfield(lua, options_index, "url");
    url = luaL_checkstring(lua, -1);
    REQUEST_SETOPT(CURLOPT_URL, url);
    lua_pop(lua, 1);

    REQUEST_SETOPT(CURLOPT_PRIVATE, transfer);
    REQUEST_SETOPT(CURLOPT_NOSIGNAL, 1L);
    REQUEST_SETOPT(CURLOPT_ERRORBUFFER, transfer->error);
    REQUEST_SETOPT(CURLOPT_WRITEFUNCTION, request_write_callback);
    REQUEST_SETOPT(CURLOPT_WRITEDATA, transfer);
    REQUEST_SETOPT(CURLOPT_HEADERFUNCTION, request_header_callback);
    REQUEST_SETOPT(CURLOPT_HEADERDATA, transfer);
    REQUEST_SETOPT(CURLOPT_ACCEPT_ENCODING, "");
    REQUEST_SETOPT(CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
    REQUEST_SETOPT(CURLOPT_SSL_VERIFYPEER, 1L);
    REQUEST_SETOPT(CURLOPT_SSL_VERIFYHOST, 2L);

#if LIBCURL_VERSION_NUM >= 0x075500
    if (curl_version_info(CURLVERSION_NOW)->version_num >= 0x075500) {
        REQUEST_SETOPT(CURLOPT_PROTOCOLS_STR, "http,https");
        REQUEST_SETOPT(CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    } else {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        REQUEST_SETOPT(CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
        REQUEST_SETOPT(CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
#pragma GCC diagnostic pop
    }
#else
    REQUEST_SETOPT(CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
    REQUEST_SETOPT(CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
#endif

    code = request_setopt_long(lua, options_index, easy, "connect_timeout_ms",
                               CURLOPT_CONNECTTIMEOUT_MS);
    if (code != CURLE_OK) {
        return code;
    }
    code = request_setopt_long(lua, options_index, easy, "timeout_ms", CURLOPT_TIMEOUT_MS);
    if (code != CURLE_OK) {
        return code;
    }
    code = request_setopt_long(lua, options_index, easy, "follow_redirects",
                               CURLOPT_FOLLOWLOCATION);
    if (code != CURLE_OK) {
        return code;
    }
    code = request_setopt_long(lua, options_index, easy, "max_redirects", CURLOPT_MAXREDIRS);
    if (code != CURLE_OK) {
        return code;
    }

    code = request_setopt_string(lua, options_index, easy, "proxy", CURLOPT_PROXY);
    if (code != CURLE_OK) {
        return code;
    }
    code = request_setopt_string(lua, options_index, easy, "ca_file", CURLOPT_CAINFO);
    if (code != CURLE_OK) {
        return code;
    }
    code = request_setopt_string(lua, options_index, easy, "client_cert", CURLOPT_SSLCERT);
    if (code != CURLE_OK) {
        return code;
    }
    code = request_setopt_string(lua, options_index, easy, "client_key", CURLOPT_SSLKEY);
    if (code != CURLE_OK) {
        return code;
    }
    code = request_setopt_string(lua, options_index, easy, "username", CURLOPT_USERNAME);
    if (code != CURLE_OK) {
        return code;
    }
    code = request_setopt_string(lua, options_index, easy, "password", CURLOPT_PASSWORD);
    if (code != CURLE_OK) {
        return code;
    }

    lua_getfield(lua, options_index, "verify_tls");
    if (!lua_isnil(lua, -1) && !lua_toboolean(lua, -1)) {
        REQUEST_SETOPT(CURLOPT_SSL_VERIFYPEER, 0L);
        REQUEST_SETOPT(CURLOPT_SSL_VERIFYHOST, 0L);
    }
    lua_pop(lua, 1);

    if (transfer->manager->share != NULL) {
        REQUEST_SETOPT(CURLOPT_SHARE, transfer->manager->share);
        REQUEST_SETOPT(CURLOPT_COOKIEFILE, "");
    }

    code = request_configure_headers(lua, options_index, transfer);
    if (code != CURLE_OK) {
        return code;
    }

    code = request_configure_body(lua, options_index, transfer);
    if (code != CURLE_OK) {
        return code;
    }

    lua_getfield(lua, options_index, "method");
    method = luaL_checkstring(lua, -1);
    if (strcmp(method, "GET") == 0) {
        if (transfer->body_ref != LUA_NOREF) {
            REQUEST_SETOPT(CURLOPT_CUSTOMREQUEST, "GET");
        } else {
            REQUEST_SETOPT(CURLOPT_HTTPGET, 1L);
        }
    } else if (strcmp(method, "HEAD") == 0) {
        REQUEST_SETOPT(CURLOPT_NOBODY, 1L);
    } else {
        REQUEST_SETOPT(CURLOPT_CUSTOMREQUEST, method);
    }
    lua_pop(lua, 1);
    return CURLE_OK;
#undef REQUEST_SETOPT
}

static int request_manager_new(lua_State *lua)
{
    request_multi_t *manager;
    CURLMcode multi_code;
    bool cookies = false;

    luaL_checktype(lua, 1, LUA_TFUNCTION);
    luaL_checktype(lua, 2, LUA_TFUNCTION);
    luaL_checktype(lua, 3, LUA_TTABLE);

    manager = lua_newuserdata(lua, sizeof(*manager));
    memset(manager, 0, sizeof(*manager));
    manager->lua = lua;

    luaL_getmetatable(lua, REQUEST_MANAGER_METATABLE);
    lua_setmetatable(lua, -2);

    lua_newtable(lua);
    lua_pushvalue(lua, 1);
    lua_setfield(lua, -2, REQUEST_SOCKET_CALLBACK);
    lua_pushvalue(lua, 2);
    lua_setfield(lua, -2, REQUEST_TIMER_CALLBACK);
    lua_setfenv(lua, -2);

    manager->multi = curl_multi_init();
    if (manager->multi == NULL) {
        return luaL_error(lua, "curl_multi_init failed");
    }

    multi_code = curl_multi_setopt(
        manager->multi,
        CURLMOPT_SOCKETFUNCTION,
        request_socket_callback);
    if (multi_code == CURLM_OK) {
        multi_code = curl_multi_setopt(manager->multi, CURLMOPT_SOCKETDATA, manager);
    }
    if (multi_code == CURLM_OK) {
        multi_code = curl_multi_setopt(
            manager->multi,
            CURLMOPT_TIMERFUNCTION,
            request_timer_callback);
    }
    if (multi_code == CURLM_OK) {
        multi_code = curl_multi_setopt(manager->multi, CURLMOPT_TIMERDATA, manager);
    }
    if (multi_code == CURLM_OK) {
        multi_code = curl_multi_setopt(
            manager->multi,
            CURLMOPT_PIPELINING,
            CURLPIPE_MULTIPLEX);
    }

    lua_getfield(lua, 3, "max_total_connections");
    if (multi_code == CURLM_OK && lua_isnumber(lua, -1)) {
        multi_code = curl_multi_setopt(
            manager->multi,
            CURLMOPT_MAX_TOTAL_CONNECTIONS,
            (long)lua_tonumber(lua, -1));
    }
    lua_pop(lua, 1);

    lua_getfield(lua, 3, "max_host_connections");
    if (multi_code == CURLM_OK && lua_isnumber(lua, -1)) {
        multi_code = curl_multi_setopt(
            manager->multi,
            CURLMOPT_MAX_HOST_CONNECTIONS,
            (long)lua_tonumber(lua, -1));
    }
    lua_pop(lua, 1);

    lua_getfield(lua, 3, "cookies");
    cookies = lua_toboolean(lua, -1);
    lua_pop(lua, 1);

    if (multi_code != CURLM_OK) {
        request_manager_release(manager);
        return luaL_error(
            lua,
            "failed to configure curl multi: %s",
            curl_multi_strerror(multi_code));
    }

    if (cookies) {
        CURLSHcode share_code;

        manager->share = curl_share_init();
        if (manager->share == NULL) {
            request_manager_release(manager);
            return luaL_error(lua, "curl_share_init failed");
        }
        share_code = curl_share_setopt(manager->share, CURLSHOPT_SHARE, CURL_LOCK_DATA_COOKIE);
        if (share_code != CURLSHE_OK) {
            request_manager_release(manager);
            return luaL_error(lua, "failed to configure cookie sharing: %s",
                              curl_share_strerror(share_code));
        }
    }

    return 1;
}

static int request_manager_add(lua_State *lua)
{
    request_multi_t *manager = request_check_manager(lua, 1);
    request_transfer_t *transfer;
    CURLcode code;
    CURLMcode multi_code;
    uint64_t timer_callback_count;

    luaL_checktype(lua, 2, LUA_TTABLE);
    if (manager->closed || manager->multi == NULL) {
        return luaL_error(lua, "session is closed");
    }
    manager->lua = lua;
    manager->callback_owner_index = 1;

    transfer = lua_newuserdata(lua, sizeof(*transfer));
    memset(transfer, 0, sizeof(*transfer));
    transfer->manager = manager;
    manager->next_transfer_id++;
    transfer->id = manager->next_transfer_id;
    transfer->self_ref = LUA_NOREF;
    transfer->body_ref = LUA_NOREF;
    request_buffer_init(
        &transfer->body,
        request_get_limit(lua, 2, "max_body_bytes", REQUEST_DEFAULT_BODY_LIMIT));
    request_buffer_init(
        &transfer->header,
        request_get_limit(lua, 2, "max_header_bytes", REQUEST_DEFAULT_HEADER_LIMIT));

    luaL_getmetatable(lua, REQUEST_TRANSFER_METATABLE);
    lua_setmetatable(lua, -2);

    lua_newtable(lua);
    lua_pushvalue(lua, 1);
    lua_setfield(lua, -2, "manager");
    lua_setfenv(lua, -2);

    transfer->easy = curl_easy_init();
    if (transfer->easy == NULL) {
        request_transfer_cleanup(lua, transfer);
        lua_pushnil(lua);
        lua_pushstring(lua, "curl_easy_init failed");
        return 2;
    }

    code = request_configure_transfer(lua, 2, transfer);
    if (code != CURLE_OK) {
        request_transfer_cleanup(lua, transfer);
        lua_pushnil(lua);
        lua_pushstring(lua, curl_easy_strerror(code));
        return 2;
    }

    request_manager_link_transfer(manager, transfer);
    timer_callback_count = manager->timer_callback_count;
    multi_code = curl_multi_add_handle(manager->multi, transfer->easy);
    if (multi_code != CURLM_OK) {
        bool fatal = manager->callback_error[0] != '\0';

        request_manager_unlink_transfer(transfer);
        request_transfer_cleanup(lua, transfer);
        request_push_manager_error(lua, manager, multi_code);
        lua_pushboolean(lua, fatal);
        return 3;
    }

    transfer->active = true;
    lua_pushvalue(lua, -1);
    transfer->self_ref = luaL_ref(lua, LUA_REGISTRYINDEX);
    lua_pushnumber(lua, (lua_Number)transfer->id);
    lua_pushboolean(lua, manager->timer_callback_count == timer_callback_count);
    if (manager->callback_error[0] != '\0') {
        lua_pushstring(lua, manager->callback_error);
        manager->callback_error[0] = '\0';
    } else {
        lua_pushnil(lua);
    }
    return 4;
}

static int request_manager_perform(
    lua_State *lua,
    request_multi_t *manager,
    curl_socket_t socket,
    int events)
{
    CURLMcode code;
    int running = 0;

    if (manager->closed || manager->multi == NULL) {
        return luaL_error(lua, "session is closed");
    }
    if (manager->action_depth != 0) {
        return luaL_error(lua, "recursive curl multi action");
    }

    manager->lua = lua;
    manager->callback_owner_index = 1;
    manager->action_depth++;
    do {
        code = curl_multi_socket_action(manager->multi, socket, events, &running);
    } while (code == CURLM_CALL_MULTI_PERFORM);
    manager->action_depth--;

    if (code != CURLM_OK || manager->callback_error[0] != '\0') {
        return request_push_manager_error(lua, manager, code);
    }

    return request_drain_messages(lua, manager);
}

static int request_manager_socket_action(lua_State *lua)
{
    request_multi_t *manager = request_check_manager(lua, 1);
    curl_socket_t socket = (curl_socket_t)luaL_checknumber(lua, 2);
    int events = luaL_checkinteger(lua, 3);

    return request_manager_perform(lua, manager, socket, events);
}

static int request_manager_timeout_action(lua_State *lua)
{
    request_multi_t *manager = request_check_manager(lua, 1);

    return request_manager_perform(lua, manager, CURL_SOCKET_TIMEOUT, 0);
}

static int request_manager_cancel(lua_State *lua)
{
    request_multi_t *manager = request_check_manager(lua, 1);
    request_transfer_t *transfer = request_check_transfer(lua, 2);
    const char *reason = luaL_optstring(lua, 3, "request cancelled");
    CURLMcode code;

    if (transfer->manager != manager || transfer->finished) {
        lua_pushnil(lua);
        return 1;
    }

    manager->lua = lua;
    manager->callback_owner_index = 1;
    code = request_complete_transfer(
        lua,
        transfer,
        CURLE_ABORTED_BY_CALLBACK,
        true,
        reason);
    if (code != CURLM_OK || manager->callback_error[0] != '\0') {
        if (manager->callback_error[0] != '\0') {
            lua_pushstring(lua, manager->callback_error);
            manager->callback_error[0] = '\0';
        } else {
            lua_pushstring(lua, curl_multi_strerror(code));
        }
        return 2;
    }
    return 1;
}

static void request_manager_release(request_multi_t *manager)
{
    if (manager->multi != NULL) {
        CURLMcode code = curl_multi_cleanup(manager->multi);

        manager->multi = NULL;
        if (code != CURLM_OK && manager->callback_error[0] == '\0') {
            snprintf(
                manager->callback_error,
                sizeof(manager->callback_error),
                "failed to clean up curl multi: %s",
                curl_multi_strerror(code));
        }
    }
    if (manager->share != NULL) {
        CURLSHcode code = curl_share_cleanup(manager->share);

        manager->share = NULL;
        if (code != CURLSHE_OK && manager->callback_error[0] == '\0') {
            snprintf(
                manager->callback_error,
                sizeof(manager->callback_error),
                "failed to clean up curl share: %s",
                curl_share_strerror(code));
        }
    }
    manager->closed = true;
}

static int request_manager_close(lua_State *lua)
{
    request_multi_t *manager = request_check_manager(lua, 1);
    int index = 1;
    const char *error = NULL;

    lua_createtable(lua, 0, 0);
    if (manager->closed) {
        return 1;
    }

    manager->lua = lua;
    manager->callback_owner_index = 1;
    while (manager->transfers != NULL) {
        request_transfer_t *transfer = manager->transfers;
        CURLMcode code = request_complete_transfer(
            lua,
            transfer,
            CURLE_ABORTED_BY_CALLBACK,
            true,
            "session closed");

        lua_rawseti(lua, -2, index++);
        if (code != CURLM_OK && error == NULL) {
            error = curl_multi_strerror(code);
        }
        if (manager->callback_error[0] != '\0' && error == NULL) {
            error = manager->callback_error;
        }
    }

    request_manager_release(manager);
    if (manager->callback_error[0] != '\0' && error == NULL) {
        error = manager->callback_error;
    }
    if (error != NULL) {
        lua_pushstring(lua, error);
        manager->callback_error[0] = '\0';
        return 2;
    }
    return 1;
}

static int request_manager_gc(lua_State *lua)
{
    request_multi_t *manager = request_check_manager(lua, 1);

    manager->lua = lua;
    manager->callback_owner_index = 1;
    while (manager->transfers != NULL) {
        request_transfer_t *transfer = manager->transfers;

        if (transfer->active && manager->multi != NULL) {
            curl_multi_remove_handle(manager->multi, transfer->easy);
            transfer->active = false;
        }
        request_manager_unlink_transfer(transfer);
        request_transfer_cleanup(lua, transfer);
        if (transfer->self_ref != LUA_NOREF) {
            luaL_unref(lua, LUA_REGISTRYINDEX, transfer->self_ref);
            transfer->self_ref = LUA_NOREF;
        }
    }
    request_manager_release(manager);
    return 0;
}

static int request_transfer_gc(lua_State *lua)
{
    request_transfer_t *transfer = request_check_transfer(lua, 1);

    if (!transfer->active) {
        request_transfer_cleanup(lua, transfer);
    }
    return 0;
}

static bool request_protocol_available(const curl_version_info_data *info, const char *wanted)
{
    const char *const *protocol;

    for (protocol = info->protocols; protocol != NULL && *protocol != NULL; protocol++) {
        if (strcmp(*protocol, wanted) == 0) {
            return true;
        }
    }
    return false;
}

static int request_capabilities(lua_State *lua)
{
    const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);

    lua_createtable(lua, 0, 12);
    request_set_field_string(lua, "libcurl_version", info->version);
    request_set_field_number(lua, "libcurl_version_num", (lua_Number)info->version_num);
    request_set_field_string(lua, "ssl_version", info->ssl_version);
    request_set_field_boolean(lua, "http", request_protocol_available(info, "http"));
    request_set_field_boolean(lua, "https", request_protocol_available(info, "https"));
    request_set_field_boolean(lua, "ssl", (info->features & CURL_VERSION_SSL) != 0);
    request_set_field_boolean(lua, "async_dns", (info->features & CURL_VERSION_ASYNCHDNS) != 0);
    request_set_field_boolean(lua, "http2", (info->features & CURL_VERSION_HTTP2) != 0);
#ifdef CURL_VERSION_HTTP3
    request_set_field_boolean(lua, "http3", (info->features & CURL_VERSION_HTTP3) != 0);
#else
    request_set_field_boolean(lua, "http3", false);
#endif
#ifdef CURL_VERSION_BROTLI
    request_set_field_boolean(lua, "brotli", (info->features & CURL_VERSION_BROTLI) != 0);
#else
    request_set_field_boolean(lua, "brotli", false);
#endif
#ifdef CURL_VERSION_ZSTD
    request_set_field_boolean(lua, "zstd", (info->features & CURL_VERSION_ZSTD) != 0);
#else
    request_set_field_boolean(lua, "zstd", false);
#endif
    return 1;
}

static const luaL_Reg request_manager_methods[] = {
    {"add", request_manager_add},
    {"socket_action", request_manager_socket_action},
    {"timeout_action", request_manager_timeout_action},
    {"cancel", request_manager_cancel},
    {"close", request_manager_close},
    {NULL, NULL},
};

static const luaL_Reg request_core_functions[] = {
    {"new", request_manager_new},
    {"capabilities", request_capabilities},
    {NULL, NULL},
};

static void request_create_manager_metatable(lua_State *lua)
{
    luaL_newmetatable(lua, REQUEST_MANAGER_METATABLE);
    lua_pushcfunction(lua, request_manager_gc);
    lua_setfield(lua, -2, "__gc");
    lua_newtable(lua);
    luaL_register(lua, NULL, request_manager_methods);
    lua_setfield(lua, -2, "__index");
    lua_pop(lua, 1);
}

static void request_create_transfer_metatable(lua_State *lua)
{
    luaL_newmetatable(lua, REQUEST_TRANSFER_METATABLE);
    lua_pushcfunction(lua, request_transfer_gc);
    lua_setfield(lua, -2, "__gc");
    lua_pop(lua, 1);
}

int luaopen_request_core(lua_State *lua)
{
    const curl_version_info_data *info;
    int once_code;

    once_code = pthread_once(&request_curl_once, request_curl_global_init);
    if (once_code != 0) {
        return luaL_error(lua, "pthread_once failed: %s", strerror(once_code));
    }
    if (request_curl_init_result != CURLE_OK) {
        return luaL_error(
            lua,
            "curl_global_init failed: %s",
            curl_easy_strerror(request_curl_init_result));
    }

    info = curl_version_info(CURLVERSION_NOW);
    if (info == NULL || info->version_num < 0x074400) {
        return luaL_error(
            lua,
            "libcurl 7.68.0 or newer is required; loaded %s",
            info == NULL ? "unknown" : info->version);
    }
    if (!request_protocol_available(info, "http") ||
        !request_protocol_available(info, "https") ||
        (info->features & CURL_VERSION_SSL) == 0) {
        return luaL_error(lua, "loaded libcurl must support HTTP, HTTPS, and TLS");
    }

    request_create_manager_metatable(lua);
    request_create_transfer_metatable(lua);

    lua_newtable(lua);
    luaL_register(lua, NULL, request_core_functions);

    lua_pushinteger(lua, CURL_POLL_IN);
    lua_setfield(lua, -2, "POLL_IN");
    lua_pushinteger(lua, CURL_POLL_OUT);
    lua_setfield(lua, -2, "POLL_OUT");
    lua_pushinteger(lua, CURL_POLL_INOUT);
    lua_setfield(lua, -2, "POLL_INOUT");
    lua_pushinteger(lua, CURL_POLL_REMOVE);
    lua_setfield(lua, -2, "POLL_REMOVE");
    lua_pushinteger(lua, CURL_CSELECT_IN);
    lua_setfield(lua, -2, "CSELECT_IN");
    lua_pushinteger(lua, CURL_CSELECT_OUT);
    lua_setfield(lua, -2, "CSELECT_OUT");
    lua_pushinteger(lua, CURL_CSELECT_ERR);
    lua_setfield(lua, -2, "CSELECT_ERR");
    lua_pushinteger(lua, CURLE_OPERATION_TIMEDOUT);
    lua_setfield(lua, -2, "CURLE_OPERATION_TIMEDOUT");
    lua_pushinteger(lua, CURLE_UNSUPPORTED_PROTOCOL);
    lua_setfield(lua, -2, "CURLE_UNSUPPORTED_PROTOCOL");
    lua_pushinteger(lua, CURLE_URL_MALFORMAT);
    lua_setfield(lua, -2, "CURLE_URL_MALFORMAT");
    lua_pushinteger(lua, CURLE_NOT_BUILT_IN);
    lua_setfield(lua, -2, "CURLE_NOT_BUILT_IN");

    return 1;
}
