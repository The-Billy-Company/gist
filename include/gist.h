/* gist — fast, agent-friendly code locator kernel.
 *
 * This C ABI is deliberately minimal: ABI-version introspection plus one
 * allocation-free trigram primitive. It does not expose index open/build,
 * search, result, ownership, or error APIs. Search embedding is Zig-native;
 * non-Zig consumers use the gist CLI contract. */
#ifndef GIST_H
#define GIST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* C-ABI version; bump on any breaking change so consumers can reject a
 * mismatched shared library. */
uint32_t gist_abi_version(void);

/* Extract the distinct, ascending trigrams of text[0..len] into out[0..len]
 * (caller sizes out >= len). Returns the count written; len < 3 yields 0. */
size_t gist_trigram_count(const uint8_t *text, size_t len, uint32_t *out);

#ifdef __cplusplus
}
#endif

#endif /* GIST_H */
