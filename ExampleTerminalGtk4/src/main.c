/*
 * GTK4 demo for TermViewWidget.
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include <gtk/gtk.h>
#include "term_view_widget.h"

typedef struct {
    GtkWindow      *window;
    TermViewWidget *term;
} AppCtx;

static void on_title_changed(TermViewWidget *t G_GNUC_UNUSED, const char *title, gpointer ud) {
    AppCtx *ctx = (AppCtx *)ud;
    if (title && *title) gtk_window_set_title(ctx->window, title);
}

static void on_shell_exited(TermViewWidget *t G_GNUC_UNUSED, gpointer ud) {
    AppCtx *ctx = (AppCtx *)ud;
    const char *old = gtk_window_get_title(ctx->window);
    gchar *neu = g_strdup_printf("%s [exited]", old ? old : "Terminal");
    gtk_window_set_title(ctx->window, neu);
    g_free(neu);
}

typedef struct {
    GMainLoop *loop;
    int        response;
} DialogState;

static void on_dialog_response(GtkDialog *d G_GNUC_UNUSED, int r, gpointer ud) {
    DialogState *st = (DialogState *)ud;
    st->response = r;
    g_main_loop_quit(st->loop);
}

static gboolean on_close_request(GtkWindow *win, gpointer ud) {
    AppCtx *ctx = (AppCtx *)ud;
    tv_handle *h = term_view_widget_get_handle(ctx->term);
    if (!h || !tv_subprocess_running(h)) return FALSE; /* let close proceed */

    GtkWidget *dlg = gtk_message_dialog_new(win, GTK_DIALOG_MODAL,
        GTK_MESSAGE_QUESTION, GTK_BUTTONS_YES_NO,
        "A program is still running in the shell. Quit anyway?");
    gtk_window_set_title(GTK_WINDOW(dlg), "Close window?");

    DialogState st = { g_main_loop_new(NULL, FALSE), GTK_RESPONSE_NO };
    g_signal_connect(dlg, "response", G_CALLBACK(on_dialog_response), &st);
    gtk_window_present(GTK_WINDOW(dlg));
    g_main_loop_run(st.loop);
    g_main_loop_unref(st.loop);
    gtk_window_destroy(GTK_WINDOW(dlg));
    return st.response != GTK_RESPONSE_YES;
}

static void on_activate(GtkApplication *app, gpointer ud G_GNUC_UNUSED) {
    AppCtx *ctx = g_new0(AppCtx, 1);

    GtkWidget *win = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(win), "GTK4 Terminal");
    gtk_window_set_default_size(GTK_WINDOW(win), 900, 600);
    ctx->window = GTK_WINDOW(win);

    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
        GTK_POLICY_NEVER, GTK_POLICY_ALWAYS);

    GtkWidget *term = term_view_widget_new();
    ctx->term = TERM_VIEW_WIDGET(term);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), term);
    gtk_window_set_child(GTK_WINDOW(win), scrolled);

    g_signal_connect(term, "title-changed", G_CALLBACK(on_title_changed), ctx);
    g_signal_connect(term, "shell-exited",  G_CALLBACK(on_shell_exited),  ctx);
    g_signal_connect(win,  "close-request", G_CALLBACK(on_close_request), ctx);

    gtk_window_present(GTK_WINDOW(win));
    gtk_widget_grab_focus(term);

    /* Start a shell (defaults to $SHELL). */
    term_view_widget_start_shell(TERM_VIEW_WIDGET(term), NULL);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("com.example.termview",
                                              G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
