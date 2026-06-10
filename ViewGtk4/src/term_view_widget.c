/*
 * term_view_widget.c — GTK4 TermViewWidget impl.
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "term_view_widget.h"

#include <pango/pangocairo.h>
#include <string.h>
#include <stdlib.h>

#define SETTINGS_GROUP      "appearance"
#define SETTINGS_KEY_FONT   "font-desc"
#define PUMP_INTERVAL_MS    20
#define CURSOR_BLINK_MS     750
#define SELECTION_DRAG_PX   3
#define DEFAULT_FG          0x00D0D0D0u
#define DEFAULT_BG          0x00000000u
#define SELECTION_FG        0x00000000u
#define SELECTION_BG        0x00FFD700u

typedef struct {
    int row;
    int col;
} TermCellPos;

struct _TermViewWidget {
    GtkWidget        parent;

    tv_handle       *tv;
    guint            pump_source;
    guint            cursor_source;
    gboolean         cursor_visible;
    gboolean         shell_exited;

    /* Font metrics. */
    PangoFontDescription *font_desc;
    int              char_w;
    int              char_h;
    int              baseline;

    /* Scroll state — top virtual row currently shown at view y=0. */
    int              top_row;
    GtkAdjustment   *vadjust;

    /* Selection (virtual coords). */
    gboolean         sel_active;
    gboolean         sel_dragging;
    gboolean         sel_pending;
    int              sel_down_x, sel_down_y;
    TermCellPos      sel_anchor, sel_focus;

    /* Input. */
    GtkIMContext    *im;

    /* Mouse-report dedup. */
    int              last_report_col;
    int              last_report_row;

    /* Popover. */
    GtkWidget       *popover;
    GtkWidget       *mi_copy;
    GtkWidget       *mi_paste;
    GtkWidget       *mi_copy_html_sel;
    GtkWidget       *mi_copy_html_screen;
    GtkWidget       *mi_copy_html_all;
    GMenu           *menu_model;

    /* Properties. */
    gboolean         yield_right_click_to_app;
    int              scrollback;
    char            *pending_shell;

    /* For clipboard async ops. */
    GdkClipboard    *clipboard;

    /* For pending clipboard-get (OSC 52 read). */
    char           **pending_clip_out;
    GMainLoop       *clip_loop;
};

enum {
    PROP_0,
    PROP_FONT_DESC,
    PROP_SCROLLBACK,
    PROP_YIELD_RIGHT_CLICK_TO_APP,
    N_PROPS
};
static GParamSpec *props[N_PROPS];

enum {
    SIG_SHELL_EXITED,
    SIG_TITLE_CHANGED,
    SIG_BELL,
    N_SIGS
};
static guint signals[N_SIGS];

static void term_view_widget_scrollable_iface_init(GtkScrollableInterface *iface);

G_DEFINE_FINAL_TYPE_WITH_CODE(TermViewWidget, term_view_widget, GTK_TYPE_WIDGET,
    G_IMPLEMENT_INTERFACE(GTK_TYPE_SCROLLABLE,
                          term_view_widget_scrollable_iface_init))

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

static void update_font_metrics(TermViewWidget *self);
static void update_adjustment(TermViewWidget *self);
static void send_resize_to_tv(TermViewWidget *self);
static void rebuild_popover(TermViewWidget *self);
static void load_settings(TermViewWidget *self);
static void save_settings(TermViewWidget *self);
static char *settings_path(void);

static guint32 cell_fg(uint32_t fg) {
    return (fg == TV_COLOR_DEFAULT) ? DEFAULT_FG : (fg & 0x00FFFFFFu);
}
static guint32 cell_bg(uint32_t bg) {
    return (bg == TV_COLOR_DEFAULT) ? DEFAULT_BG : (bg & 0x00FFFFFFu);
}
static void set_cairo_color(cairo_t *cr, guint32 rgb) {
    cairo_set_source_rgb(cr,
        ((rgb >> 16) & 0xFF) / 255.0,
        ((rgb >>  8) & 0xFF) / 255.0,
        ( rgb        & 0xFF) / 255.0);
}

static int virtual_rows(TermViewWidget *self) {
    if (!self->tv) return 0;
    return tv_history_count(self->tv) + tv_rows(self->tv);
}

static int rows_visible(TermViewWidget *self) {
    int h = gtk_widget_get_height(GTK_WIDGET(self));
    return MAX(1, h / MAX(1, self->char_h));
}

static int cols_visible(TermViewWidget *self) {
    int w = gtk_widget_get_width(GTK_WIDGET(self));
    return MAX(1, w / MAX(1, self->char_w));
}

static void normalize_sel(TermCellPos a, TermCellPos b, TermCellPos *s, TermCellPos *e) {
    if (a.row < b.row || (a.row == b.row && a.col <= b.col)) {
        *s = a; *e = b;
    } else {
        *s = b; *e = a;
    }
}

static gboolean cell_in_selection(TermViewWidget *self, int virt_row, int col) {
    if (!self->sel_active) return FALSE;
    TermCellPos s, e;
    normalize_sel(self->sel_anchor, self->sel_focus, &s, &e);
    if (virt_row < s.row || virt_row > e.row) return FALSE;
    if (s.row == e.row) return col >= s.col && col <= e.col;
    if (virt_row == s.row) return col >= s.col;
    if (virt_row == e.row) return col <= e.col;
    return TRUE;
}

/* ------------------------------------------------------------------ */
/* TV core callbacks                                                  */
/* ------------------------------------------------------------------ */

static void on_tv_invalidate(void *user) {
    TermViewWidget *self = TERM_VIEW_WIDGET(user);
    gtk_widget_queue_draw(GTK_WIDGET(self));
}

static void on_tv_bell(void *user) {
    TermViewWidget *self = TERM_VIEW_WIDGET(user);
    g_signal_emit(self, signals[SIG_BELL], 0);
}

static void on_tv_title(const char *title, void *user) {
    TermViewWidget *self = TERM_VIEW_WIDGET(user);
    g_signal_emit(self, signals[SIG_TITLE_CHANGED], 0, title);
}

static void on_tv_exit(void *user) {
    TermViewWidget *self = TERM_VIEW_WIDGET(user);
    self->shell_exited = TRUE;
    g_signal_emit(self, signals[SIG_SHELL_EXITED], 0);
    gtk_widget_queue_draw(GTK_WIDGET(self));
}

static void on_tv_clip_set(const char *targets G_GNUC_UNUSED,
                           const char *text, size_t len, void *user) {
    TermViewWidget *self = TERM_VIEW_WIDGET(user);
    if (!self->clipboard) return;
    gchar *copy = g_strndup(text, len);
    gdk_clipboard_set_text(self->clipboard, copy);
    g_free(copy);
}

