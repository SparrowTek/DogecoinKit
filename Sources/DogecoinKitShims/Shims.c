#include "DogecoinKitShims.h"

#include <dogecoin/scrypt.h>

void dogecoinkit_scrypt_pow_hash(const uint8_t header[80], uint8_t hash[32])
{
    scrypt_1024_1_1_256((const char *)header, (char *)hash);
}

/* Defined in libdogecoin's bip39.c. */
extern const char *const wordlist_eng[];

const char *dogecoinkit_bip39_english_word(int index)
{
    if (index < 0 || index >= 2048) {
        return NULL;
    }
    return wordlist_eng[index];
}
