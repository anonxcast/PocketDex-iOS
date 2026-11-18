#include "pk_ios.h"
#include "pk_wide.h"
#include "pk_nds.h"

#include <mgba/core/blip_buf.h>
#include <mgba/core/config.h>
#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba/core/serialize.h>
#include <mgba/internal/gb/gb.h>
#include <mgba/internal/gb/memory.h>
#include <mgba/internal/gba/gba.h>
#include <mgba-util/vfs.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

enum { kAudioRingFrames = 8192 };
enum { kAudioTempFrames = 4096 };
enum { kAudioTargetFrames = 3360 }; /* ~70 ms at 48 kHz — GBC Expand underran at 60 ms */
enum { kAudioTargetFramesNds = 5600 }; /* ~117 ms — DS present is heavy; keep a deeper cushion */
enum { kAudioDisplayFps = 60 };     /* CADisplayLink preferredFramesPerSecond */
enum { kNdsStackPixels = PK_NDS_W * PK_NDS_H * 2 };
static int g_jit_ready = 0; /* interpreter only — JIT compiled out of melonDS */

void pk_ios_prepare_jit(void) {
  g_jit_ready = 0;
}

int pk_ios_jit_ready(void) {
  return 0;
}

/* GBA ~59.7275 fps; NDS ~59.8261 — match Android EmulatorEngine pacing. */
static const double kGbaNativeFps = 16777216.0 / 280896.0;
static const double kNdsNativeFps = 33513982.0 / 560190.0;

static struct {
  struct mCore *core;
  color_t *video;
  unsigned vw, vh;
  struct VFile *saveVf;

  /* WIDE / EXPAND output (up to PK_WIDE_MAX_VIEW_W × _H). */
  color_t *wide;
  int wideX, wideY, wideW, wideH;
  int presentW, presentH;
  const color_t *present;
  uint32_t romCrc;
  int wideOk; /* pk_wide_configure / pk_wide_gb_configure succeeded */
  char romName[96]; /* basename for Expand soft-map heuristics (e.g. Radical Red) */

  /* melonDS: stacked top+bottom 256×384 + Soft Expand top window (no GLES battle margins). */
  int nds;
  color_t *nds_stack;
  color_t *nds_wide; /* Expand window (up to PK_WIDE_MAX_VIEW_W × _H) */
  int nds_wide_on;

  int16_t ring[kAudioRingFrames * 2];
  size_t ring_r;
  size_t ring_w;
  size_t ring_count;
  double rate_scale; /* dynamic rate control around display-locked production */
  double output_hz;  /* AVAudioSession actual rate; defaults to 48 kHz */
} g;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_audio_lock = PTHREAD_MUTEX_INITIALIZER;

static void pk_log(struct mLogger *logger, int category, enum mLogLevel level,
                   const char *format, va_list args) {
  (void)logger;
  (void)category;
  (void)level;
  (void)format;
  (void)args;
}

static struct mLogger g_logger = {.log = pk_log, .filter = NULL};

static void audio_ring_clear(void) {
  pthread_mutex_lock(&g_audio_lock);
  g.ring_r = g.ring_w = g.ring_count = 0;
  pthread_mutex_unlock(&g_audio_lock);
  g.rate_scale = 1.0;
}

static void audio_ring_write(const int16_t *samples, int frames) {
  if (frames <= 0) return;
  pthread_mutex_lock(&g_audio_lock);
  for (int i = 0; i < frames; i++) {
    /* Drop newest on overrun — moving the read cursor (drop oldest) puts a
     * discontinuity at the playback point and sounds like constant popping. */
    if (g.ring_count >= kAudioRingFrames) break;
    size_t o = g.ring_w * 2;
    g.ring[o] = samples[i * 2];
    g.ring[o + 1] = samples[i * 2 + 1];
    g.ring_w = (g.ring_w + 1) % kAudioRingFrames;
    g.ring_count++;
  }
  pthread_mutex_unlock(&g_audio_lock);
}

/* CADisplayLink runs at 60 Hz; GBA/GB ~59.73, NDS ~59.83. Without this scale,
 * each frame pushes a few extra samples, the ring fills, and overruns pop. */
static double audio_display_ratio(void) {
  double native = g.nds ? kNdsNativeFps : kGbaNativeFps;
  return native / (double)kAudioDisplayFps;
}

static double audio_output_hz(void) {
  return g.output_hz > 0.0 ? g.output_hz : (double)PK_IOS_AUDIO_SAMPLE_RATE;
}

static double audio_out_rate(void) {
  double scale = g.rate_scale > 0.0 ? g.rate_scale : 1.0;
  return audio_output_hz() * audio_display_ratio() * scale;
}

static void configure_audio_rates_locked(void) {
  double rate = audio_out_rate();
  if (g.nds) {
    pk_nds_set_audio_rate(rate);
    return;
  }
  if (!g.core) return;
  blip_t *left = g.core->getAudioChannel(g.core, 0);
  blip_t *right = g.core->getAudioChannel(g.core, 1);
  if (!left || !right) return;
  double clock = (double)g.core->frequency(g.core);
  blip_set_rates(left, clock, rate);
  blip_set_rates(right, clock, rate);
}

static size_t audio_target_frames(void) {
  return g.nds ? (size_t)kAudioTargetFramesNds : (size_t)kAudioTargetFrames;
}

/* Nudge blip/NDS output so the ring stays near the platform target. */
static void audio_rate_control_locked(void) {
  pthread_mutex_lock(&g_audio_lock);
  size_t level = g.ring_count;
  pthread_mutex_unlock(&g_audio_lock);
  size_t target = audio_target_frames();
  /* Only retune when clearly off — retuning blip every frame crackled GB/GBA. */
  double err = ((double)level - (double)target) / (double)kAudioRingFrames;
  if (fabs(err) < 0.08) {
    if (fabs(g.rate_scale - 1.0) < 0.002) return;
    /* Ease back to 1.0 once the ring is healthy. */
    double back = g.rate_scale * 0.9 + 0.1;
    if (fabs(back - g.rate_scale) < 0.001) return;
    g.rate_scale = back;
    configure_audio_rates_locked();
    return;
  }
  double adj = 1.0 - err * 0.02;
  if (adj < 0.99) adj = 0.99;
  if (adj > 1.01) adj = 1.01;
  if (fabs(adj - g.rate_scale) < 0.002) return;
  g.rate_scale = adj;
  configure_audio_rates_locked();
}