static void clip_read_done(GObject *src, GAsyncResult *res, gpointer ud) {
    TermViewWidget *self = (TermViewWidget *)ud;
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(src), res, NULL);
    if (self->pending_clip_out) {
        *(self->pending_clip_out) = text ? strdup(text) : NULL;
    }
    g_free(text);
    if (self->clip_loop) g_main_loop_quit(self->clip_loop);
}

static void on_tv_clip_get(const char *targets G_GNUC_UNUSED,
                           char **out_text, void *user) {
    TermViewWidget *self = TERM_VIEW_WIDGET(user);
    *out_text = NULL;
    if (!self->clipboard) return;

    /* GdkClipboard is async-only. Spin a nested main loop to wait for the
     * value — this fires from inside the parser (which fires from pump,
     * which runs on the GTK main loop), so re-entry is safe here. */
    self->pending_clip_out = out_text;
    self->clip_loop = g_main_loop_new(NULL, FALSE);
    gdk_clipboard_read_text_async(self->clipboard, NULL, clip_read_done, self);
    g_main_loop_run(self->clip_loop);
    g_main_loop_unref(self->clip_loop);
    self->clip_loop = NULL;
    self->pending_clip_out = NULL;
}

/* ------------------------------------------------------------------ */
/* Pump + cursor timers                                               */
/* ------------------------------------------------------------------ */

static gboolean pump_tick(gpointer ud) {
    TermViewWidget *self = (TermViewWidget *)ud;
    if (!self->tv) return G_SOURCE_CONTINUE;
    int n = tv_pump(self->tv);
    if (n > 0) {
        self->cursor_visible = TRUE;
        update_adjustment(self);
        /* Snap to bottom on new output. */
        if (self->vadjust) {
            double upper = gtk_adjustment_get_upper(self->vadjust);
            double page = gtk_adjustment_get_page_size(self->vadjust);
            gtk_adjustment_set_value(self->vadjust, MAX(0.0, upper - page));
        }
        gtk_widget_queue_draw(GTK_WIDGET(self));
    }
    return G_SOURCE_CONTINUE;
}

static gboolean cursor_tick(gpointer ud) {
    TermViewWidget *self = (TermViewWidget *)ud;
    if (!self->tv) return G_SOURCE_CONTINUE;
    self->cursor_visible = !self->cursor_visible;
    gtk_widget_queue_draw(GTK_WIDGET(self));
    return G_SOURCE_CONTINUE;
}

/* ------------------------------------------------------------------ */
/* Paint                                                              */
/* ------------------------------------------------------------------ */

static void term_view_widget_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    TermViewWidget *self = TERM_VIEW_WIDGET(widget);
    int w = gtk_widget_get_width(widget);
    int h = gtk_widget_get_height(widget);
    if (w <= 0 || h <= 0 || !self->tv) return;

    cairo_t *cr = gtk_snapshot_append_cairo(snapshot,
                    &GRAPHENE_RECT_INIT(0, 0, (float)w, (float)h));

    /* Background. */
    set_cairo_color(cr, DEFAULT_BG);
    cairo_rectangle(cr, 0, 0, w, h);
    cairo_fill(cr);

    PangoLayout *layout = pango_cairo_create_layout(cr);
    pango_layout_set_font_description(layout, self->font_desc);

    int rows = rows_visible(self);
    int cols = cols_visible(self);
    if (tv_in_alt_buffer(self->tv))
        self->top_row = tv_history_count(self->tv);

    int cursor_v_row = tv_history_count(self->tv) + tv_cursor_row(self->tv);
    int cursor_col   = tv_cursor_col(self->tv);
    int cursor_visible_flag = tv_cursor_visible(self->tv) && self->cursor_visible;

    for (int row = 0; row < rows; ++row) {
        int v_row = self->top_row + row;
        if (v_row < 0 || v_row >= virtual_rows(self)) continue;
        int line_len = tv_line_length(self->tv, v_row);
        if (line_len <= 0) continue;
        int last_col = MIN(line_len - 1, cols - 1);

        for (int col = 0; col <= last_col; ++col) {
            tv_cell_t cell;
            if (!tv_get_cell(self->tv, v_row, col, &cell)) continue;
            if (cell.flags & TV_ATTR_WIDE_TRAIL) continue;

            guint32 fg = cell_fg(cell.fg_rgb);
            guint32 bg = cell_bg(cell.bg_rgb);
            if (cell.flags & TV_ATTR_FAINT) {
                fg = (((fg & 0xFE0000) >> 1) |
                      ((fg & 0x00FE00) >> 1) |
                      ((fg & 0x0000FE) >> 1));
            }
            if (cell.flags & TV_ATTR_INVERSE) { guint32 t = fg; fg = bg; bg = t; }
            if (cell.flags & TV_ATTR_HIDDEN)  fg = bg;

            gboolean hosts_cursor = cursor_visible_flag
                && (v_row == cursor_v_row) && (col == cursor_col);

            gboolean selected = cell_in_selection(self, v_row, col);
            if (selected) { fg = SELECTION_FG; bg = SELECTION_BG; }
            if (hosts_cursor) { guint32 t = fg; fg = bg; bg = t; }

            int cw = (cell.flags & TV_ATTR_WIDE_LEAD) ? self->char_w * 2 : self->char_w;
            int x = col * self->char_w;
            int y = row * self->char_h;

            set_cairo_color(cr, bg);
            cairo_rectangle(cr, x, y, cw, self->char_h);
            cairo_fill(cr);

            if (cell.flags & TV_ATTR_BLINK && !self->cursor_visible) continue;
            if (cell.cluster[0] == 0) continue;

            /* Build a Pango markup for bold/italic/underline/strike. */
            PangoAttrList *attrs = pango_attr_list_new();
            if (cell.flags & TV_ATTR_BOLD)
                pango_attr_list_insert(attrs, pango_attr_weight_new(PANGO_WEIGHT_BOLD));
            if (cell.flags & TV_ATTR_ITALIC)
                pango_attr_list_insert(attrs, pango_attr_style_new(PANGO_STYLE_ITALIC));
            if (cell.flags & TV_ATTR_UNDERLINE)
                pango_attr_list_insert(attrs, pango_attr_underline_new(PANGO_UNDERLINE_SINGLE));
            if (cell.flags & TV_ATTR_STRIKE)
                pango_attr_list_insert(attrs, pango_attr_strikethrough_new(TRUE));
            pango_layout_set_attributes(layout, attrs);
            pango_attr_list_unref(attrs);

            pango_layout_set_text(layout, cell.cluster, -1);
            set_cairo_color(cr, fg);
            cairo_move_to(cr, x, y);
            pango_cairo_show_layout(cr, layout);
        }
    }

    /* Underscore cursor (block-style is already covered by inverse swap). */
    /* No explicit underscore for now; block cursor is handled above. */

    g_object_unref(layout);
    cairo_destroy(cr);
}

