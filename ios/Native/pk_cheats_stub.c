/* PocketDex: pk_wide.c includes pk_cheats.h but does not call these when cheats are unused. */
#include "pk_cheats.h"

void pk_cheats_clear(struct mCore* core) { (void)core; }
int pk_cheats_apply(struct mCore* core, const char* text, size_t len) {
  (void)core; (void)text; (void)len;
  return 0;
}
void pk_cheats_overlay(uint32_t addr, uint8_t* dst, int len) {
  (void)addr; (void)dst; (void)len;
}
void pk_cheats_swap_rom(struct mCore* core) { (void)core; }
int pk_cheats_rom_patched(void) { return 0; }
int pk_cheats_patch(struct mCore* core, uint32_t expectAddr, const uint8_t* expect, int expectLen,
                    uint32_t addr, const uint8_t* value, int len) {
  (void)core; (void)expectAddr; (void)expect; (void)expectLen; (void)addr; (void)value; (void)len;
  return 0;
}
void pk_cheats_unpatch(struct mCore* core) { (void)core; }
int pk_cheats_unpatch_range(struct mCore* core, uint32_t addr, uint32_t len) {
  (void)core; (void)addr; (void)len;
  return 0;
}
int pk_cheats_patch_overlaps(uint32_t addr, uint32_t len) {
  (void)addr; (void)len;
  return 0;
}
int pk_cheats_block(struct mCore* core, uint32_t addr, const uint8_t* data, int len, uint32_t expectCrc) {
  (void)core; (void)addr; (void)data; (void)len; (void)expectCrc;
  return 0;
}
void pk_cheats_unblock(struct mCore* core) { (void)core; }
int pk_cheats_block_overlaps(uint32_t addr, uint32_t len) {
  (void)addr; (void)len;
  return 0;
}
int pk_cheats_unblock_range(struct mCore* core, uint32_t addr, uint32_t len) {
  (void)core; (void)addr; (void)len;
  return 0;
}
int pk_cheats_repalette(struct mCore* core, const uint8_t* from, int n, const uint8_t* to) {
  (void)core; (void)from; (void)n; (void)to;
  return 0;
}
char* pk_cheats_check(const char* code, int type, const char* directive) {
  (void)code; (void)type; (void)directive;
  return NULL;
}