static void drain_audio_locked(bool keep) {
  if (!g.core) return;
  blip_t *left = g.core->getAudioChannel(g.core, 0);
  blip_t *right = g.core->getAudioChannel(g.core, 1);
  if (!left || !right) return;

  int available = blip_samples_avail(left);
  if (available <= 0) return;
  if (available > kAudioTempFrames) available = kAudioTempFrames;

  int16_t temp[kAudioTempFrames * 2];
  memset(temp, 0, sizeof(temp));
  blip_read_samples(left, temp, available, true);
  blip_read_samples(right, temp + 1, available, true);
  if (keep) audio_ring_write(temp, available);
}

static int path_is_nds(const char *path) {
  if (!path) return 0;
  if (pk_nds_is_rom(path)) return 1;
  size_t n = strlen(path);
  return n >= 4 &&
         (path[n - 4] == '.') &&
         (path[n - 3] == 'n' || path[n - 3] == 'N') &&
         (path[n - 2] == 'd' || path[n - 2] == 'D') &&
         (path[n - 1] == 's' || path[n - 1] == 'S');
}

static void nds_present_locked(void) {
  if (!g.nds || !g.nds_stack) return;
  const uint32_t *top = pk_nds_top();
  const uint32_t *bot = pk_nds_bottom();
  if (!top || !bot) return;
  memcpy(g.nds_stack, top, (size_t)PK_NDS_W * PK_NDS_H * sizeof(color_t));
  memcpy(g.nds_stack + PK_NDS_W * PK_NDS_H, bot, (size_t)PK_NDS_W * PK_NDS_H * sizeof(color_t));
  /* Soft Expand: ultrawide top; touch LCD stays in nds_stack bottom half for ONE SCREEN. */
  if (g.nds_wide_on && g.nds_wide && g.wideW > 0 && g.wideH > 0 &&
      g.wideW <= PK_WIDE_MAX_VIEW_W && g.wideH <= PK_WIDE_MAX_VIEW_H &&
      pk_nds_wide_draw((uint32_t *)g.nds_wide, g.wideX, g.wideY, g.wideW, g.wideH)) {
    g.present = g.nds_wide;
    g.presentW = g.wideW;
    g.presentH = g.wideH;
  } else {
    g.present = g.nds_stack;
    g.presentW = PK_NDS_W;
    g.presentH = PK_NDS_H * 2;
  }
  /* Core size for zoom math is always one DS LCD. */
  g.vw = (unsigned)PK_NDS_W;
  g.vh = (unsigned)PK_NDS_H;
}

static void nds_drain_audio_locked(bool keep) {
  int16_t temp[kAudioTempFrames * 2];
  int got = pk_nds_read_audio(temp, kAudioTempFrames);
  if (keep && got > 0) audio_ring_write(temp, got);
}

static void teardown_locked(void) {
  pk_wide_configure(0); /* no game: also clears the Game Boy hand-over for the next ROM */
  pk_wide_reset();
  pk_wide_gb_reset();
  if (g.nds) {
    pk_nds_finish_save(120);
    pk_nds_deinit();
    g.nds = 0;
  }
  if (g.core) {
    g.core->deinit(g.core);
    g.core = NULL;
  }
  free(g.video);
  g.video = NULL;
  free(g.wide);
  g.wide = NULL;
  free(g.nds_stack);
  g.nds_stack = NULL;
  free(g.nds_wide);
  g.nds_wide = NULL;
  g.nds_wide_on = 0;
  g.vw = g.vh = 0;
  g.wideX = g.wideY = g.wideW = g.wideH = 0;
  g.presentW = g.presentH = 0;
  g.present = NULL;
  g.romCrc = 0;
  g.wideOk = 0;
  g.romName[0] = 0;
  g.saveVf = NULL;
  audio_ring_clear();
}

/* v1.5.1's pk_wide_gb.c (Native/wide_gb); not in the v1.5.0.1 pk_wide.h this file includes. */
void pk_wide_gb_snap(void);

static void read_into_locked(uint32_t addr, uint8_t *dst, int len);

static int is_gb_locked(void) {
  return g.core && g.core->platform(g.core) == mPLATFORM_GB;
}

/** On-disk ROM bytes (not mGBA's mirrored cart window). Trimmed dumps keep this under 16 MB. */
static uint32_t gba_pristine_size_locked(void) {
  if (!g.core || g.core->platform(g.core) != mPLATFORM_GBA) return 0;
  const struct GBA *gba = (const struct GBA *)g.core->board;
  return (uint32_t)gba->pristineRomSize;
}

/**
 * Soft-map an unknown dump CRC → retail pk_wide CRC when header code + rev + pristine size
 * match a known cart. Same idea as Android WideScreen.tablesCrc / RandomizedRetail.
 * Accepts exact 16 MB retail and trimmed GoodTools dumps (e.g. TrashMan Emerald ~14.2 MB).
 * Rebuilds are larger than 16 MB pristine and keep their own CRC row. Pass pristine size —
 * mGBA reports non-power-of-two dumps as a 32 MB mirrored cart.
 */
/**
 * Dump CRC → known pk_wide_games.h CRC when the file isn't the exact No-Intro / patch
 * build PokeDaisy measured, but still uses that build's engine (re-dumps, renames).
 */
