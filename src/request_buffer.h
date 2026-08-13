#ifndef REQUEST_BUFFER_H
#define REQUEST_BUFFER_H

#include <stddef.h>

typedef enum request_buffer_error {
    REQUEST_BUFFER_OK = 0,
    REQUEST_BUFFER_LIMIT,
    REQUEST_BUFFER_OOM,
    REQUEST_BUFFER_OVERFLOW,
} request_buffer_error_t;

typedef struct request_buffer {
    char *data;
    size_t size;
    size_t capacity;
    size_t limit;
    request_buffer_error_t error;
} request_buffer_t;

void request_buffer_init(request_buffer_t *buffer, size_t limit);
void request_buffer_free(request_buffer_t *buffer);
int request_buffer_append(request_buffer_t *buffer, const char *data, size_t size);

#endif