/* ------------------------------------------------------------------ */
/* Size                                                               */
/* ------------------------------------------------------------------ */

static void term_view_widget_measure(GtkWidget *widget, GtkOrientation orient,
                                     int for_size G_GNUC_UNUSED,
                                     int *minimum, int *natural,
                                     int *minimum_baseline, int *natural_baseline) {
    TermViewWidget *self = TERM_VIEW_WIDGET(widget);
    if (orient == GTK_ORIENTATION_HORIZONTAL) {
        *minimum = self->char_w * 20;
        *natural = self->char_w * 80;
    } else {
        *minimum = self->char_h * 5;
        *natural = self->char_h * 24;
    }
    *minimum_baseline = -1;
    *natural_baseline = -1;
}

static void term_view_widget_size_allocate(GtkWidget *widget,
                                           int width G_GNUC_UNUSED,
                                           int height G_GNUC_UNUSED,
                                           int baseline G_GNUC_UNUSED) {
    TermViewWidget *self = TERM_VIEW_WIDGET(widget);
    send_resize_to_tv(self);
    /* If the popover is open during a resize, GTK will reposition it for us;
       calling gtk_popover_present from here when it isn't visible triggers
       "Broken accounting of active state" warnings. */
    if (self->popover && gtk_widget_get_visible(self->popover))
        gtk_popover_present(GTK_POPOVER(self->popover));
    update_adjustment(self);
}

static void send_resize_to_tv(TermViewWidget *self) {
    if (!self->tv) return;
    int w = gtk_widget_get_width(GTK_WIDGET(self));
    int h = gtk_widget_get_height(GTK_WIDGET(self));
    int cols = MAX(1, w / MAX(1, self->char_w));
    int rows = MAX(1, h / MAX(1, self->char_h));
    tv_resize(self->tv, cols, rows);
}

/* ------------------------------------------------------------------ */
/* Font metrics                                                       */
/* ------------------------------------------------------------------ */

static void update_font_metrics(TermViewWidget *self) {
    PangoContext *pc = gtk_widget_get_pango_context(GTK_WIDGET(self));
    PangoFontMetrics *m = pango_context_get_metrics(pc, self->font_desc, NULL);
    self->char_w = pango_font_metrics_get_approximate_char_width(m) / PANGO_SCALE;
    self->char_h = (pango_font_metrics_get_ascent(m) + pango_font_metrics_get_descent(m))
                   / PANGO_SCALE;
    self->baseline = pango_font_metrics_get_ascent(m) / PANGO_SCALE;
    if (self->char_w <= 0) self->char_w = 8;
    if (self->char_h <= 0) self->char_h = 12;
    pango_font_metrics_unref(m);
}

/* ------------------------------------------------------------------ */
/* Scrollable interface                                               */
/* ------------------------------------------------------------------ */

static void on_vadjust_value_changed(GtkAdjustment *adj, gpointer ud) {
    TermViewWidget *self = (TermViewWidget *)ud;
    self->top_row = (int)gtk_adjustment_get_value(adj);
    gtk_widget_queue_draw(GTK_WIDGET(self));
}

static void update_adjustment(TermViewWidget *self) {
    if (!self->vadjust || !self->tv) return;
    int total = virtual_rows(self);
    int page = rows_visible(self);
    gtk_adjustment_configure(self->vadjust,
        gtk_adjustment_get_value(self->vadjust),
        0.0, (double)total,
        1.0, (double)page, (double)page);
    /* Clamp value if rows shrank. */
    double v = gtk_adjustment_get_value(self->vadjust);
    double upper = gtk_adjustment_get_upper(self->vadjust);
    double ps = gtk_adjustment_get_page_size(self->vadjust);
    if (v > upper - ps) gtk_adjustment_set_value(self->vadjust, MAX(0.0, upper - ps));
}

static void set_vadjustment(TermViewWidget *self, GtkAdjustment *adj) {
    if (self->vadjust == adj) return;
    if (self->vadjust) {
        g_signal_handlers_disconnect_by_func(self->vadjust,
            G_CALLBACK(on_vadjust_value_changed), self);
        g_object_unref(self->vadjust);
    }
    self->vadjust = adj ? g_object_ref(adj) : gtk_adjustment_new(0, 0, 0, 1, 1, 1);
    g_signal_connect(self->vadjust, "value-changed",
                     G_CALLBACK(on_vadjust_value_changed), self);
    update_adjustment(self);
}

/* GtkScrollable property getters/setters are wired below in get/set_property
 * with the standard interface property names. */

static void term_view_widget_scrollable_iface_init(GtkScrollableInterface *iface G_GNUC_UNUSED) {
    /* No methods to override — properties below handle it. */
}

/* ------------------------------------------------------------------ */
/* Selection helpers                                                  */
/* ------------------------------------------------------------------ */

static TermCellPos pixel_to_cell(TermViewWidget *self, double x, double y) {
    TermCellPos p;
    if (self->char_w <= 0) self->char_w = 1;
    if (self->char_h <= 0) self->char_h = 1;
    int cv = cols_visible(self);
    int rv = rows_visible(self);
    int col = (int)(x / self->char_w);
    int row = (int)(y / self->char_h);
    if (col < 0) col = 0;
    if (col > cv - 1) col = cv - 1;
    if (row < 0) row = 0;
    if (row > rv - 1) row = rv - 1;
    p.col = col;
    p.row = self->top_row + row;
    return p;
}

