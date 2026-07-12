/* gist — fast, agent-friendly code locator kernel.
 *
 * This C ABI is deliberately minimal: ABI/engine-version introspection plus
 * one allocation-free trigram primitive. It does not expose index open/build,
 * search, result, ownership, or error APIs. Search embedding uses the unified
 * search contract (ADR-352) over the certified gist binary; a resident
 * in-process session ABI is a planned graduation rung. */
#ifndef GIST_H
#define GIST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* C-ABI version; bump on any breaking change so consumers can reject a
 * mismatched shared library. Additive symbols do not bump it. */
uint32_t gist_abi_version(void);

/* The engine semantic version (e.g. "0.1.0"), NUL-terminated, static-lifetime;
 * never NULL. Lets a binding version-gate the library/binary it drives. */
const char *gist_version(void);

/* Extract the distinct, ascending trigrams of text[0..len] into out[0..len]
 * (caller sizes out >= len). Returns the count written; len < 3 yields 0. */
size_t gist_trigram_count(const uint8_t *text, size_t len, uint32_t *out);

#ifdef __cplusplus
}
#endif

#endif /* GIST_H */
