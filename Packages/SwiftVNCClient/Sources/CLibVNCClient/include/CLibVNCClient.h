/*
 * Copyright © 2026 Turing Software, LLC
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A narrow C interface to LibVNCClient for the Swift wrapper. Nothing of LibVNCClient's own
 * headers is exposed: its structures, variadic log hooks and unions do not import into Swift, and
 * its headers need configuration that importers do not have.
 *
 * One client must only ever be used from one thread.
 */
#ifndef MARIONETTE_CLIBVNCCLIENT_H
#define MARIONETTE_CLIBVNCCLIENT_H

#include <stdint.h>

typedef struct marionette_vnc_client marionette_vnc_client;

typedef struct {
    void *context;
    /**
     * The desktop is now `width` × `height`. Return storage for width × height × 4 bytes, which the
     * caller owns and keeps alive until the next resize or the client's destruction; NULL refuses.
     * A server may report 0 × 0 until it has something to show; storage for one pixel is enough then.
     */
    uint8_t *(*resize)(void *context, int width, int height);
    /** A rectangle of the framebuffer has new pixels. More rectangles of the same update may follow. */
    void (*update)(void *context, int x, int y, int width, int height);
    /** A framebuffer update is complete. */
    void (*finished)(void *context);
    /** A password for classic VNC authentication, allocated with malloc, or NULL to give up. */
    char *(*password)(void *context);
    /** A user name and password, each allocated with malloc. Return 0 to give up. */
    int (*credential)(void *context, char **username, char **password);
    /** A new pointer shape: `pixels` is width × height × 4 bytes B, G, R, X; `mask` is one byte per pixel, non-zero where opaque. */
    void (*cursor)(void *context, int hotspot_x, int hotspot_y, int width, int height, const uint8_t *pixels, const uint8_t *mask);
    void (*bell)(void *context);
    /**
     * The server's clipboard text, not NUL-terminated. `is_utf8` is 1 for the extended clipboard,
     * which is UTF-8 by definition, and 0 for classic cut text, which should be Latin-1 but is
     * UTF-8 from many servers.
     */
    void (*clipboard)(void *context, const char *text, int length, int is_utf8);
} marionette_vnc_callbacks;

/** Why a connect failed, as far as the server or LibVNCClient said. */
typedef enum {
    /** Nothing more specific than the error text: the connection broke, or the server is not VNC. */
    MARIONETTE_VNC_FAILURE_OTHER = 0,
    /** The server turned the connection away before authentication, with `reason`. */
    MARIONETTE_VNC_FAILURE_REFUSED = 1,
    /** The server rejected the credentials, with `reason` when it sent one. */
    MARIONETTE_VNC_FAILURE_REJECTED = 2,
    /** The server rejected the credentials and will not take more attempts for now. */
    MARIONETTE_VNC_FAILURE_TOO_MANY_ATTEMPTS = 3,
    /** The server offers no authentication LibVNCClient can do. */
    MARIONETTE_VNC_FAILURE_UNSUPPORTED_AUTHENTICATION = 4,
} marionette_vnc_failure_kind;

/** Creates a client that will deliver 32-bit B, G, R, X pixels. */
marionette_vnc_client *marionette_vnc_create(const marionette_vnc_callbacks *callbacks);

/** Space-separated encoding names in order of preference, and levels 0–9. */
void marionette_vnc_set_encodings(marionette_vnc_client *client, const char *encodings, int compress_level, int quality_level);

/**
 * Runs the RFB handshake and authentication over an already connected socket.
 * Returns 1 on success. On failure returns 0 and the client has been destroyed; see
 * `marionette_vnc_last_failure` and `marionette_vnc_last_error` for why.
 */
int marionette_vnc_connect(marionette_vnc_client *client, int socket, int shared);

int marionette_vnc_width(const marionette_vnc_client *client);
int marionette_vnc_height(const marionette_vnc_client *client);
/** The server's name for the desktop, valid until the client is destroyed. */
const char *marionette_vnc_desktop_name(const marionette_vnc_client *client);

/**
 * The protocol version the server announced on this thread's most recent connect, before
 * LibVNCClient settled on one it speaks (Apple's server says 3.889). Zero when none was seen.
 */
void marionette_vnc_server_version(int *major, int *minor);

/**
 * Waits until the server has sent something or `wake_fd` is readable.
 * Returns a bit set: 1 server data, 2 wake; 0 on timeout, -1 on error.
 */
int marionette_vnc_wait(marionette_vnc_client *client, int wake_fd, int timeout_ms);

/** Handles every server message that is ready. Returns 0 when the connection is over. */
int marionette_vnc_process(marionette_vnc_client *client);

int marionette_vnc_send_key(marionette_vnc_client *client, uint32_t keysym, int down);
int marionette_vnc_send_pointer(marionette_vnc_client *client, int x, int y, int button_mask);
/**
 * Sets the server's clipboard text. Where the server has the extended clipboard the UTF-8 form is
 * announced and handed over when the server asks for it; otherwise the Latin-1 form goes as
 * classic cut text.
 */
int marionette_vnc_send_clipboard(marionette_vnc_client *client, const char *utf8, int utf8_length, const char *latin1, int latin1_length);
/**
 * Checks that both the old ciphers VNC passwords need and the modern ones are usable, in the order
 * that would expose one disabling the other. Returns 1 when they are.
 */
int marionette_vnc_crypto_self_test(void);
int marionette_vnc_request_update(marionette_vnc_client *client, int x, int y, int width, int height, int incremental);

void marionette_vnc_destroy(marionette_vnc_client *client);

/** The most recent error LibVNCClient reported on this thread, or an empty string. */
const char *marionette_vnc_last_error(void);

/**
 * What ended this thread's most recent failed connect, and the server's own words for it in
 * `reason` (empty when it gave none), valid until the next connect on this thread.
 */
marionette_vnc_failure_kind marionette_vnc_last_failure(const char **reason);

/**
 * Decodes a JPEG into 32-bit pixels: `pixels` points at the top-left pixel and rows are
 * `bytes_per_row` apart; `blue_first` asks for B, G, R, X in memory rather than R, G, B, X.
 * Returns 1 when the JPEG was exactly `width` × `height` and decoded. Used for Tight's JPEG
 * rectangles; exposed for tests.
 */
int marionette_vnc_decode_jpeg(const uint8_t *jpeg, unsigned long length, uint8_t *pixels, int width, int height, int bytes_per_row, int blue_first);

#endif
