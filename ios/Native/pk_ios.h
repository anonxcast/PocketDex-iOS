#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Output sample rate for pulled stereo PCM (Hz). */
#define PK_IOS_AUDIO_SAMPLE_RATE 48000

/**
 * Tell the core the AVAudioSession's actual output rate (may be 44100 even when
 * 48000 was preferred). Blip / NDS resampling track this so pitch stays correct.
 */
void pk_ios_set_output_sample_rate(double hz);

/**
 * Call once at app launch (before any DS ROM). Sets CS_DEBUGGED via ptrace(PT_TRACE_ME)
 * and probes W^X mprotect so melonDS A64 JIT can run at 60 FPS. Safe if already prepared.
 */
void pk_ios_prepare_jit(void);
/** 1 if prepare_jit succeeded (JIT will be used for DS). */
int pk_ios_jit_ready(void);

/** Init mGBA or melonDS from a local ROM path. Optional save path may be NULL. */
bool pk_ios_init(const char *rom_path, const char *save_path);
void pk_ios_deinit(void);
bool pk_ios_is_running(void);

/** Instant save / load state to a file path (mGBA or melonDS serialized state). */
bool pk_ios_save_state(const char *path);
bool pk_ios_load_state(const char *path);

void pk_ios_set_keys(uint32_t mask);
/** Stylus on the DS bottom screen (ignored for GB/GBC/GBA). Coords in DS pixels 0..255 / 0..191. */
void pk_ios_set_touch(bool down, int x, int y);
/**
 * DS LAYOUT one-screen: PK_NDS_FIELD_* bits from the last frame (0 if not NDS).
 * Includes PK_NDS_FIELD_TOUCH when the game wants its touch screen floated in.
 */
int pk_ios_nds_field_bits(void);
/** Keep HG/SS X menu after a touch-closed menu screen (PokeDaisy ONE SCREEN). */
void pk_ios_nds_set_keep_start_menu(bool on);
void pk_ios_run_frame(void);
/**
 * Run one frame. When keep_audio is false, core audio is drained and discarded
 * (used for fast-forward so only ~1× samples reach the ring at normal pitch).
 */
void pk_ios_run_frame_ex(bool keep_audio);
/**
 * Run one frame. `keep_audio` as above. When `present_video` is false, skip LCD
 * convert / Expand compose (DS audio catch-up without the present tax).
 */
void pk_ios_run_frame_present(bool keep_audio, bool present_video);
/** Frames waiting in the audio ring (for catch-up pacing). */
int pk_ios_audio_queued(void);
/** Soft target ring depth for the current platform. */
int pk_ios_audio_target(void);

int pk_ios_video_width(void);
int pk_ios_video_height(void);
/** Present buffer (core frame, or WIDE/EXPAND window). Length = width * height. */
const uint32_t *pk_ios_video_buffer(void);

/**
 * PokeDaisy WIDE / EXPAND: rebuild map past the GBA/GB frame into a window of size (w×h)
 * whose top-left is (x,y) in game pixels ((0,0) = frame top-left; x/y may be negative).
 * Pass w=0 to disable and show the plain core frame. Call from the emu thread / before frames.
 */
void pk_ios_set_wide_view(int x, int y, int w, int h);
/** Whether Expand/WIDE works (GBA/GB table, or NDS melonDS EXPAND). */
bool pk_ios_wide_supported(void);
/** Last frame's pk_wide_scene() (FIELD=0 … MENU=6); -1 if WIDE off. */
int pk_ios_wide_scene(void);
/** Whether the last frame wants a close-up (battle / menu / text). */
bool pk_ios_wide_wants_close(void);
/** Core frame size in game pixels (240×160 GBA, 160×144 GB, 256×192 NDS top LCD). */
int pk_ios_core_width(void);
int pk_ios_core_height(void);
/**
 * NDS native touch LCD (256×192 RGBA), always available while melonDS is running —
 * used when Expand presents a wide top buffer instead of the stacked 256×384 frame.
 */
bool pk_ios_nds_bottom_rgba(uint32_t *out_256x192);

/**
 * Copy interleaved stereo S16 PCM into out (L,R,L,R…).
 * Returns frames filled (always max_frames). Underrun writes silence.
 */
int pk_ios_audio_render(int16_t *out, int max_frames);

/** Read guest memory for companion (GBA bus). Returns false if unavailable. */
bool pk_ios_read_bytes(uint32_t addr, uint8_t *dst, int len);

/** Bulk guest read (same as pk_ios_read_bytes; word-wide where aligned). Thread-safe. */
bool pk_ios_read_into(uint32_t addr, uint8_t *dst, int len);

/** 0 = none, 1 = GBA, 2 = GB/GBC (mGBA), 3 = NDS (melonDS). */
int pk_ios_platform(void);

/** GBA cart header game code at 0xAC (4 ASCII chars + NUL, e.g. "BPEE"). False if no core / not printable. */
bool pk_ios_rom_code(char out[5]);
/** GBA cart header title at 0xA0 (up to 12 chars + NUL, trailing spaces trimmed). */
bool pk_ios_rom_title(char out[13]);
/** GB/GBC cart title at 0x134 (up to 16 chars + NUL). False if not a GB core. */
bool pk_ios_gb_title(char out[17]);
/** GB/GBC manufacturer / game code at 0x13F (up to 4 chars + NUL), when present. */
bool pk_ios_gb_manufacturer(char out[5]);
/** GBA cart header software version byte at 0xBC (FireRed rev 0 = 0, rev 1 = 1); -1 if no core. */
int pk_ios_rom_revision(void);
/** Loaded ROM size in bytes (0 if unknown). */
uint32_t pk_ios_rom_size(void);
/** mGBA dump CRC32 used for WIDE lookup (0 if none). Soft-map may configure a different retail CRC. */
uint32_t pk_ios_rom_crc(void);

/** GBA key bitmask bits (mGBA / PocketDex convention). */
#define PK_KEY_A      ((uint32_t)(1u << 0))
#define PK_KEY_B      ((uint32_t)(1u << 1))
#define PK_KEY_SELECT ((uint32_t)(1u << 2))
#define PK_KEY_START  ((uint32_t)(1u << 3))
#define PK_KEY_RIGHT  ((uint32_t)(1u << 4))
#define PK_KEY_LEFT   ((uint32_t)(1u << 5))
#define PK_KEY_UP     ((uint32_t)(1u << 6))
#define PK_KEY_DOWN   ((uint32_t)(1u << 7))
#define PK_KEY_R      ((uint32_t)(1u << 8))
#define PK_KEY_L      ((uint32_t)(1u << 9))
/** Nintendo DS face buttons (melonDS / pk_nds). */
#define PK_KEY_X      ((uint32_t)(1u << 10))
#define PK_KEY_Y      ((uint32_t)(1u << 11))

#ifdef __cplusplus
}
#endif