static char *selection_as_text(TermViewWidget *self) {
    if (!self->sel_active || !self->tv) return NULL;
    TermCellPos s, e;
    normalize_sel(self->sel_anchor, self->sel_focus, &s, &e);
    GString *out = g_string_new(NULL);
    for (int r = s.row; r <= e.row; ++r) {
        int len = tv_line_length(self->tv, r);
        if (len <= 0) {
            if (r != e.row) g_string_append_c(out, '\n');
            continue;
        }
        int start = (r == s.row) ? s.col : 0;
        int end   = (r == e.row) ? MIN(e.col, len - 1) : len - 1;
        /* trim trailing spaces on non-last rows */
        if (r != e.row) {
            int last_real = end;
            while (last_real >= start) {
                tv_cell_t c;
                tv_get_cell(self->tv, r, last_real, &c);
                if (c.flags & TV_ATTR_WIDE_TRAIL) { last_real--; continue; }
                if (c.cluster[0] != 0 && !(c.cluster[0] == ' ' && c.cluster[1] == 0)) break;
                last_real--;
            }
            end = last_real;
        }
        for (int c = start; c <= end; ++c) {
            tv_cell_t cell;
            if (!tv_get_cell(self->tv, r, c, &cell)) continue;
            if (cell.flags & TV_ATTR_WIDE_TRAIL) continue;
            if (cell.cluster[0])
                g_string_append(out, cell.cluster);
            else
                g_string_append_c(out, ' ');
        }
        if (r != e.row) g_string_append_c(out, '\n');
    }
    return g_string_free(out, FALSE);
}

/* ------------------------------------------------------------------ */
/* Popover                                                            */
/* ------------------------------------------------------------------ */

static const char *snapshot_title(TermViewWidget *self) {
    GtkRoot *root = gtk_widget_get_root(GTK_WIDGET(self));
    if (GTK_IS_WINDOW(root))
        return gtk_window_get_title(GTK_WINDOW(root));
    return NULL;
}

static void copy_html_to_clipboard(TermViewWidget *self, int kind) {
    if (!self->tv || !self->clipboard) return;
    int ar = self->sel_anchor.row, ac = self->sel_anchor.col;
    int fr = self->sel_focus.row,  fc = self->sel_focus.col;
    char *html = tv_get_html(self->tv, kind, snapshot_title(self), ar, ac, fr, fc);
    if (!html) return;
    gdk_clipboard_set_text(self->clipboard, html);
    tv_str_free(html);
}

static void on_action_copy(GSimpleAction *a G_GNUC_UNUSED, GVariant *p G_GNUC_UNUSED, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    if (self->sel_active) {
        char *txt = selection_as_text(self);
        if (txt) {
            gdk_clipboard_set_text(self->clipboard, txt);
            g_free(txt);
        }
    } else if (self->tv && tv_bracketed_paste(self->tv)) {
        tv_send_input(self->tv, "\x1b[99;6u", 7);
    }
}

static void paste_text_done(GObject *src, GAsyncResult *res, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(src), res, NULL);
    if (!self->tv) { g_free(text); return; }
    if (!text || !*text) {
        g_free(text);
        if (!tv_bracketed_paste(self->tv))
            tv_send_input(self->tv, "\x1b[86;6u", 7);
        return;
    }
    /* Normalize line endings. */
    char *nl = text;
    GString *s = g_string_new(NULL);
    while (*nl) {
        if (nl[0] == '\r' && nl[1] == '\n') { g_string_append_c(s, '\n'); nl += 2; }
        else if (*nl == '\r') { g_string_append_c(s, '\n'); nl++; }
        else { g_string_append_c(s, *nl); nl++; }
    }
    if (tv_bracketed_paste(self->tv)) {
        tv_send_input(self->tv, "\x1b[200~", 6);
        tv_send_input(self->tv, s->str, s->len);
        tv_send_input(self->tv, "\x1b[201~", 6);
    } else {
        tv_send_input(self->tv, "\x1b[86;6u", 7);
    }
    g_string_free(s, TRUE);
    g_free(text);
}

static void on_action_paste(GSimpleAction *a G_GNUC_UNUSED, GVariant *p G_GNUC_UNUSED, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    if (!self->clipboard || !self->tv) return;
    gdk_clipboard_read_text_async(self->clipboard, NULL, paste_text_done, self);
}

static void on_action_copy_html_sel(GSimpleAction *a G_GNUC_UNUSED, GVariant *p G_GNUC_UNUSED, gpointer ud) {
    copy_html_to_clipboard(TERM_VIEW_WIDGET(ud), TV_HTML_SELECTION);
}
static void on_action_copy_html_screen(GSimpleAction *a G_GNUC_UNUSED, GVariant *p G_GNUC_UNUSED, gpointer ud) {
    copy_html_to_clipboard(TERM_VIEW_WIDGET(ud), TV_HTML_SCREEN);
}
static void on_action_copy_html_all(GSimpleAction *a G_GNUC_UNUSED, GVariant *p G_GNUC_UNUSED, gpointer ud) {
    copy_html_to_clipboard(TERM_VIEW_WIDGET(ud), TV_HTML_ALL);
}

static char *settings_path(void) {
    return g_build_filename(g_get_user_config_dir(), "termview", "config.ini", NULL);
}

static void load_settings(TermViewWidget *self) {
    char *path = settings_path();
    GKeyFile *kf = g_key_file_new();
    if (g_key_file_load_from_file(kf, path, G_KEY_FILE_NONE, NULL)) {
        char *s = g_key_file_get_string(kf, SETTINGS_GROUP, SETTINGS_KEY_FONT, NULL);
        if (s && *s) {
            if (self->font_desc) pango_font_description_free(self->font_desc);
            self->font_desc = pango_font_description_from_string(s);
        }
        g_free(s);
    }
    g_key_file_free(kf);
    g_free(path);
}

static void save_settings(TermViewWidget *self) {
    char *path = settings_path();
    char *dir = g_path_get_dirname(path);
    g_mkdir_with_parents(dir, 0700);
    g_free(dir);

    /* Read-modify-write so we don't clobber settings other instances saved. */
    GKeyFile *kf = g_key_file_new();
    g_key_file_load_from_file(kf, path, G_KEY_FILE_NONE, NULL);

    char *font_str = self->font_desc
        ? pango_font_description_to_string(self->font_desc)
        : g_strdup("Monospace 10");
    g_key_file_set_string(kf, SETTINGS_GROUP, SETTINGS_KEY_FONT, font_str);
    g_free(font_str);

    g_key_file_save_to_file(kf, path, NULL);
    g_key_file_free(kf);
    g_free(path);
}

static void on_font_dialog_done(GObject *src, GAsyncResult *res, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    PangoFontDescription *fd = gtk_font_dialog_choose_font_finish(
        GTK_FONT_DIALOG(src), res, NULL);
    if (!fd) return;
    if (self->font_desc) pango_font_description_free(self->font_desc);
    self->font_desc = fd;
    update_font_metrics(self);
    send_resize_to_tv(self);
    gtk_widget_queue_resize(GTK_WIDGET(self));
    save_settings(self);
}

