#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Unzip a .zip / .deltaskin into an existing directory. Returns true on success. */
bool pk_unzip(const char *zip_path, const char *dest_dir);

#ifdef __cplusplus
}
#endif
