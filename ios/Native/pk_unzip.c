#include "pk_unzip.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <zlib.h>

static uint16_t u16(const unsigned char *p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static uint32_t u32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int mkpath(char *path) {
  for (char *p = path + 1; *p; p++) {
    if (*p == '/') {
      *p = 0;
      mkdir(path, 0755);
      *p = '/';
    }
  }
  return 0;
}

static int inflate_raw(const unsigned char *src, size_t src_len, unsigned char *dst, size_t dst_len) {
  z_stream strm;
  memset(&strm, 0, sizeof(strm));
  if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) return -1;
  strm.next_in = (Bytef *)src;
  strm.avail_in = (uInt)src_len;
  strm.next_out = dst;
  strm.avail_out = (uInt)dst_len;
  int rc = inflate(&strm, Z_FINISH);
  inflateEnd(&strm);
  return (rc == Z_STREAM_END || rc == Z_OK) ? 0 : -1;
}

bool pk_unzip(const char *zip_path, const char *dest_dir) {
  FILE *f = fopen(zip_path, "rb");
  if (!f) return false;
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (sz <= 0) { fclose(f); return false; }
  unsigned char *buf = malloc((size_t)sz);
  if (!buf) { fclose(f); return false; }
  if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) { free(buf); fclose(f); return false; }
  fclose(f);

  size_t off = 0;
  bool ok = true;
  while (off + 30 <= (size_t)sz) {
    if (u32(buf + off) != 0x04034b50u) break;
    uint16_t method = u16(buf + off + 8);
    uint32_t comp = u32(buf + off + 18);
    uint32_t uncomp = u32(buf + off + 22);
    uint16_t nlen = u16(buf + off + 26);
    uint16_t xlen = u16(buf + off + 28);
    size_t name_at = off + 30;
    size_t data_at = name_at + nlen + xlen;
    if (data_at + comp > (size_t)sz) { ok = false; break; }

    char name[1024];
    if (nlen >= sizeof(name)) { ok = false; break; }
    memcpy(name, buf + name_at, nlen);
    name[nlen] = 0;

    char outpath[2048];
    snprintf(outpath, sizeof(outpath), "%s/%s", dest_dir, name);
    if (nlen > 0 && name[nlen - 1] == '/') {
      mkpath(outpath);
      mkdir(outpath, 0755);
    } else {
      mkpath(outpath);
      unsigned char *out = NULL;
      size_t out_len = uncomp;
      if (method == 0) {
        out = buf + data_at;
        out_len = comp;
        FILE *o = fopen(outpath, "wb");
        if (!o) { ok = false; break; }
        fwrite(out, 1, out_len, o);
        fclose(o);
      } else if (method == 8) {
        out = malloc(uncomp ? uncomp : 1);
        if (!out || inflate_raw(buf + data_at, comp, out, uncomp) != 0) {
          free(out); ok = false; break;
        }
        FILE *o = fopen(outpath, "wb");
        if (!o) { free(out); ok = false; break; }
        fwrite(out, 1, uncomp, o);
        fclose(o);
        free(out);
      } else {
        ok = false; break;
      }
    }
    off = data_at + comp;
  }
  free(buf);
  return ok;
}