static void on_action_font(GSimpleAction *a G_GNUC_UNUSED, GVariant *p G_GNUC_UNUSED, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    GtkFontDialog *dlg = gtk_font_dialog_new();
    gtk_font_dialog_set_title(dlg, "Choose Terminal Font");
    GtkRoot *root = gtk_widget_get_root(GTK_WIDGET(self));
    GtkWindow *parent = GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL;
    gtk_font_dialog_choose_font(dlg, parent, self->font_desc, NULL,
                                on_font_dialog_done, self);
    g_object_unref(dlg);
}

static void rebuild_popover(TermViewWidget *self) {
    if (self->popover) return;

    GMenu *menu = g_menu_new();
    g_menu_append(menu, "Copy",                       "term.copy");
    g_menu_append(menu, "Paste",                      "term.paste");
    GMenu *sect = g_menu_new();
    g_menu_append(sect, "Copy Selection as HTML",     "term.copy-html-sel");
    g_menu_append(sect, "Copy Screen as HTML",        "term.copy-html-screen");
    g_menu_append(sect, "Copy Everything as HTML",    "term.copy-html-all");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(sect));
    g_object_unref(sect);

    GMenu *fontsec = g_menu_new();
    g_menu_append(fontsec, "Font\xe2\x80\xa6",        "term.font");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(fontsec));
    g_object_unref(fontsec);

    self->menu_model = menu;
    self->popover = gtk_popover_menu_new_from_model(G_MENU_MODEL(menu));
    gtk_widget_set_parent(self->popover, GTK_WIDGET(self));
    gtk_popover_set_has_arrow(GTK_POPOVER(self->popover), FALSE);

    static const GActionEntry entries[] = {
        { "copy",              on_action_copy,              NULL, NULL, NULL, {0,0,0} },
        { "paste",             on_action_paste,             NULL, NULL, NULL, {0,0,0} },
        { "copy-html-sel",     on_action_copy_html_sel,     NULL, NULL, NULL, {0,0,0} },
        { "copy-html-screen",  on_action_copy_html_screen,  NULL, NULL, NULL, {0,0,0} },
        { "copy-html-all",     on_action_copy_html_all,     NULL, NULL, NULL, {0,0,0} },
        { "font",              on_action_font,              NULL, NULL, NULL, {0,0,0} },
    };
    GSimpleActionGroup *grp = g_simple_action_group_new();
    g_action_map_add_action_entries(G_ACTION_MAP(grp), entries,
                                    G_N_ELEMENTS(entries), self);
    gtk_widget_insert_action_group(GTK_WIDGET(self), "term", G_ACTION_GROUP(grp));
    g_object_unref(grp);
}

static void show_popover_at(TermViewWidget *self, double x, double y) {
    rebuild_popover(self);
    GdkRectangle r = { (int)x, (int)y, 1, 1 };
    gtk_popover_set_pointing_to(GTK_POPOVER(self->popover), &r);
    gtk_popover_popup(GTK_POPOVER(self->popover));
}

/* ------------------------------------------------------------------ */
/* Mouse                                                              */
/* ------------------------------------------------------------------ */

static gboolean try_mouse_report(TermViewWidget *self, double x, double y,
                                 int button, int pressed, int motion,
                                 GdkModifierType state) {
    if (!self->tv) return FALSE;
    if (!tv_mouse_protocol_active(self->tv)) return FALSE;
    if (state & GDK_SHIFT_MASK) return FALSE; /* user override */

    int col = (int)x / MAX(1, self->char_w);
    int row = (int)y / MAX(1, self->char_h);
    if (col < 0) col = 0;
    if (row < 0) row = 0;
    if (col >= tv_cols(self->tv)) col = tv_cols(self->tv) - 1;
    if (row >= tv_rows(self->tv)) row = tv_rows(self->tv) - 1;

    if (motion) {
        if (col == self->last_report_col && row == self->last_report_row) return TRUE;
    }
    self->last_report_col = col;
    self->last_report_row = row;
    tv_send_mouse(self->tv, button, col, row, pressed, motion,
                  (state & GDK_SHIFT_MASK) != 0,
                  (state & GDK_ALT_MASK) != 0,
                  (state & GDK_CONTROL_MASK) != 0);
    return TRUE;
}

static void on_click_pressed(GtkGestureClick *gesture, int n_press G_GNUC_UNUSED,
                             double x, double y, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    GdkModifierType state =
        gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture));
    guint btn = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));

    gtk_widget_grab_focus(GTK_WIDGET(self));

    /* Right-click: menu by default; only forward to app if YieldRightClickToApp. */
    if (btn == GDK_BUTTON_SECONDARY) {
        if (self->yield_right_click_to_app
            && try_mouse_report(self, x, y, TV_MOUSE_RIGHT, 1, 0, state))
            return;
        show_popover_at(self, x, y);
        return;
    }

    int tv_btn = (btn == GDK_BUTTON_PRIMARY)  ? TV_MOUSE_LEFT
              :  (btn == GDK_BUTTON_MIDDLE)   ? TV_MOUSE_MIDDLE
              :  TV_MOUSE_LEFT;
    if (try_mouse_report(self, x, y, tv_btn, 1, 0, state)) return;

    if (btn != GDK_BUTTON_PRIMARY) return;

    /* Clear any prior selection — drag will re-anchor once we exceed threshold. */
    gboolean had_selection = self->sel_active;
    self->sel_active = FALSE;
    self->sel_dragging = FALSE;
    self->sel_pending = TRUE;
    self->sel_down_x = (int)x;
    self->sel_down_y = (int)y;
    self->sel_anchor = pixel_to_cell(self, x, y);
    if (had_selection) gtk_widget_queue_draw(GTK_WIDGET(self));
}

static void on_motion(GtkEventControllerMotion *m, double x, double y, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    GdkModifierType state =
        gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(m));

    int btn = -1;
    if      (state & GDK_BUTTON1_MASK) btn = TV_MOUSE_LEFT;
    else if (state & GDK_BUTTON2_MASK) btn = TV_MOUSE_MIDDLE;
    else if (state & GDK_BUTTON3_MASK) btn = TV_MOUSE_RIGHT;
    if (tv_mouse_protocol_active(self->tv) && !(state & GDK_SHIFT_MASK)) {
        if (btn >= 0) try_mouse_report(self, x, y, btn, 1, 1, state);
        return;
    }

    if (!(state & GDK_BUTTON1_MASK)) return;

    if (self->sel_pending && !self->sel_dragging) {
        if (ABS((int)x - self->sel_down_x) < SELECTION_DRAG_PX
            && ABS((int)y - self->sel_down_y) < SELECTION_DRAG_PX) return;
        self->sel_active = TRUE;
        self->sel_dragging = TRUE;
        self->sel_pending = FALSE;
        self->sel_focus = self->sel_anchor;
    }

    if (self->sel_active && self->sel_dragging) {
        self->sel_focus = pixel_to_cell(self, x, y);
        gtk_widget_queue_draw(GTK_WIDGET(self));
    }
}

