#include "DogecoinKitShims.h"

/* As libdogecoin's ecc.c defines it. This file includes none of
 * libdogecoin's headers, whose declaration of the same function drops the
 * result. */
extern uint8_t dogecoin_ecc_start(void);

bool dogecoinkit_ecc_start(void)
{
    return dogecoin_ecc_start() != 0;
}
