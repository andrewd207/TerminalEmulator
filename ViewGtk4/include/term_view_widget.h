/*
 * TermViewWidget — GTK4 widget wrapping a tv_handle. Built on the C ABI in
 * termview.h. Drop into any GtkWindow.
 *
 * Properties (via g_object_set/get):
 *   "font-desc"               (string,  default "Monospace 10") — Pango
 *   "scrollback"              (int,     default 5000)
 *   "yield-right-click-to-app" (boolean, default FALSE)
 *
 * Signals:
 *   "shell-exited"  (void)
 *   "title-changed" (string)
 *   "bell"          (void)
 *
 * Copyright (c) 2026 Andrew Haines
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef TERM_VIEW_WIDGET_H
#define TERM_VIEW_WIDGET_H

#include <gtk/gtk.h>
#include "termview.h"

G_BEGIN_DECLS

#define TERM_TYPE_VIEW_WIDGET (term_view_widget_get_type())
G_DECLARE_FINAL_TYPE(TermViewWidget, term_view_widget, TERM, VIEW_WIDGET, GtkWidget)

GtkWidget *term_view_widget_new(void);

/* Start a shell. Pass NULL for $SHELL default. */
void       term_view_widget_start_shell(TermViewWidget *self, const char *shell);

/* Underlying handle (NULL until realized). */
tv_handle *term_view_widget_get_handle(TermViewWidget *self);

G_END_DECLS

#endif /* TERM_VIEW_WIDGET_H */