static uint32_t wide_crc_alias(uint32_t dumpCrc) {
  static const struct {
    uint32_t dump;
    uint32_t wide;
  } kAliases[] = {
      /* Device "Pokemon Radical Red.gba" → Radical Red v4.1 WIDE row */
      { 0xad908d2bu, 0xfba55dd8u },
      /* Pokemon - Emerald Version (U)(TrashMan).gba — trimmed retail BPEE */
      { 0x487491bfu, 0x1f1c08fbu },
      /* Pokémon Crystal Advance Redux.gba → FireRed rev 0 WIDE (vanilla overworld tables) */
      { 0x72920c57u, 0xdd88761cu },
  };
  for (size_t i = 0; i < sizeof(kAliases) / sizeof(kAliases[0]); i++) {
    if (kAliases[i].dump == dumpCrc) return kAliases[i].wide;
  }
  return 0;
}

static int name_has_ci(const char *hay, const char *needle) {
  if (!hay || !needle || !needle[0]) return 0;
  size_t n = strlen(needle);
  for (const char *p = hay; *p; p++) {
    size_t i = 0;
    while (i < n) {
      char a = p[i], b = needle[i];
      if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
      if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
      if (a != b) break;
      i++;
    }
    if (i == n) return 1;
  }
  return 0;
}

/** Filename / header heuristics for known hacks whose dump CRC isn't in the tables. */
static uint32_t soft_hack_wide_crc(const char *code, uint32_t pristineSize) {
  if (!code) return 0;
  /* Must run before soft_retail: Seaglass / Unbound / Rocket share BPEE/BPRE headers. */
  if (name_has_ci(g.romName, "seaglass"))
    return 0x14465a33u;
  if (name_has_ci(g.romName, "unbound"))
    return 0x4b3d4957u;
  if (name_has_ci(g.romName, "rocket"))
    return 0xf2d16ebdu;
  /* Crystal Enhanced (GBA Free Roam) — exact CRC aacbbf26; before Crystal Advance soft-map. */
  if ((name_has_ci(g.romName, "crystal") && name_has_ci(g.romName, "enhanced")) ||
      name_has_ci(g.romName, "crysenha") || name_has_ci(g.romName, "pokecrysenha"))
    return 0xaacbbf26u;
  /* Wishes of Tomorrow v1.3.0 — exact CRC 5a5fc74f; soft-map for renamed dumps. */
  if (name_has_ci(g.romName, "wishes"))
    return 0x5a5fc74fu;
  /* Crystal Advance / Crystal Advance Redux — FireRed-based; keep retail FR WIDE. */
  if ((name_has_ci(g.romName, "crystal") && name_has_ci(g.romName, "advance")) ||
      name_has_ci(g.romName, "crystaladvance"))
    return 0xdd88761cu;
  /* Heart and Soul v2.0.6 — exact CRC 01713508; soft-map for renamed dumps. */
  if (name_has_ci(g.romName, "heart") && name_has_ci(g.romName, "soul"))
    return 0x01713508u;
  /* SoulGold GBA hack (not DS SoulSilver) — device dump matches v1.2.1 Alt 1. */
  if (name_has_ci(g.romName, "soulgold") || name_has_ci(g.romName, "soul gold") ||
      name_has_ci(g.romName, "souldgold"))
    return 0x5578ebeau;
  /* R.O.W.E. v2.1.9.1 Experimental */
  if (name_has_ci(g.romName, "rowe") || name_has_ci(g.romName, "r.o.w.e"))
    return 0xad252fd3u;
  /* Pokémon Lazarus v2.0 — exact CRC 558ae42f; soft-map for renamed dumps. */
  if (name_has_ci(g.romName, "lazarus"))
    return 0x558ae42fu;
  /* Radical Red v4.1 — 32 MB BPRE; cart title stays "POKEMON FIRE". */
  if (strcmp(code, "BPRE") == 0 && pristineSize == 0x02000000u &&
      name_has_ci(g.romName, "radical")) {
    return 0xfba55dd8u;
  }
  if (strcmp(code, "BPRE") == 0 && name_has_ci(g.romName, "radical"))
    return 0xfba55dd8u;
  /* Modern Emerald v3.6 — exact CRC 263a1187; soft-map for renamed dumps. */
  if (name_has_ci(g.romName, "modern") && name_has_ci(g.romName, "emerald"))
    return 0x263a1187u;
  /* Trimmed retail Emerald (TrashMan) when CRC alias missed.
   * Skip named expansion hacks that keep their own WIDE rows. */
  if (strcmp(code, "BPEE") == 0 && pristineSize > 0 && pristineSize <= 0x01000000u &&
      name_has_ci(g.romName, "emerald") && !name_has_ci(g.romName, "seaglass") &&
      !name_has_ci(g.romName, "modern") && !name_has_ci(g.romName, "rowe") &&
      !name_has_ci(g.romName, "soulgold") && !name_has_ci(g.romName, "imperium") &&
      !name_has_ci(g.romName, "lazarus")) {
    return 0x1f1c08fbu;
  }
  return 0;
}

