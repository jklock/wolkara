#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// Our bounded GDB remote-protocol codec. No sockets, attachment, memory access,
// credentials or native execution happen here. Payloads must never be logged.
typedef enum { DW_MORE, DW_PACKET, DW_NOTIFICATION, DW_ACK, DW_NACK,
               DW_BAD_CHECKSUM, DW_MALFORMED, DW_OVERFLOW } DWEvent;
typedef struct {
    uint8_t *payload;
    size_t capacity,length;
    uint8_t state,sum,expected;
    bool notification;
} DWParser;
void dw_init(DWParser *parser,void *buffer,size_t capacity);
DWEvent dw_feed(DWParser *parser,uint8_t byte);
// All-or-nothing packet encoding; returns 0 if the destination is too small.
size_t dw_encode(const void *payload,size_t length,void *destination,size_t capacity);
