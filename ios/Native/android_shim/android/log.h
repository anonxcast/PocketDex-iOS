#pragma once
/* Minimal Android log shim so upstream pk_nds.cpp compiles on iOS. */
#include <stdio.h>
#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  ANDROID_LOG_UNKNOWN = 0,
  ANDROID_LOG_DEFAULT = 1,
  ANDROID_LOG_VERBOSE = 2,
  ANDROID_LOG_DEBUG = 3,
  ANDROID_LOG_INFO = 4,
  ANDROID_LOG_WARN = 5,
  ANDROID_LOG_ERROR = 6,
  ANDROID_LOG_FATAL = 7,
  ANDROID_LOG_SILENT = 8,
};

static inline int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
  (void)prio;
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "[%s] ", tag ? tag : "nds");
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  return 0;
}

#ifdef __cplusplus
}
#endif