static uint32_t soft_retail_wide_crc(const char *code, int rev, uint32_t pristineSize) {
  if (!code || code[0] == 0 || pristineSize == 0 || pristineSize > 0x01000000u) return 0;
  static const struct {
    char code[5];
    int rev;
    uint32_t crc;
  } kRows[] = {
      /* Emerald — all languages */
      {"BPEE", 0, 0x1f1c08fbu},
      {"BPES", 0, 0x8c4d3108u},
      {"BPED", 0, 0x34c9df89u},
      {"BPEF", 0, 0xa3fdccb1u},
      {"BPEI", 0, 0xa0aec80au},
      {"BPEJ", 0, 0x4881f3f8u},
      /* FireRed */
      {"BPRE", 0, 0xdd88761cu},
      {"BPRE", 1, 0x84ee4776u},
      {"BPRS", 0, 0x9f08064eu},
      {"BPRD", 0, 0x1a81eedfu},
      {"BPRF", 0, 0x5dc668f6u},
      {"BPRI", 0, 0x73a72167u},
      {"BPRJ", 0, 0x3b2056e9u},
      {"BPRJ", 1, 0xbb640df7u},
      /* LeafGreen */
      {"BPGE", 0, 0xd69c96ccu},
      {"BPGE", 1, 0xdaffececu},
      {"BPGS", 0, 0x2ca11d59u},
      {"BPGD", 0, 0xd12f1fddu},
      {"BPGF", 0, 0xba3285e3u},
      {"BPGI", 0, 0x16974506u},
      {"BPGJ", 0, 0x0a48556bu},
      {"BPGJ", 1, 0x8da4601au},
      /* Ruby */
      {"AXVE", 0, 0xf0815ee7u},
      {"AXVE", 1, 0x61641576u},
      {"AXVE", 2, 0xaeac73e6u},
      {"AXVS", 0, 0xeb0729cfu},
      {"AXVS", 1, 0xb980fff5u},
      {"AXVD", 0, 0x15e1e280u},
      {"AXVD", 1, 0xcae89464u},
      {"AXVF", 0, 0x690fd310u},
      {"AXVF", 1, 0x9f981f72u},
      {"AXVI", 0, 0xc18231a9u},
      {"AXVI", 1, 0x9305e793u},
      {"AXVJ", 0, 0xcee9471au},
      {"AXVJ", 1, 0xb448a337u},
      /* Sapphire */
      {"AXPE", 0, 0x554dedc4u},
      {"AXPE", 1, 0xbafedae5u},
      {"AXPE", 2, 0x9cc4410eu},
      {"AXPS", 0, 0xa04f5f0bu},
      {"AXPS", 1, 0xf2c88931u},
      {"AXPD", 0, 0x6fcd7a98u},
      {"AXPD", 1, 0xb0c40c7cu},
      {"AXPF", 0, 0x3581a05fu},
      {"AXPF", 1, 0x2ae49146u},
      {"AXPI", 0, 0x0c7992a9u},
      {"AXPI", 1, 0x5efe4493u},
      {"AXPJ", 0, 0xfd1eeb78u},
      {"AXPJ", 1, 0x01bd60e3u},
  };
  for (size_t i = 0; i < sizeof(kRows) / sizeof(kRows[0]); i++) {
    if (kRows[i].rev == rev && strcmp(code, kRows[i].code) == 0) return kRows[i].crc;
  }
  return 0;
}

static void read_gba_code_rev_locked(char codeOut[5], int *revOut) {
  codeOut[0] = 0;
  *revOut = -1;
  if (!g.core || g.core->platform(g.core) != mPLATFORM_GBA) return;
  uint8_t buf[4];
  read_into_locked(0x080000ACu, buf, 4);
  for (int i = 0; i < 4; i++) {
    uint8_t c = buf[i];
    if (c < 0x20 || c > 0x7E) {
      codeOut[0] = 0;
      return;
    }
    codeOut[i] = (char)c;
  }
  codeOut[4] = 0;
  uint8_t rev = 0;
  read_into_locked(0x080000BCu, &rev, 1);
  *revOut = (int)rev;
}

static void configure_wide_locked(void) {
  g.wideOk = 0;
  g.romCrc = 0;
  if (!g.core || sizeof(color_t) != 4) return;
  uint32_t crc = 0;
  g.core->checksum(g.core, &crc, mCHECKSUM_CRC32);
  g.romCrc = crc;
  /* As PokeDaisy's Android app: one lookup by ROM CRC. pk_wide_configure() hands a Game Boy
   * game it knows (Yellow, Crystal, Crystal Clear, Polished Crystal 3.2.3 ...) to pk_wide_gb.c,
   * and from then on pk_wide_view / pk_wide_scene / pk_wide_wants_close go there too. */
  enum mPlatform plat = g.core->platform(g.core);
  if (plat != mPLATFORM_GBA && plat != mPLATFORM_GB) return;

  uint32_t tryCrc = crc;
  if (!pk_wide_knows(tryCrc)) {
    uint32_t alias = wide_crc_alias(crc);
    if (alias && pk_wide_knows(alias)) {
      fprintf(stderr, "pocketdex: WIDE CRC alias dump=%08x → %08x\n",
              (unsigned)crc, (unsigned)alias);
      tryCrc = alias;
    } else if (plat == mPLATFORM_GBA) {
      char code[5];
      int rev = -1;
      read_gba_code_rev_locked(code, &rev);
      uint32_t pristine = gba_pristine_size_locked();
      uint32_t soft = soft_hack_wide_crc(code, pristine);
      if (!soft) soft = soft_retail_wide_crc(code, rev, pristine);
      if (soft && pk_wide_knows(soft)) {
        fprintf(stderr,
                "pocketdex: WIDE soft-map %s rev%d pristine=%u dump=%08x → %08x (%s)\n",
                code, rev, (unsigned)pristine, (unsigned)crc, (unsigned)soft,
                g.romName[0] ? g.romName : "?");
        tryCrc = soft;
      }
    } else if (plat == mPLATFORM_GB && g.romName[0]) {
      /* Filename soft-map only onto existing GB_ROMS / Polished rows — never invent addresses. */
      uint32_t soft = 0;
      if (name_has_ci(g.romName, "yellow") && !name_has_ci(g.romName, "legacy"))
        soft = 0x7d527d62u;
      else if (name_has_ci(g.romName, "polished"))
        soft = 0xf98367e4u;
      /* Prism — own GB_ROMS row (0x2e883c15); filename soft-map for renamed dumps. */
      else if (name_has_ci(g.romName, "prism") || name_has_ci(g.romName, "pokeprism"))
        soft = 0x2e883c15u;
      /* Crystal Clear — device dump CRC 4d2a5ad5 not in GB_ROMS; RAM matches Clear rows. */
      else if (name_has_ci(g.romName, "clear") && name_has_ci(g.romName, "crystal"))
        soft = 0x17617cdeu;
      else if (name_has_ci(g.romName, "midori") ||
               (name_has_ci(g.romName, "green") && !name_has_ci(g.romName, "leaf")))
        soft = 0xbaeacd2bu;
      else if (name_has_ci(g.romName, "blue") && !name_has_ci(g.romName, "crystal"))
        soft = 0xd6da8a1au;
      else if (name_has_ci(g.romName, "red") && !name_has_ci(g.romName, "firered") &&
               !name_has_ci(g.romName, "fire") && !name_has_ci(g.romName, "radical"))
        soft = 0x9f7fdd53u;
      /* Plain Crystal filename when CRC isn't a measured No-Intro build. */
      else if (name_has_ci(g.romName, "crystal") && !name_has_ci(g.romName, "clear") &&
               !name_has_ci(g.romName, "legacy") && !name_has_ci(g.romName, "polished") &&
               !name_has_ci(g.romName, "enhanced") && !name_has_ci(g.romName, "advance"))
        soft = 0x3358e30au;
      if (soft && pk_wide_knows(soft)) {
        fprintf(stderr, "pocketdex: WIDE GB filename soft-map dump=%08x → %08x (%s)\n",
                (unsigned)crc, (unsigned)soft, g.romName);
        tryCrc = soft;
      }
    }
  }

  g.wideOk = pk_wide_configure(tryCrc) != 0;
  if (g.wideOk) {
    fprintf(stderr, "pocketdex: WIDE ok dump=%08x configured=%08x\n",
            (unsigned)crc, (unsigned)tryCrc);
  } else {
    fprintf(stderr, "pocketdex: WIDE miss dump=%08x\n", (unsigned)crc);
  }
  if (g.wideOk && !g.wide) {
    g.wide = calloc((size_t)PK_WIDE_MAX_VIEW_W * (size_t)PK_WIDE_MAX_VIEW_H, sizeof(color_t));
    if (!g.wide) g.wideOk = 0;
  }
}