static void on_click_released(GtkGestureClick *gesture, int n_press G_GNUC_UNUSED,
                              double x, double y, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    GdkModifierType state =
        gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture));
    guint btn = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));

    if (btn == GDK_BUTTON_SECONDARY && !self->yield_right_click_to_app) return;

    int tv_btn = (btn == GDK_BUTTON_PRIMARY) ? TV_MOUSE_LEFT
              :  (btn == GDK_BUTTON_MIDDLE)  ? TV_MOUSE_MIDDLE
              :  (btn == GDK_BUTTON_SECONDARY) ? TV_MOUSE_RIGHT
              :  TV_MOUSE_LEFT;
    if (try_mouse_report(self, x, y, tv_btn, 0, 0, state)) return;
    if (btn != GDK_BUTTON_PRIMARY) return;

    self->sel_pending = FALSE;
    if (self->sel_active && self->sel_dragging) {
        self->sel_focus = pixel_to_cell(self, x, y);
        self->sel_dragging = FALSE;
        gtk_widget_queue_draw(GTK_WIDGET(self));
    }
}

static gboolean on_scroll(GtkEventControllerScroll *s, double dx G_GNUC_UNUSED,
                          double dy, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    GdkModifierType state =
        gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(s));
    if (tv_mouse_protocol_active(self->tv) && !(state & GDK_SHIFT_MASK)) {
        int btn = (dy < 0) ? TV_MOUSE_WHEEL_UP : TV_MOUSE_WHEEL_DOWN;
        try_mouse_report(self, 0, 0, btn, 1, 0, state);
        return TRUE;
    }
    if (self->vadjust) {
        double v = gtk_adjustment_get_value(self->vadjust);
        double upper = gtk_adjustment_get_upper(self->vadjust);
        double page = gtk_adjustment_get_page_size(self->vadjust);
        v += dy * 3.0;
        if (v < 0) v = 0;
        if (v > upper - page) v = MAX(0.0, upper - page);
        gtk_adjustment_set_value(self->vadjust, v);
    }
    return TRUE;
}

/* ------------------------------------------------------------------ */
/* Keyboard                                                           */
/* ------------------------------------------------------------------ */

static void send_str(TermViewWidget *self, const char *s) {
    if (self->tv) tv_send_input(self->tv, s, strlen(s));
}

/* xterm modifyOtherKeys param: Shift=1, Alt=2, Ctrl=4, +1. */
static int xterm_mod_param(GdkModifierType state) {
    int n = 1;
    if (state & GDK_SHIFT_MASK)   n += 1;
    if (state & GDK_ALT_MASK)     n += 2;
    if (state & GDK_CONTROL_MASK) n += 4;
    return n;
}

static gboolean has_mod(GdkModifierType state) {
    return (state & (GDK_SHIFT_MASK | GDK_ALT_MASK | GDK_CONTROL_MASK)) != 0;
}

/* Cursor / Home / End / F1-F4: CSI <final> or CSI 1;<mod> <final>.
   F1-F4 use SS3 (ESC O P/Q/R/S) bare, CSI form when modified. */
static void send_csi_final(TermViewWidget *self, char final,
                           GdkModifierType state, gboolean use_ss3) {
    char buf[16];
    int n;
    if (has_mod(state))
        n = snprintf(buf, sizeof buf, "\x1b[1;%d%c", xterm_mod_param(state), final);
    else if (use_ss3)
        n = snprintf(buf, sizeof buf, "\x1bO%c", final);
    else
        n = snprintf(buf, sizeof buf, "\x1b[%c", final);
    if (self->tv && n > 0) tv_send_input(self->tv, buf, (size_t)n);
}

/* Tilde-terminated CSI: ESC [ <n> ~ or ESC [ <n> ; <mod> ~.
   Insert=2, Delete=3, PageUp=5, PageDown=6, F5=15, F6-F12=17-24. */
static void send_csi_tilde(TermViewWidget *self, int code,
                           GdkModifierType state) {
    char buf[16];
    int n;
    if (has_mod(state))
        n = snprintf(buf, sizeof buf, "\x1b[%d;%d~", code, xterm_mod_param(state));
    else
        n = snprintf(buf, sizeof buf, "\x1b[%d~", code);
    if (self->tv && n > 0) tv_send_input(self->tv, buf, (size_t)n);
}

