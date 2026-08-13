#include "request_buffer.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define REQUEST_BUFFER_INITIAL_CAPACITY 4096U

void request_buffer_init(request_buffer_t *buffer, size_t limit)
{
    buffer->data = NULL;
    buffer->size = 0;
    buffer->capacity = 0;
    buffer->limit = limit;
    buffer->error = REQUEST_BUFFER_OK;
}

void request_buffer_free(request_buffer_t *buffer)
{
    free(buffer->data);
    request_buffer_init(buffer, buffer->limit);
}

static int request_buffer_reserve(request_buffer_t *buffer, size_t required)
{
    size_t capacity;
    char *data;

    if (required <= buffer->capacity) {
        return 1;
    }

    capacity = buffer->capacity;
    if (capacity == 0) {
        capacity = REQUEST_BUFFER_INITIAL_CAPACITY;
    }

    while (capacity < required) {
        if (capacity > SIZE_MAX / 2) {
            capacity = required;
            break;
        }
        capacity *= 2;
    }

    data = realloc(buffer->data, capacity);
    if (data == NULL) {
        buffer->error = REQUEST_BUFFER_OOM;
        return 0;
    }

    buffer->data = data;
    buffer->capacity = capacity;
    return 1;
}

int request_buffer_append(request_buffer_t *buffer, const char *data, size_t size)
{
    size_t required;

    if (buffer->error != REQUEST_BUFFER_OK) {
        return 0;
    }

    if (size > SIZE_MAX - buffer->size) {
        buffer->error = REQUEST_BUFFER_OVERFLOW;
        return 0;
    }

    required = buffer->size + size;
    if (required > buffer->limit) {
        buffer->error = REQUEST_BUFFER_LIMIT;
        return 0;
    }

    if (size == 0) {
        return 1;
    }

    if (!request_buffer_reserve(buffer, required)) {
        return 0;
    }

    memcpy(buffer->data + buffer->size, data, size);
    buffer->size = required;
    return 1;
}

