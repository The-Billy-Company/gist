/* gist — fast, agent-friendly code locator kernel. Flat C ABI (no namespaces).
 * Generated parity surface for the Go (cgo) + Python (cffi) bindings.
 * Mirrors pkg/kernels/core/include/lamina.h. */
#ifndef GIST_H
#define GIST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* C-ABI version; bump on any breaking change so bindings can refuse a
 * mismatched shared library. */
uint32_t gist_abi_version(void);

/* Extract the distinct, ascending trigrams of text[0..len] into out[0..len]
 * (caller sizes out >= len). Returns the count written; len < 3 yields 0.
 * Deterministic, allocation-free — the cross-language parity oracle. */
size_t gist_trigram_count(const uint8_t *text, size_t len, uint32_t *out);

#ifdef __cplusplus
}
#endif

#endif /* GIST_H */
