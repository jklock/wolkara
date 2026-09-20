#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Narrow, local-only IPv4 route. Values are bytes in network order.
typedef struct { uint8_t interface_address[4], peer_address[4]; } LocalRoute;
typedef enum { LR_REFLECTED, LR_UNRELATED, LR_MALFORMED } LRResult;
// Reflect an outbound packet back to the local network stack by exchanging
// endpoints. Never forwards it to an external socket or changes its payload.
LRResult lr_reflect(const LocalRoute *route, void *packet, size_t length);