static void set_rom_name_locked(const char *rom_path) {
  g.romName[0] = 0;
  if (!rom_path) return;
  const char *base = strrchr(rom_path, '/');
  base = base ? base + 1 : rom_path;
  snprintf(g.romName, sizeof(g.romName), "%s", base);
}

bool pk_ios_init(const char *rom_path, const char *save_path) {
  if (!rom_path) return false;

  pthread_mutex_lock(&g_lock);
  teardown_locked();
  set_rom_name_locked(rom_path);
  mLogSetDefaultLogger(&g_logger);

  if (path_is_nds(rom_path)) {
    color_t *stack = calloc((size_t)kNdsStackPixels, sizeof(color_t));
    if (!stack) {
      pthread_mutex_unlock(&g_lock);
      return false;
    }
    pk_nds_set_allow_jit(0);
    if (!pk_nds_init(rom_path, save_path, PK_IOS_AUDIO_SAMPLE_RATE)) {
      free(stack);
      pthread_mutex_unlock(&g_lock);
      return false;
    }
    pk_nds_set_cpu_boost(true);
    pk_nds_set_draw(true, true);
    /* Soft Expand starts off until Aspect→Expand sets a window (pk_ios_set_wide_view). */
    pk_nds_wide_enable(false);
    pk_nds_set_expand_compose(true);
    pk_nds_set_keep_start_menu(true);
    g.nds = 1;
    g.nds_stack = stack;
    g.nds_wide = calloc((size_t)PK_WIDE_MAX_VIEW_W * (size_t)PK_WIDE_MAX_VIEW_H, sizeof(color_t));
    g.nds_wide_on = 0;
    g.wideOk = g.nds_wide ? 1 : 0; /* melonDS Soft Expand when buffer allocated */
    g.vw = (unsigned)PK_NDS_W;
    g.vh = (unsigned)PK_NDS_H;
    nds_present_locked();
    audio_ring_clear();
    configure_audio_rates_locked();
    fprintf(stderr, "pocketdex: DS up (interpreter, Soft Expand ready)\n");
    pthread_mutex_unlock(&g_lock);
    return true;
  }

  struct VFile *rom = VFileOpen(rom_path, O_RDONLY);
  if (!rom) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }

  struct mCore *core = mCoreFindVF(rom);
  if (!core || !core->init(core)) {
    rom->close(rom);
    if (core) core->deinit(core);
    pthread_mutex_unlock(&g_lock);
    return false;
  }

  mCoreInitConfig(core, NULL);
  /* GB/GBC: without applying this option the core keeps Super Game Boy borders on and
   * reports a 256x224 frame, with the real 160x144 game drawn in its top-left corner
   * (small, off-centre picture; zoom math also sized for 256x224). Setting the config
   * value alone does nothing — it has to be reloaded into the core, as upstream does. */
  mCoreConfigSetIntValue(&core->config, "sgb.borders", 0);
  if (core->platform(core) == mPLATFORM_GB) {
    core->reloadConfigOption(core, "sgb.borders", &core->config);
  }

  unsigned w = 0, h = 0;
  core->desiredVideoDimensions(core, &w, &h);
  color_t *video = calloc((size_t)w * h, sizeof(color_t));
  if (!video) {
    rom->close(rom);
    core->deinit(core);
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  core->setVideoBuffer(core, video, w);
  core->setAudioBufferSize(core, 2048);

  if (!core->loadROM(core, rom)) {
    rom->close(rom);
    core->deinit(core);
    free(video);
    pthread_mutex_unlock(&g_lock);
    return false;
  }

  if (save_path) {
    struct VFile *saveVf = VFileOpen(save_path, O_RDWR | O_CREAT);
    if (!saveVf) saveVf = VFileOpen(save_path, O_RDONLY);
    if (saveVf) {
      core->loadSave(core, saveVf);
      g.saveVf = saveVf;
    }
  }

  core->reset(core);
  g.core = core;
  g.video = video;
  g.vw = w;
  g.vh = h;
  g.present = video;
  g.presentW = (int)w;
  g.presentH = (int)h;
  configure_wide_locked();
  configure_audio_rates_locked();
  audio_ring_clear();
  pthread_mutex_unlock(&g_lock);
  return true;
}

void pk_ios_deinit(void) {
  pthread_mutex_lock(&g_lock);
  teardown_locked();
  pthread_mutex_unlock(&g_lock);
}

bool pk_ios_is_running(void) {
  pthread_mutex_lock(&g_lock);
  bool ok = g.nds || g.core != NULL;
  pthread_mutex_unlock(&g_lock);
  return ok;
}