static gboolean on_key_pressed(GtkEventControllerKey *ek, guint keyval,
                               guint keycode G_GNUC_UNUSED,
                               GdkModifierType state, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    if (!self->tv) return FALSE;

    gboolean ctrl  = (state & GDK_CONTROL_MASK) != 0;
    gboolean shift = (state & GDK_SHIFT_MASK)   != 0;

    /* Ctrl+Shift shortcuts. */
    if (ctrl && shift) {
        if (keyval == GDK_KEY_C || keyval == GDK_KEY_c) {
            on_action_copy(NULL, NULL, self); return TRUE;
        }
        if (keyval == GDK_KEY_V || keyval == GDK_KEY_v) {
            on_action_paste(NULL, NULL, self); return TRUE;
        }
    }
    /* Shift+Insert is the unconditional paste escape hatch. Check before
       routing Insert to the PTY. */
    if (shift && !ctrl && keyval == GDK_KEY_Insert) {
        on_action_paste(NULL, NULL, self); return TRUE;
    }

    switch (keyval) {
        case GDK_KEY_Return: case GDK_KEY_KP_Enter: send_str(self, "\r"); return TRUE;
        case GDK_KEY_BackSpace: send_str(self, "\x7f"); return TRUE;
        case GDK_KEY_Tab: send_str(self, "\t"); return TRUE;
        case GDK_KEY_ISO_Left_Tab: send_str(self, "\x1b[Z"); return TRUE;
        case GDK_KEY_Escape: send_str(self, "\x1b"); return TRUE;

        case GDK_KEY_Up:    send_csi_final(self, 'A', state, FALSE); return TRUE;
        case GDK_KEY_Down:  send_csi_final(self, 'B', state, FALSE); return TRUE;
        case GDK_KEY_Right: send_csi_final(self, 'C', state, FALSE); return TRUE;
        case GDK_KEY_Left:  send_csi_final(self, 'D', state, FALSE); return TRUE;
        case GDK_KEY_Home:  send_csi_final(self, 'H', state, FALSE); return TRUE;
        case GDK_KEY_End:   send_csi_final(self, 'F', state, FALSE); return TRUE;

        case GDK_KEY_Insert:    send_csi_tilde(self, 2,  state); return TRUE;
        case GDK_KEY_Delete:    send_csi_tilde(self, 3,  state); return TRUE;
        case GDK_KEY_Page_Up:   send_csi_tilde(self, 5,  state); return TRUE;
        case GDK_KEY_Page_Down: send_csi_tilde(self, 6,  state); return TRUE;

        case GDK_KEY_F1: send_csi_final(self, 'P', state, TRUE); return TRUE;
        case GDK_KEY_F2: send_csi_final(self, 'Q', state, TRUE); return TRUE;
        case GDK_KEY_F3: send_csi_final(self, 'R', state, TRUE); return TRUE;
        case GDK_KEY_F4: send_csi_final(self, 'S', state, TRUE); return TRUE;
        case GDK_KEY_F5:  send_csi_tilde(self, 15, state); return TRUE;
        case GDK_KEY_F6:  send_csi_tilde(self, 17, state); return TRUE;
        case GDK_KEY_F7:  send_csi_tilde(self, 18, state); return TRUE;
        case GDK_KEY_F8:  send_csi_tilde(self, 19, state); return TRUE;
        case GDK_KEY_F9:  send_csi_tilde(self, 20, state); return TRUE;
        case GDK_KEY_F10: send_csi_tilde(self, 21, state); return TRUE;
        case GDK_KEY_F11: send_csi_tilde(self, 23, state); return TRUE;
        case GDK_KEY_F12: send_csi_tilde(self, 24, state); return TRUE;
    }

    if (ctrl && !shift) {
        if (keyval >= GDK_KEY_a && keyval <= GDK_KEY_z) {
            char ch = (char)(keyval - GDK_KEY_a + 1);
            tv_send_input(self->tv, &ch, 1);
            return TRUE;
        }
        if (keyval >= GDK_KEY_A && keyval <= GDK_KEY_Z) {
            char ch = (char)(keyval - GDK_KEY_A + 1);
            tv_send_input(self->tv, &ch, 1);
            return TRUE;
        }
        switch (keyval) {
            case GDK_KEY_bracketleft:  send_str(self, "\x1b"); return TRUE;
            case GDK_KEY_backslash:    send_str(self, "\x1c"); return TRUE;
            case GDK_KEY_bracketright: send_str(self, "\x1d"); return TRUE;
        }
    }

    /* Let IM context handle printable input. */
    return gtk_im_context_filter_keypress(self->im,
        gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(ek)));
}

static void on_im_commit(GtkIMContext *im G_GNUC_UNUSED, const char *str, gpointer ud) {
    TermViewWidget *self = TERM_VIEW_WIDGET(ud);
    if (self->tv && str) tv_send_input(self->tv, str, strlen(str));
}

/* ------------------------------------------------------------------ */
/* GObject lifecycle                                                  */
/* ------------------------------------------------------------------ */

static void term_view_widget_realize(GtkWidget *widget) {
    GTK_WIDGET_CLASS(term_view_widget_parent_class)->realize(widget);
    TermViewWidget *self = TERM_VIEW_WIDGET(widget);
    gtk_im_context_set_client_widget(self->im, widget);
    self->clipboard = gtk_widget_get_clipboard(widget);
    update_font_metrics(self);

    if (!self->tv) {
        self->tv = tv_controller_new(80, 25, self->scrollback);
        tv_set_user_data(self->tv, self);
        tv_set_on_invalidate(self->tv, on_tv_invalidate);
        tv_set_on_bell(self->tv,       on_tv_bell);
        tv_set_on_title(self->tv,      on_tv_title);
        tv_set_on_exit(self->tv,       on_tv_exit);
        tv_set_on_clipboard_set(self->tv, on_tv_clip_set);
        tv_set_on_clipboard_get(self->tv, on_tv_clip_get);
    }
    if (self->pending_shell) {
        tv_start_shell(self->tv, self->pending_shell);
        g_clear_pointer(&self->pending_shell, g_free);
    }
    if (!self->pump_source)
        self->pump_source = g_timeout_add(PUMP_INTERVAL_MS, pump_tick, self);
    if (!self->cursor_source)
        self->cursor_source = g_timeout_add(CURSOR_BLINK_MS, cursor_tick, self);
}

static void term_view_widget_unrealize(GtkWidget *widget) {
    TermViewWidget *self = TERM_VIEW_WIDGET(widget);
    if (self->pump_source)   { g_source_remove(self->pump_source);   self->pump_source = 0; }
    if (self->cursor_source) { g_source_remove(self->cursor_source); self->cursor_source = 0; }
    GTK_WIDGET_CLASS(term_view_widget_parent_class)->unrealize(widget);
}

static void term_view_widget_dispose(GObject *obj) {
    TermViewWidget *self = TERM_VIEW_WIDGET(obj);
    if (self->popover) {
        gtk_widget_unparent(self->popover);
        self->popover = NULL;
    }
    if (self->tv) { tv_controller_free(self->tv); self->tv = NULL; }
    g_clear_object(&self->im);
    if (self->menu_model) { g_object_unref(self->menu_model); self->menu_model = NULL; }
    G_OBJECT_CLASS(term_view_widget_parent_class)->dispose(obj);
}

static void term_view_widget_finalize(GObject *obj) {
    TermViewWidget *self = TERM_VIEW_WIDGET(obj);
    if (self->font_desc) pango_font_description_free(self->font_desc);
    g_clear_pointer(&self->pending_shell, g_free);
    if (self->vadjust) g_object_unref(self->vadjust);
    G_OBJECT_CLASS(term_view_widget_parent_class)->finalize(obj);
}

static void term_view_widget_get_property(GObject *obj, guint id,
                                          GValue *val, GParamSpec *pspec) {
    TermViewWidget *self = TERM_VIEW_WIDGET(obj);
    switch (id) {
    case PROP_FONT_DESC: {
        gchar *s = self->font_desc ? pango_font_description_to_string(self->font_desc) : g_strdup("");
        g_value_take_string(val, s);
        break;
    }
    case PROP_SCROLLBACK: g_value_set_int(val, self->scrollback); break;
    case PROP_YIELD_RIGHT_CLICK_TO_APP:
        g_value_set_boolean(val, self->yield_right_click_to_app); break;
    default:
        /* Scrollable interface properties. */
        if (g_strcmp0(g_param_spec_get_name(pspec), "vadjustment") == 0) {
            g_value_set_object(val, self->vadjust);
        } else if (g_strcmp0(g_param_spec_get_name(pspec), "hadjustment") == 0) {
            g_value_set_object(val, NULL);
        } else if (g_strcmp0(g_param_spec_get_name(pspec), "vscroll-policy") == 0) {
            g_value_set_enum(val, GTK_SCROLL_NATURAL);
        } else if (g_strcmp0(g_param_spec_get_name(pspec), "hscroll-policy") == 0) {
            g_value_set_enum(val, GTK_SCROLL_NATURAL);
        } else {
            G_OBJECT_WARN_INVALID_PROPERTY_ID(obj, id, pspec);
        }
    }
}

