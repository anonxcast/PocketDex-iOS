// Software-only stub for pk_nds_gl.h — no GLES / ANativeWindow on iOS (v1).
#include "pk_nds_gl.h"

int pk_nds_gl_set_scale(melonDS::NDS *nds, int scale) {
  (void)nds;
  (void)scale;
  return 1;
}

int pk_nds_gl_scale() { return 1; }

int pk_nds_gl_supported() { return 0; }

void pk_nds_gl_end(melonDS::NDS *nds) { (void)nds; }

void pk_nds_gl_begin_frame() {}

void pk_nds_gl_set_window(ANativeWindow *window) { (void)window; }

bool pk_nds_gl_frame(melonDS::NDS *nds, int x, int y, int w, int h, uint32_t *top, uint32_t *bottom) {
  (void)nds;
  (void)x;
  (void)y;
  (void)w;
  (void)h;
  (void)top;
  (void)bottom;
  return false;
}

void pk_nds_gl_capture(bool on) { (void)on; }

const uint32_t *pk_nds_gl_captured(int *w, int *h) {
  if (w) *w = 0;
  if (h) *h = 0;
  return nullptr;
}

bool pk_nds_gl_frame_info(int64_t timestamp, int32_t out[6]) {
  (void)timestamp;
  if (out) {
    for (int i = 0; i < 6; i++) out[i] = 0;
  }
  return false;
}