void pk_ios_set_keys(uint32_t mask) {
  pthread_mutex_lock(&g_lock);
  if (g.nds) pk_nds_set_keys(mask);
  else if (g.core) g.core->setKeys(g.core, mask);
  pthread_mutex_unlock(&g_lock);
}

void pk_ios_set_touch(bool down, int x, int y) {
  pthread_mutex_lock(&g_lock);
  if (g.nds) pk_nds_touch(down, x, y);
  pthread_mutex_unlock(&g_lock);
}

int pk_ios_nds_field_bits(void) {
  pthread_mutex_lock(&g_lock);
  int bits = g.nds ? pk_nds_field_bits() : 0;
  pthread_mutex_unlock(&g_lock);
  return bits;
}

void pk_ios_nds_set_keep_start_menu(bool on) {
  pthread_mutex_lock(&g_lock);
  if (g.nds) pk_nds_set_keep_start_menu(on);
  pthread_mutex_unlock(&g_lock);
}

bool pk_ios_save_state(const char *path) {
  if (!path) return false;
  pthread_mutex_lock(&g_lock);
  if (g.nds) {
    bool ok = pk_nds_save_state(path);
    pthread_mutex_unlock(&g_lock);
    return ok;
  }
  if (!g.core) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  struct VFile *vf = VFileOpen(path, O_CREAT | O_TRUNC | O_RDWR);
  if (!vf) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  bool ok = mCoreSaveStateNamed(g.core, vf, SAVESTATE_ALL);
  vf->close(vf);
  pthread_mutex_unlock(&g_lock);
  return ok;
}

bool pk_ios_load_state(const char *path) {
  if (!path) return false;
  pthread_mutex_lock(&g_lock);
  if (g.nds) {
    bool ok = pk_nds_load_state(path);
    if (ok) nds_present_locked();
    pthread_mutex_unlock(&g_lock);
    return ok;
  }
  if (!g.core) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  struct VFile *vf = VFileOpen(path, O_RDONLY);
  if (!vf) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  bool ok = mCoreLoadStateNamed(g.core, vf, SAVESTATE_ALL);
  vf->close(vf);
  if (ok && g.wideOk && is_gb_locked() && g.video) {
    /* A state load is a cut to another moment: drop the map match from before it, keep the
     * RAM as the next frame's history and show the next scene at once rather than fading it in
     * (v1.5.1's pk_wide_jump, for the Game Boy rebuild). */
    pk_wide_reset();
    pk_wide_skip(g.core, (const uint32_t *)g.video);
    pk_wide_gb_snap();
  }
  pthread_mutex_unlock(&g_lock);
  return ok;
}

void pk_ios_run_frame_present(bool keep_audio, bool present_video) {
  pthread_mutex_lock(&g_lock);
  /* GB/GBA: fixed blip rate (display-ratio already matches ~59.7→60). DRC
   * retuning every few frames caused crackle and stole time from Expand. */
  if (keep_audio && g.nds) audio_rate_control_locked();
  if (g.nds) {
    /* Fast-forward: skipped frames use draw=false but drawNext MUST stay true so
     * SoftRenderer still prepares the next frame's 3D. present_video=false/false
     * left SkipDrawNext set and the shown FF frame never converted — LCD froze.
     * Soft Expand: skip compose on audio catch-up / unseen frames — reuse last buffer. */
    pk_nds_set_draw(present_video, true);
    pk_nds_set_expand_compose(present_video && g.nds_wide_on);
    pk_nds_run_frame();
    nds_drain_audio_locked(keep_audio);
    if (present_video && (keep_audio || pk_nds_frame_drawn())) nds_present_locked();
  } else if (g.core) {
    g.core->runFrame(g.core);
    drain_audio_locked(keep_audio);
    if (present_video) {
      g.present = g.video;
      g.presentW = (int)g.vw;
      g.presentH = (int)g.vh;
      if (g.wideOk && g.wide && g.wideW > 0 && g.wideH > 0 &&
          g.wideW <= PK_WIDE_MAX_VIEW_W && g.wideH <= PK_WIDE_MAX_VIEW_H &&
          sizeof(color_t) == 4) {
        struct PkWideView v = { g.wideX, g.wideY, g.wideW, g.wideH };
        /* pk_wide_view is the guarded entry for both consoles: a fault while drawing switches
         * EXPAND off for this game instead of taking the app down. */
        int ok = pk_wide_view(g.core, (const uint32_t *)g.video, (uint32_t *)g.wide, v, NULL);
        if (pk_wide_fault()) {
          g.wideOk = 0;
        } else if (ok || is_gb_locked()) {
          /* Game Boy: always show the window, as PokeDaisy does. Off the map (a battle, a menu
           * screen) it is the game's frame with bars in the screen's own background colour, so
           * the zoom eases in and out instead of cutting to a letterboxed frame mid-motion.
           * GBA keeps this port's earlier behaviour: the plain frame while nothing is drawn. */
          g.present = g.wide;
          g.presentW = g.wideW;
          g.presentH = g.wideH;
        }
      }
    }
  }
  pthread_mutex_unlock(&g_lock);
}

void pk_ios_run_frame_ex(bool keep_audio) {
  pk_ios_run_frame_present(keep_audio, true);
}

void pk_ios_run_frame(void) {
  pk_ios_run_frame_ex(true);
}

int pk_ios_audio_queued(void) {
  pthread_mutex_lock(&g_audio_lock);
  int n = (int)g.ring_count;
  pthread_mutex_unlock(&g_audio_lock);
  return n;
}

int pk_ios_audio_target(void) {
  return (int)audio_target_frames();
}

int pk_ios_video_width(void) { return g.presentW > 0 ? g.presentW : (int)g.vw; }
int pk_ios_video_height(void) { return g.presentH > 0 ? g.presentH : (int)g.vh; }

const uint32_t *pk_ios_video_buffer(void) {
  return (const uint32_t *)(g.present ? g.present : g.video);
}

