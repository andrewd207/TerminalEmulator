/*
 * termview.h — C ABI for the TerminalEmulator core.
 *
 * Wraps a Free Pascal TTerminalController + TTerminalCore so any C host
 * can drive a PTY and render the cell grid. Paint is the caller's job.
 *
 * Copyright (c) 2026 Andrew Haines
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef TERMVIEW_H
#define TERMVIEW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle. */
typedef struct tv_handle tv_handle;

/* Cell attribute bits. Mirror the Pascal TTermAttrFlag set. */
#define TV_ATTR_BOLD        (1u << 0)
#define TV_ATTR_FAINT       (1u << 1)
#define TV_ATTR_ITALIC      (1u << 2)
#define TV_ATTR_UNDERLINE   (1u << 3)
#define TV_ATTR_BLINK       (1u << 4)
#define TV_ATTR_INVERSE     (1u << 5)
#define TV_ATTR_HIDDEN      (1u << 6)
#define TV_ATTR_STRIKE      (1u << 7)
#define TV_ATTR_WIDE_LEAD   (1u << 8)
#define TV_ATTR_WIDE_TRAIL  (1u << 9)

/* Sentinel used in fg_rgb / bg_rgb when the cell uses the terminal's default
 * color (renderer should substitute its palette default). */
#define TV_COLOR_DEFAULT    0xFF000001u

/* HTML export kinds for tv_get_html. */
#define TV_HTML_SELECTION   0
#define TV_HTML_SCREEN      1
#define TV_HTML_ALL         2

/* Mouse buttons for tv_send_mouse. */
#define TV_MOUSE_LEFT       0
#define TV_MOUSE_MIDDLE     1
#define TV_MOUSE_RIGHT      2
#define TV_MOUSE_WHEEL_UP   3
#define TV_MOUSE_WHEEL_DOWN 4

/* Cell snapshot. cluster is a NUL-terminated UTF-8 grapheme (up to 15 bytes
 * of payload). codepoint is the leading code point. */
typedef struct {
    uint32_t codepoint;
    uint32_t fg_rgb;   /* 0x00RRGGBB or TV_COLOR_DEFAULT */
    uint32_t bg_rgb;
    uint32_t flags;    /* TV_ATTR_* bitmask */
    char     cluster[16];
} tv_cell_t;

/* ---- Callbacks ---- */

typedef void (*tv_invalidate_cb)(void *user);
typedef void (*tv_bell_cb)(void *user);
typedef void (*tv_title_cb)(const char *title, void *user);
typedef void (*tv_exit_cb)(void *user);
typedef void (*tv_clip_set_cb)(const char *targets, const char *text,
                               size_t len, void *user);
/* On clipboard-get, the C side must allocate *out_text with malloc and write
 * a NUL-terminated UTF-8 string (or set it to NULL). Pascal will free it. */
typedef void (*tv_clip_get_cb)(const char *targets, char **out_text, void *user);

/* ---- Lifecycle ---- */

tv_handle *tv_controller_new(int cols, int rows, int scrollback);
void       tv_controller_free(tv_handle *h);

int        tv_start_shell(tv_handle *h, const char *shell /* or NULL */);

/* Pull bytes from the PTY into the parser. Returns bytes read this tick.
 * Call from your main-loop timer (≈20ms). */
int        tv_pump(tv_handle *h);

/* Send input bytes to the PTY (raw; bracketed-paste wrapping is the caller's
 * job when appropriate). */
void       tv_send_input(tv_handle *h, const char *data, size_t len);

void       tv_resize(tv_handle *h, int cols, int rows);

/* ---- Queries ---- */

int  tv_cols(tv_handle *h);
int  tv_rows(tv_handle *h);
int  tv_history_count(tv_handle *h);

int  tv_cursor_col(tv_handle *h);
int  tv_cursor_row(tv_handle *h);
int  tv_cursor_visible(tv_handle *h);
int  tv_in_alt_buffer(tv_handle *h);

int  tv_bracketed_paste(tv_handle *h);
int  tv_is_running(tv_handle *h);
int  tv_subprocess_running(tv_handle *h);

/* Row indices below are *virtual*: 0..tv_history_count()-1 reach into
 * scrollback; history_count..history_count+rows-1 cover the screen. */

int  tv_line_wrapped(tv_handle *h, int virtual_row);
int  tv_line_length(tv_handle *h, int virtual_row);
int  tv_get_cell(tv_handle *h, int virtual_row, int col, tv_cell_t *out_cell);

/* ---- Mouse ---- */

void tv_send_mouse(tv_handle *h, int button, int col, int row,
                   int pressed, int motion, int shift, int alt, int ctrl);
/* True when the running app has enabled mouse reporting (?1000/?1002/?1003). */
int  tv_mouse_protocol_active(tv_handle *h);

/* ---- HTML export ----
 *
 * Returns a newly allocated NUL-terminated UTF-8 buffer (or NULL on error).
 * Must be freed with tv_str_free. For TV_HTML_SCREEN / TV_HTML_ALL, the
 * anchor/focus arguments are ignored; for TV_HTML_SELECTION pass the
 * selection's virtual-row/col anchor and focus.
 */
char *tv_get_html(tv_handle *h, int kind, const char *title /* or NULL */,
                  int anchor_row, int anchor_col,
                  int focus_row,  int focus_col);

void  tv_str_free(char *p);

/* ---- Callback registration ---- */

void tv_set_user_data(tv_handle *h, void *user);
void tv_set_on_invalidate(tv_handle *h, tv_invalidate_cb cb);
void tv_set_on_bell(tv_handle *h, tv_bell_cb cb);
void tv_set_on_title(tv_handle *h, tv_title_cb cb);
void tv_set_on_exit(tv_handle *h, tv_exit_cb cb);
void tv_set_on_clipboard_set(tv_handle *h, tv_clip_set_cb cb);
void tv_set_on_clipboard_get(tv_handle *h, tv_clip_get_cb cb);

#ifdef __cplusplus
}
#endif

#endif /* TERMVIEW_H */
