/* PocketDex: glue between two PokeDaisy versions of EXPAND.
 *
 * This folder holds PokeDaisy v1.5.1's Game Boy rebuild (pk_wide_gb.c and its Polished Crystal
 * includes, copied unchanged from github.com/lidor30/pokedaisy at tag v1.5.1). The GBA rebuild
 * (pk_wide.c) is still the v1.5.0.1 copy under upstream/, because v1.5.1's needs modules this
 * port does not build (pk_flight.c and others).
 *
 * v1.5.0.1's pk_wide.c still refers to the old entry point for an externally supplied Polished
 * Crystal profile. v1.5.1 looks that game up by CRC inside pk_wide_gb_configure() instead and
 * made the function file-local, so the old name is satisfied here. Nothing calls it. */
#include <stdint.h>

#include "pk_wide_gb_profile.h"

int pk_wide_gb_configure_polished(const uint32_t addresses[GB_CONFIG], pk_wide_gb_decode_fn decode) {
  (void)addresses;
  (void)decode;
  return 0;
}