void pk_ios_set_wide_view(int x, int y, int w, int h) {
  pthread_mutex_lock(&g_lock);
  if (w <= 0 || h <= 0) {
    g.wideX = g.wideY = g.wideW = g.wideH = 0;
    if (g.nds && g.nds_wide_on) {
      pk_nds_wide_enable(false);
      g.nds_wide_on = 0;
    }
  } else {
    if (w > PK_WIDE_MAX_VIEW_W) w = PK_WIDE_MAX_VIEW_W;
    if (h > PK_WIDE_MAX_VIEW_H) h = PK_WIDE_MAX_VIEW_H;
    g.wideX = x;
    g.wideY = y;
    g.wideW = w;
    g.wideH = h;
    if (g.nds) {
      if (!g.nds_wide_on) {
        pk_nds_wide_enable(true);
        g.nds_wide_on = 1;
      }
      pk_nds_wide_window(x, y, w, h);
    }
  }
  pthread_mutex_unlock(&g_lock);
}

bool pk_ios_wide_supported(void) {
  pthread_mutex_lock(&g_lock);
  bool ok = g.wideOk != 0;
  pthread_mutex_unlock(&g_lock);
  return ok;
}

int pk_ios_wide_scene(void) {
  pthread_mutex_lock(&g_lock);
  int s = -1;
  if (g.nds) {
    s = pk_nds_wide_scene();
  } else if (g.wideOk && g.core) {
    s = pk_wide_scene(); /* a Game Boy game's comes from pk_wide_gb.c */
  }
  pthread_mutex_unlock(&g_lock);
  return s;
}

bool pk_ios_wide_wants_close(void) {
  pthread_mutex_lock(&g_lock);
  bool close = false;
  if (g.nds) {
    /* SCENE_OFF (4) = battle / no map; SCENE_MENU (6) = menu over field. */
    int s = pk_nds_wide_scene();
    close = (s == 4 || s == 6);
  } else if (g.wideOk && g.core) {
    close = pk_wide_wants_close() != 0;
  }
  pthread_mutex_unlock(&g_lock);
  return close;
}

int pk_ios_core_width(void) {
  if (g.nds) return PK_NDS_W;
  return (int)g.vw;
}
int pk_ios_core_height(void) {
  if (g.nds) return PK_NDS_H;
  return (int)g.vh;
}

bool pk_ios_nds_bottom_rgba(uint32_t *out_256x192) {
  if (!out_256x192) return false;
  pthread_mutex_lock(&g_lock);
  if (!g.nds || !g.nds_stack) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  memcpy(out_256x192, g.nds_stack + PK_NDS_W * PK_NDS_H,
         (size_t)PK_NDS_W * PK_NDS_H * sizeof(uint32_t));
  pthread_mutex_unlock(&g_lock);
  return true;
}

void pk_ios_set_output_sample_rate(double hz) {
  if (hz < 8000.0 || hz > 192000.0) return;
  pthread_mutex_lock(&g_lock);
  g.output_hz = hz;
  configure_audio_rates_locked();
  pthread_mutex_unlock(&g_lock);
}

int pk_ios_audio_render(int16_t *out, int max_frames) {
  if (!out || max_frames <= 0) return 0;
  pthread_mutex_lock(&g_audio_lock);
  int written = 0;
  int16_t last_l = 0, last_r = 0;
  while (written < max_frames && g.ring_count > 0) {
    size_t o = g.ring_r * 2;
    last_l = g.ring[o];
    last_r = g.ring[o + 1];
    out[written * 2] = last_l;
    out[written * 2 + 1] = last_r;
    g.ring_r = (g.ring_r + 1) % kAudioRingFrames;
    g.ring_count--;
    written++;
  }
  int hold = g.nds; /* peek without g_lock — nds flag is stable while a core is up */
  pthread_mutex_unlock(&g_audio_lock);
  /* DS: hold last sample on underrun (less scratchy). GB/GBA: silence — holding
   * sounded like crackle when Expand present lagged. */
  while (written < max_frames) {
    out[written * 2] = hold ? last_l : 0;
    out[written * 2 + 1] = hold ? last_r : 0;
    written++;
  }
  return written;
}

/* Bulk read with g_lock already held. Uses aligned 32-bit reads for the middle
 * of the span (GBA views mask the low address bits, so only aligned reads are
 * word-wide), 8-bit reads for the unaligned head / tail. Host is little-endian. */
static void read_into_locked(uint32_t addr, uint8_t *dst, int len) {
  struct mCore *core = g.core;
  int i = 0;
  while (i < len && ((addr + (uint32_t)i) & 3u) != 0) {
    dst[i] = (uint8_t)core->rawRead8(core, addr + (uint32_t)i, 0);
    i++;
  }
  while (i + 4 <= len) {
    uint32_t w = core->rawRead32(core, addr + (uint32_t)i, 0);
    dst[i] = (uint8_t)(w & 0xFF);
    dst[i + 1] = (uint8_t)((w >> 8) & 0xFF);
    dst[i + 2] = (uint8_t)((w >> 16) & 0xFF);
    dst[i + 3] = (uint8_t)((w >> 24) & 0xFF);
    i += 4;
  }
  while (i < len) {
    dst[i] = (uint8_t)core->rawRead8(core, addr + (uint32_t)i, 0);
    i++;
  }
}

/* GBC WRAM bank B at D000–DFFF via (B << 16) | addr — Crystal switches SVBK mid-frame
 * so a plain bus peek of 0xDxxx can miss bank 1 (PokeDaisy pk_gb_read_banked / Gen2 wramx). */
static bool pk_gb_read_banked(struct mCore *core, uint32_t addr, uint8_t *dst, int len) {
  if (addr < 0x10000u || core->platform(core) != mPLATFORM_GB) {
    return false;
  }
  struct GB *gb = (struct GB *)core->board;
  uint32_t bank = addr >> 16;
  uint32_t off = addr & 0xFFFFu;
  if (bank > 7 || off < 0xD000u || off + (uint32_t)len > 0xE000u || !gb->memory.wram) {
    memset(dst, 0, (size_t)len);
  } else {
    memcpy(dst, gb->memory.wram + bank * GB_SIZE_WORKING_RAM_BANK0 + (off - 0xD000u), (size_t)len);
  }
  return true;
}