static void term_view_widget_set_property(GObject *obj, guint id,
                                          const GValue *val, GParamSpec *pspec) {
    TermViewWidget *self = TERM_VIEW_WIDGET(obj);
    switch (id) {
    case PROP_FONT_DESC: {
        const char *s = g_value_get_string(val);
        if (self->font_desc) pango_font_description_free(self->font_desc);
        self->font_desc = pango_font_description_from_string(s ? s : "Monospace 10");
        if (gtk_widget_get_realized(GTK_WIDGET(self))) {
            update_font_metrics(self);
            send_resize_to_tv(self);
            gtk_widget_queue_resize(GTK_WIDGET(self));
        }
        break;
    }
    case PROP_SCROLLBACK: self->scrollback = g_value_get_int(val); break;
    case PROP_YIELD_RIGHT_CLICK_TO_APP:
        self->yield_right_click_to_app = g_value_get_boolean(val); break;
    default:
        if (g_strcmp0(g_param_spec_get_name(pspec), "vadjustment") == 0) {
            set_vadjustment(self, GTK_ADJUSTMENT(g_value_get_object(val)));
        } else if (g_strcmp0(g_param_spec_get_name(pspec), "hadjustment") == 0
                || g_strcmp0(g_param_spec_get_name(pspec), "vscroll-policy") == 0
                || g_strcmp0(g_param_spec_get_name(pspec), "hscroll-policy") == 0) {
            /* accept and ignore */
        } else {
            G_OBJECT_WARN_INVALID_PROPERTY_ID(obj, id, pspec);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Class init                                                         */
/* ------------------------------------------------------------------ */

static void term_view_widget_class_init(TermViewWidgetClass *klass) {
    GObjectClass   *gc = G_OBJECT_CLASS(klass);
    GtkWidgetClass *wc = GTK_WIDGET_CLASS(klass);

    gc->get_property = term_view_widget_get_property;
    gc->set_property = term_view_widget_set_property;
    gc->dispose      = term_view_widget_dispose;
    gc->finalize     = term_view_widget_finalize;

    wc->snapshot      = term_view_widget_snapshot;
    wc->measure       = term_view_widget_measure;
    wc->size_allocate = term_view_widget_size_allocate;
    wc->realize       = term_view_widget_realize;
    wc->unrealize     = term_view_widget_unrealize;

    gtk_widget_class_set_css_name(wc, "termview");

    props[PROP_FONT_DESC] = g_param_spec_string("font-desc",
        "Font", "Pango font description", "Monospace 10",
        G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);
    props[PROP_SCROLLBACK] = g_param_spec_int("scrollback",
        "Scrollback", "Scrollback rows", 0, G_MAXINT, 5000,
        G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);
    props[PROP_YIELD_RIGHT_CLICK_TO_APP] = g_param_spec_boolean("yield-right-click-to-app",
        "Yield right-click to app",
        "If TRUE, right-click is reported to the running app instead of opening the menu",
        FALSE, G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);
    g_object_class_install_properties(gc, N_PROPS, props);

    /* Override the scrollable interface properties. */
    g_object_class_override_property(gc, N_PROPS,     "hadjustment");
    g_object_class_override_property(gc, N_PROPS + 1, "vadjustment");
    g_object_class_override_property(gc, N_PROPS + 2, "hscroll-policy");
    g_object_class_override_property(gc, N_PROPS + 3, "vscroll-policy");

    signals[SIG_SHELL_EXITED] = g_signal_new("shell-exited",
        G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
        G_TYPE_NONE, 0);
    signals[SIG_TITLE_CHANGED] = g_signal_new("title-changed",
        G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
        G_TYPE_NONE, 1, G_TYPE_STRING);
    signals[SIG_BELL] = g_signal_new("bell",
        G_TYPE_FROM_CLASS(klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
        G_TYPE_NONE, 0);
}

static void term_view_widget_init(TermViewWidget *self) {
    self->font_desc = pango_font_description_from_string("Monospace 10");
    self->scrollback = 5000;
    self->cursor_visible = TRUE;
    self->char_w = 8;
    self->char_h = 12;

    gtk_widget_set_focusable(GTK_WIDGET(self), TRUE);
    gtk_widget_set_can_focus(GTK_WIDGET(self), TRUE);

    /* Input. */
    self->im = gtk_im_multicontext_new();
    g_signal_connect(self->im, "commit", G_CALLBACK(on_im_commit), self);

    GtkEventController *kc = gtk_event_controller_key_new();
    g_signal_connect(kc, "key-pressed", G_CALLBACK(on_key_pressed), self);
    gtk_widget_add_controller(GTK_WIDGET(self), kc);

    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect(click, "pressed",  G_CALLBACK(on_click_pressed),  self);
    g_signal_connect(click, "released", G_CALLBACK(on_click_released), self);
    gtk_widget_add_controller(GTK_WIDGET(self), GTK_EVENT_CONTROLLER(click));

    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_motion), self);
    gtk_widget_add_controller(GTK_WIDGET(self), motion);

    GtkEventController *scroll =
        gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), self);
    gtk_widget_add_controller(GTK_WIDGET(self), scroll);

    set_vadjustment(self, NULL);

    load_settings(self);
}

/* ------------------------------------------------------------------ */
/* Public                                                             */
/* ------------------------------------------------------------------ */

GtkWidget *term_view_widget_new(void) {
    return g_object_new(TERM_TYPE_VIEW_WIDGET, NULL);
}

void term_view_widget_start_shell(TermViewWidget *self, const char *shell) {
    g_return_if_fail(TERM_IS_VIEW_WIDGET(self));
    if (self->tv && gtk_widget_get_realized(GTK_WIDGET(self))) {
        tv_start_shell(self->tv, shell);
    } else {
        g_clear_pointer(&self->pending_shell, g_free);
        self->pending_shell = shell ? g_strdup(shell) : g_strdup("");
    }
}

tv_handle *term_view_widget_get_handle(TermViewWidget *self) {
    g_return_val_if_fail(TERM_IS_VIEW_WIDGET(self), NULL);
    return self->tv;
}
