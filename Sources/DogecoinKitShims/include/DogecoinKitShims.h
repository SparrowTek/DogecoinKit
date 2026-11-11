#ifndef DOGECOINKIT_SHIMS_H
#define DOGECOINKIT_SHIMS_H

#include <stdbool.h>
#include <stdint.h>

/// Dogecoin's (and Litecoin's) proof-of-work hash: scrypt with N=1024, r=1,
/// p=1 over an 80-byte block header.
///
/// libdogecoin writes the 32-byte result in display (big-endian) order, the
/// reverse of the little-endian layout block hashes use internally.
void dogecoinkit_scrypt_pow_hash(const uint8_t header[80], uint8_t hash[32]);

/// The BIP39 English word at `index` (0-2047) — the list libdogecoin checks
/// mnemonics against — or NULL when `index` is out of range.
const char *dogecoinkit_bip39_english_word(int index);

/// Creates the calling thread's secp256k1 context and reports whether it is
/// usable.
///
/// libdogecoin's headers declare `dogecoin_ecc_start` as returning nothing,
/// while the function reports whether the context was created and seeded.
/// This forwards that result.
bool dogecoinkit_ecc_start(void);

#endif