bool pk_ios_read_into(uint32_t addr, uint8_t *dst, int len) {
  if (!dst || len <= 0) return false;
  pthread_mutex_lock(&g_lock);
  if (g.nds) {
    pk_nds_read(addr, dst, len);
    pthread_mutex_unlock(&g_lock);
    return true;
  }
  if (!g.core) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  if (pk_gb_read_banked(g.core, addr, dst, len)) {
    pthread_mutex_unlock(&g_lock);
    return true;
  }
  read_into_locked(addr, dst, len);
  pthread_mutex_unlock(&g_lock);
  return true;
}

bool pk_ios_read_bytes(uint32_t addr, uint8_t *dst, int len) {
  return pk_ios_read_into(addr, dst, len);
}

int pk_ios_platform(void) {
  pthread_mutex_lock(&g_lock);
  int p = 0;
  if (g.nds) {
    p = 3;
  } else if (g.core) {
    enum mPlatform plat = g.core->platform(g.core);
    if (plat == mPLATFORM_GBA) p = 1;
    else if (plat == mPLATFORM_GB) p = 2;
  }
  pthread_mutex_unlock(&g_lock);
  return p;
}

bool pk_ios_rom_code(char out[5]) {
  if (!out) return false;
  out[0] = 0;
  pthread_mutex_lock(&g_lock);
  if (g.nds) {
    bool ok = pk_nds_rom_code(out);
    pthread_mutex_unlock(&g_lock);
    return ok;
  }
  if (!g.core || g.core->platform(g.core) != mPLATFORM_GBA) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  /* GBA cart header: game code at 0xAC (ROM mirror 0x08000000). */
  uint8_t buf[4];
  read_into_locked(0x080000ACu, buf, 4);
  pthread_mutex_unlock(&g_lock);
  for (int i = 0; i < 4; i++) {
    uint8_t c = buf[i];
    if (c < 0x20 || c > 0x7E) {
      out[0] = 0;
      return false;
    }
    out[i] = (char)c;
  }
  out[4] = 0;
  return true;
}

bool pk_ios_rom_title(char out[13]) {
  if (!out) return false;
  out[0] = 0;
  pthread_mutex_lock(&g_lock);
  if (!g.core || g.core->platform(g.core) != mPLATFORM_GBA) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  /* GBA cart header: game title at 0xA0 (12 bytes, NUL / space padded). */
  uint8_t buf[12];
  read_into_locked(0x080000A0u, buf, 12);
  pthread_mutex_unlock(&g_lock);
  int n = 0;
  for (int i = 0; i < 12; i++) {
    uint8_t c = buf[i];
    if (c == 0) break;
    out[n++] = (c >= 0x20 && c <= 0x7E) ? (char)c : '?';
  }
  while (n > 0 && out[n - 1] == ' ') n--;
  out[n] = 0;
  return true;
}

bool pk_ios_gb_title(char out[17]) {
  if (!out) return false;
  out[0] = 0;
  pthread_mutex_lock(&g_lock);
  if (!g.core || g.core->platform(g.core) != mPLATFORM_GB) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  /* GB header title at 0x0134 (16 bytes; newer carts shorten for manufacturer). */
  uint8_t buf[16];
  read_into_locked(0x0134u, buf, 16);
  pthread_mutex_unlock(&g_lock);
  int n = 0;
  for (int i = 0; i < 16; i++) {
    uint8_t c = buf[i];
    if (c == 0) break;
    if (c < 0x20 || c > 0x7E) break;
    out[n++] = (char)c;
  }
  while (n > 0 && out[n - 1] == ' ') n--;
  out[n] = 0;
  return n > 0;
}

bool pk_ios_gb_manufacturer(char out[5]) {
  if (!out) return false;
  out[0] = 0;
  pthread_mutex_lock(&g_lock);
  if (!g.core || g.core->platform(g.core) != mPLATFORM_GB) {
    pthread_mutex_unlock(&g_lock);
    return false;
  }
  uint8_t buf[4];
  read_into_locked(0x013Fu, buf, 4);
  pthread_mutex_unlock(&g_lock);
  for (int i = 0; i < 4; i++) {
    uint8_t c = buf[i];
    if (c < 0x20 || c > 0x7E) {
      out[0] = 0;
      return false;
    }
    out[i] = (char)c;
  }
  out[4] = 0;
  return true;
}

int pk_ios_rom_revision(void) {
  pthread_mutex_lock(&g_lock);
  if (g.nds) {
    int rev = pk_nds_rom_revision();
    pthread_mutex_unlock(&g_lock);
    return rev;
  }
  if (!g.core) {
    pthread_mutex_unlock(&g_lock);
    return -1;
  }
  /* GBA cart header: software version at 0xBC. */
  uint8_t v = 0;
  read_into_locked(0x080000BCu, &v, 1);
  pthread_mutex_unlock(&g_lock);
  return (int)v;
}

uint32_t pk_ios_rom_size(void) {
  pthread_mutex_lock(&g_lock);
  uint32_t size = 0;
  if (g.nds) {
    size = pk_nds_rom_size();
  } else if (g.core && g.core->platform(g.core) == mPLATFORM_GBA) {
    /* Companion / soft-map need the file size: trimmed dumps (TrashMan) are under 16 MB but
     * mGBA mirrors them into a 32 MB cart window via romSize(). */
    size = gba_pristine_size_locked();
    if (!size && g.core->romSize) size = (uint32_t)g.core->romSize(g.core);
  } else if (g.core && g.core->romSize) {
    size = (uint32_t)g.core->romSize(g.core);
  }
  pthread_mutex_unlock(&g_lock);
  return size;
}

uint32_t pk_ios_rom_crc(void) {
  pthread_mutex_lock(&g_lock);
  uint32_t crc = g.romCrc;
  pthread_mutex_unlock(&g_lock);
  return crc;
}
