/*
 * Copyright © 2026 Turing Software, LLC
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <zlib.h>
#include <openssl/provider.h>
#include <openssl/rand.h>
#include <rfb/rfbclient.h>
#include "crypto.h"
#include "../include/CLibVNCClient.h"

/* The opaque handle is the rfbClient itself; our state rides in its client data. */
struct marionette_vnc_client {
    rfbClient rfb;
};

typedef struct {
    marionette_vnc_callbacks callbacks;
    /* The encoding names handed to LibVNCClient, which must outlive the client. */
    char *encodings;
    /* Whether the encodings were looked at again after the first update (see `review_encodings`). */
    int encodings_reviewed;
    /* Whether SetEncodings still asks for ExtendedDesktopSize (see `review_encodings`). */
    int extended_desktop_size;
    /* The caller's framebuffer, B, G, R, X: what the caller sees, whatever format the server sends. */
    uint8_t *pixels;
    /* The colour depth (see `marionette_vnc_set_full_colour`): what was asked for, and what the
       server sends. */
    int wanted_low_colour;
    int low_colour;
    /* Ask for the whole desktop when back in full colour. */
    int refresh_in_full_colour;
    /* LibVNCClient's framebuffer while in 256 colours, a byte a pixel, converted into `pixels`
       rectangle by rectangle. */
    uint8_t *low_pixels;
    /* Update requests (see `request_next_update`): whether an update is being read, whether the
       desktop changed size during it or outside one, and whether a request beyond the one the
       shim keeps outstanding has ever gone out. */
    int in_update;
    int resized_in_update;
    int resized_outside_update;
    int requests_uncertain;
    /* The JPEG quality asked for, -1 for none. LibVNCClient keeps its own copy in `appData`, but
       sets it to 9 whenever a ZRLE rectangle arrives. */
    int quality_level;
    /* The server takes only full colour (see `marionette_vnc_keep_full_colour`). */
    int full_colour_only;
    /* The extended-clipboard capabilities the server sent; 0 until it does. */
    uint32_t server_clipboard;
    /* Our clipboard text as the extended clipboard carries it: UTF-8, CR LF line ends, NUL-terminated.
       `clipboard_length` counts the NUL. */
    char *clipboard;
    uint32_t clipboard_length;
} client_state;

static char state_tag;

/* Everything LibVNCClient says arrives through process-wide log hooks, so what a connect needs to
   know afterwards is kept per thread: each client runs on a thread of its own. */
static _Thread_local char last_error[512];
static _Thread_local char last_reason[512];
static _Thread_local marionette_vnc_failure_kind last_failure;
static _Thread_local int refused_before_authentication;
static _Thread_local int server_major, server_minor;

static client_state *state_of(rfbClient *client) {
    return (client_state *)rfbClientGetClientData(client, &state_tag);
}

static marionette_vnc_callbacks *callbacks_of(rfbClient *client) {
    client_state *state = state_of(client);
    return state ? &state->callbacks : NULL;
}

static void keep_line(char *buffer, size_t size, const char *format, va_list arguments) {
    vsnprintf(buffer, size, format, arguments);
    size_t length = strlen(buffer);
    while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) {
        buffer[--length] = '\0';
    }
}

/* LibVNCClient reports the server's protocol version and its reasons for failing only as log
   lines. They are recognised by their format strings, which are LibVNCClient's own literals, so
   the arguments can be taken as they were passed rather than parsed back out of text. */
static void log_info(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    if (strcmp(format, "VNC server supports protocol version %d.%d (viewer %d.%d)\n") == 0) {
        server_major = va_arg(arguments, int);
        server_minor = va_arg(arguments, int);
    } else if (strcmp(format, "List of security types is ZERO, expecting an error to follow\n") == 0) {
        refused_before_authentication = 1;
    } else if (strcmp(format, "Selected Security Scheme %d\n") == 0) {
        /* RFB 3.3's way of turning a client away: security type 0, then a reason. */
        if (va_arg(arguments, int) == rfbConnFailed) refused_before_authentication = 1;
    } else if (strcmp(format, "VNC connection failed: %s\n") == 0) {
        const char *reason = va_arg(arguments, const char *);
        snprintf(last_reason, sizeof(last_reason), "%s", reason ? reason : "");
        last_failure = refused_before_authentication ? MARIONETTE_VNC_FAILURE_REFUSED : MARIONETTE_VNC_FAILURE_REJECTED;
    } else if (strcmp(format, "VNC authentication failed\n") == 0) {
        last_failure = MARIONETTE_VNC_FAILURE_REJECTED;
    } else if (strcmp(format, "VNC authentication failed - too many tries\n") == 0) {
        last_failure = MARIONETTE_VNC_FAILURE_TOO_MANY_ATTEMPTS;
    } else if (strncmp(format, "Unknown authentication scheme from VNC server", 45) == 0
               || strncmp(format, "Unknown sub authentication scheme from VNC server", 49) == 0) {
        last_failure = MARIONETTE_VNC_FAILURE_UNSUPPORTED_AUTHENTICATION;
        keep_line(last_error, sizeof(last_error), format, arguments);
    } else if (strncmp(format, "Rect too large", 14) == 0 || strncmp(format, "Unknown", 7) == 0) {
        /* Data the library could not make sense of: the reason a session ends as a protocol error. */
        keep_line(last_error, sizeof(last_error), format, arguments);
    }
    va_end(arguments);
}

static void log_error(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    keep_line(last_error, sizeof(last_error), format, arguments);
    va_end(arguments);
}

static pthread_once_t log_once = PTHREAD_ONCE_INIT;

static void install_log_hooks(void) {
    rfbClientLog = log_info;
    rfbClientErr = log_error;
    /* LibVNCClient loads OpenSSL's "legacy" and "default" providers around each DES operation and
       unloads them afterwards. Once a provider has been loaded by hand OpenSSL stops falling back
       to the default one, so after the first VNC password every later use of OpenSSL in the
       process would fail (the next login to a Mac, an SSH tunnel). Holding both for the life of
       the process turns that load and unload into a reference count going up and down. */
    OSSL_PROVIDER_load(NULL, "default");
    OSSL_PROVIDER_load(NULL, "legacy");
}

int marionette_vnc_crypto_self_test(void) {
    pthread_once(&log_once, install_log_hooks);
    static const unsigned char key[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    static const unsigned char aes_key[16] = {0};
    unsigned char block[16] = {0}, sealed[32], random[16];
    int sealed_length = 0;
    /* DES is in the legacy provider; AES and the random generator (which every key exchange
       needs) are in the default one. In that order on purpose. */
    if (!encrypt_rfbdes(sealed, &sealed_length, key, block, sizeof(block))) return 0;
    if (!encrypt_aes128ecb(sealed, &sealed_length, aes_key, block, sizeof(block))) return 0;
    if (RAND_bytes(random, sizeof(random)) != 1) return 0;
    return 1;
}

const char *marionette_vnc_last_error(void) {
    return last_error;
}

marionette_vnc_failure_kind marionette_vnc_last_failure(const char **reason) {
    if (reason) *reason = last_reason;
    return last_failure;
}

void marionette_vnc_server_version(int *major, int *minor) {
    if (major) *major = server_major;
    if (minor) *minor = server_minor;
}

static uint32_t read_u32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3];
}

static void write_u32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24);
    bytes[1] = (uint8_t)(value >> 16);
    bytes[2] = (uint8_t)(value >> 8);
    bytes[3] = (uint8_t)value;
}

// MARK: - Encodings

/* The encoding names LibVNCClient understands, with the pseudo-encodings each brings along. */
typedef struct {
    const char *name;
    int32_t encodings[2];
    int count;
    int compress_level;
    int quality_level;
    int last_rect;
} encoding_name;

static const encoding_name encoding_names[] = {
    {"raw", {rfbEncodingRaw}, 1, 0, 0, 0},
    {"copyrect", {rfbEncodingCopyRect}, 1, 0, 0, 0},
    {"tight", {rfbEncodingTight}, 1, 1, 1, 1},
    {"hextile", {rfbEncodingHextile}, 1, 0, 0, 0},
    {"zlib", {rfbEncodingZlib}, 1, 1, 0, 0},
    {"zlibhex", {rfbEncodingZlibHex}, 1, 1, 0, 0},
    {"trle", {rfbEncodingTRLE}, 1, 0, 0, 0},
    {"zrle", {rfbEncodingZRLE}, 1, 0, 0, 0},
    {"zywrle", {rfbEncodingZYWRLE}, 1, 0, 1, 0},
    {"ultra", {rfbEncodingUltra, rfbEncodingUltraZip}, 2, 0, 0, 0},
    {"corre", {rfbEncodingCoRRE}, 1, 0, 0, 0},
    {"rre", {rfbEncodingRRE}, 1, 0, 0, 0},
};

/* Sends SetEncodings with the list LibVNCClient's own SetFormatAndEncodings builds from the same
   names, with or without ExtendedDesktopSize. */
static rfbBool send_encodings(rfbClient *client, const char *names, int extended_desktop_size) {
    uint32_t list[64];
    int count = 0, compress = 0, quality = 0, last_rect = 0;
    for (const char *name = names; name && *name;) {
        size_t length = strcspn(name, " ");
        for (size_t index = 0; index < sizeof(encoding_names) / sizeof(encoding_names[0]); index++) {
            const encoding_name *known = &encoding_names[index];
            if (strlen(known->name) != length || strncasecmp(known->name, name, length) != 0) continue;
            for (int i = 0; i < known->count && count < 48; i++) list[count++] = (uint32_t)known->encodings[i];
            compress |= known->compress_level;
            quality |= known->quality_level;
            last_rect |= known->last_rect;
        }
        name += length;
        while (*name == ' ') name++;
    }
    if (compress && client->appData.compressLevel >= 0 && client->appData.compressLevel <= 9) {
        list[count++] = (uint32_t)(rfbEncodingCompressLevel0 + client->appData.compressLevel);
    }
    /* Tight has no JPEG in 256 colours, and LibVNCClient ends the session if a server sends one. */
    client_state *state = state_of(client);
    int level = state ? state->quality_level : -1;
    if (quality && state && !state->low_colour && level >= 0 && level <= 9) {
        list[count++] = (uint32_t)(rfbEncodingQualityLevel0 + level);
    }
    if (client->appData.useRemoteCursor) {
        list[count++] = rfbEncodingXCursor;
        list[count++] = rfbEncodingRichCursor;
        list[count++] = rfbEncodingPointerPos;
    }
    list[count++] = rfbEncodingKeyboardLedState;
    if (client->canHandleNewFBSize) list[count++] = rfbEncodingNewFBSize;
    if (extended_desktop_size) list[count++] = rfbEncodingExtDesktopSize;
    if (last_rect) list[count++] = rfbEncodingLastRect;
    list[count++] = rfbEncodingSupportedMessages;
    list[count++] = rfbEncodingSupportedEncodings;
    list[count++] = rfbEncodingServerIdentity;
    list[count++] = rfbEncodingXvp;
    list[count++] = rfbEncodingQemuExtendedKeyEvent;
    list[count++] = rfbEncodingExtendedClipboard;

    uint8_t message[4 + sizeof(list)];
    message[0] = rfbSetEncodings;
    message[1] = 0;
    message[2] = (uint8_t)(count >> 8);
    message[3] = (uint8_t)count;
    for (int i = 0; i < count; i++) write_u32(&message[4 + i * 4], list[i]);
    return WriteToRFBServer(client, (const char *)message, (unsigned int)(4 + count * 4));
}

/* LibVNCClient always asks for ExtendedDesktopSize, but takes a resize from it only when every
   screen in it has a non-zero id. QEMU (and with it libvirt and Proxmox) and Xvnc without RandR
   number their one screen 0, so their resizes are dropped and the next rectangle, drawn at the
   new size, ends the session as "too large". Servers that send ExtendedDesktopSize do so straight
   after SetEncodings; if by the end of the first update no screen the library accepts has arrived,
   the encodings are sent again without it, and such a server reports resizes as DesktopSize, which
   LibVNCClient always follows. */
static void review_encodings(rfbClient *client, client_state *state) {
    if (state->encodings_reviewed) return;
    state->encodings_reviewed = 1;
    if (client->screen.width == 0 && client->screen.height == 0) {
        state->extended_desktop_size = 0;
        send_encodings(client, state->encodings, 0);
    }
}

// MARK: - Colour depth

/* Below full colour the server sends 256 colours, a byte a pixel: three bits of red and green and
   two of blue, to which the eye is least sensitive. */
static void set_format(rfbPixelFormat *format, int low_colour) {
    memset(format, 0, sizeof(*format));
    format->trueColour = TRUE;
    format->bigEndian = FALSE;
    if (low_colour) {
        format->bitsPerPixel = 8;
        format->depth = 8;
        format->redMax = 7;
        format->greenMax = 7;
        format->blueMax = 3;
        format->redShift = 5;
        format->greenShift = 2;
        format->blueShift = 0;
    } else {
        /* Little-endian 32-bit with blue in the low byte: B, G, R, X in memory. */
        format->bitsPerPixel = 32;
        format->depth = 24;
        format->redMax = 255;
        format->greenMax = 255;
        format->blueMax = 255;
        format->redShift = 16;
        format->greenShift = 8;
        format->blueShift = 0;
    }
}

static rfbBool send_pixel_format(rfbClient *client, int low_colour) {
    rfbPixelFormat format;
    set_format(&format, low_colour);
    uint8_t message[20] = {rfbSetPixelFormat};
    message[4] = format.bitsPerPixel;
    message[5] = format.depth;
    message[6] = format.bigEndian;
    message[7] = format.trueColour;
    message[8] = (uint8_t)(format.redMax >> 8);
    message[9] = (uint8_t)format.redMax;
    message[10] = (uint8_t)(format.greenMax >> 8);
    message[11] = (uint8_t)format.greenMax;
    message[12] = (uint8_t)(format.blueMax >> 8);
    message[13] = (uint8_t)format.blueMax;
    message[14] = format.redShift;
    message[15] = format.greenShift;
    message[16] = format.blueShift;
    return WriteToRFBServer(client, (const char *)message, sizeof(message));
}

/* A 256-colour pixel as B, G, R, X, each component stretched to the full 0–255. */
static uint32_t low_colour_table[256];
static pthread_once_t low_colour_once = PTHREAD_ONCE_INIT;

static void build_low_colour_table(void) {
    for (int pixel = 0; pixel < 256; pixel++) {
        uint32_t red = (uint32_t)((pixel >> 5) & 7) * 255 / 7;
        uint32_t green = (uint32_t)((pixel >> 2) & 7) * 255 / 7;
        uint32_t blue = (uint32_t)(pixel & 3) * 255 / 3;
        low_colour_table[pixel] = red << 16 | green << 8 | blue;
    }
}

static void expand_low_colour(const uint8_t *source, uint8_t *destination, size_t count) {
    pthread_once(&low_colour_once, build_low_colour_table);
    for (size_t index = 0; index < count; index++) {
        uint32_t value = low_colour_table[source[index]];
        memcpy(destination + index * 4, &value, 4);
    }
}

/* Copies a rectangle LibVNCClient decoded in 256 colours into the caller's framebuffer. */
static void expand_rect(rfbClient *client, client_state *state, int x, int y, int width, int height) {
    if (!state->low_pixels || !state->pixels) return;
    if (x < 0) { width += x; x = 0; }
    if (y < 0) { height += y; y = 0; }
    if (x + width > client->width) width = client->width - x;
    if (y + height > client->height) height = client->height - y;
    for (int row = y; row < y + height; row++) {
        size_t offset = (size_t)row * (size_t)client->width + (size_t)x;
        expand_low_colour(state->low_pixels + offset, state->pixels + offset * 4, (size_t)(width > 0 ? width : 0));
    }
}

/* Storage for the 256-colour framebuffer at the desktop's current size. */
static rfbBool allocate_low_pixels(rfbClient *client, client_state *state) {
    free(state->low_pixels);
    size_t count = (size_t)client->width * (size_t)client->height;
    state->low_pixels = calloc(count > 0 ? count : 1, 1);
    return state->low_pixels != NULL;
}

/* Points LibVNCClient at a framebuffer in the format updates are now decoded in. Into 256 colours
   the picture so far is reduced too, so that CopyRect still copies what is on the screen. */
static void adopt_format(rfbClient *client, client_state *state) {
    if (state->low_colour) {
        size_t count = (size_t)client->width * (size_t)client->height;
        if (state->pixels) {
            for (size_t index = 0; index < count; index++) {
                const uint8_t *pixel = state->pixels + index * 4;
                state->low_pixels[index] = (uint8_t)((pixel[2] >> 5) << 5 | (pixel[1] >> 5) << 2 | pixel[0] >> 6);
            }
        }
        client->frameBuffer = state->low_pixels;
    } else {
        client->frameBuffer = state->pixels;
        free(state->low_pixels);
        state->low_pixels = NULL;
    }
    set_format(&client->format, state->low_colour);
}

// MARK: - Update requests

/* An update in flight when the server takes a SetPixelFormat is still in the old format, so the
   client must know of every update in flight when it changes format. It does by keeping exactly one
   request outstanding: the shim asks for the next update at the end of each one, and LibVNCClient's
   own requests (after every update, and in the middle of one after a DesktopSize) are held back by
   keeping `requestedResize` set, which makes it skip them. LibVNCClient clears the flag when an
   ExtendedDesktopSize arrives; if that was the update's last rectangle, the library asks for the
   next update itself and the shim does not.

   A request asked for outside that rhythm (`marionette_vnc_request_update`) is needed on a still
   desktop, where the outstanding incremental request may go unanswered for good; but whether a
   server answers both with one update or with two cannot be told, so from then on the colour depth
   stays as it is. */
static void send_request(rfbClient *client, int incremental) {
    client->requestedResize = FALSE;
    SendFramebufferUpdateRequest(client, 0, 0, client->width, client->height, incremental ? TRUE : FALSE);
    client->requestedResize = TRUE;
}

static void update_starting(client_state *state) {
    state->in_update = 1;
    if (state->callbacks.started) state->callbacks.started(state->callbacks.context);
}

/* At the end of an update, with nothing outstanding: the moment to change the format, before the
   next request goes. */
static int can_change_colour(const rfbClient *client, const client_state *state) {
    int version_ok = client->major > 3 || (client->major == 3 && client->minor >= 8);
    return version_ok && !state->requests_uncertain && !state->full_colour_only;
}

static void request_next_update(rfbClient *client, client_state *state) {
    state->in_update = 0;
    if (!client->requestedResize) {
        /* The library asked incrementally; a resize in this update still wants the whole desktop,
           which the shim asks for at the end of the next one. */
        client->requestedResize = TRUE;
        return;
    }
    int incremental = !state->resized_in_update;
    state->resized_in_update = 0;
    /* The 256-colour framebuffer is allocated before the server is told, so that running out of
       memory leaves both in full colour. */
    if (state->wanted_low_colour != state->low_colour && can_change_colour(client, state)
        && (!state->wanted_low_colour || allocate_low_pixels(client, state))) {
        state->low_colour = state->wanted_low_colour;
        send_pixel_format(client, state->low_colour);
        send_encodings(client, state->encodings, state->extended_desktop_size);
        adopt_format(client, state);
        if (!state->low_colour && state->refresh_in_full_colour) incremental = 0;
    }
    send_request(client, incremental);
}

// MARK: - Clipboard

/* Larger clipboard text is skipped. */
#define MAX_CLIPBOARD_TEXT (8u << 20)

static rfbBool send_extended_clipboard(rfbClient *client, const uint8_t *payload, uint32_t length) {
    uint8_t header[8] = {rfbClientCutText, 0, 0, 0};
    /* The extended clipboard is ClientCutText with the length negated. */
    write_u32(&header[4], (uint32_t)0 - length);
    return WriteToRFBServer(client, (const char *)header, sizeof(header))
        && WriteToRFBServer(client, (const char *)payload, length);
}

static rfbBool send_clipboard_flags(rfbClient *client, uint32_t flags) {
    uint8_t payload[4];
    write_u32(payload, flags);
    return send_extended_clipboard(client, payload, sizeof(payload));
}

static rfbBool send_clipboard_caps(rfbClient *client) {
    uint8_t payload[8];
    write_u32(payload, rfbExtendedClipboard_Caps | rfbExtendedClipboard_Text | rfbExtendedClipboard_Request
              | rfbExtendedClipboard_Peek | rfbExtendedClipboard_Notify | rfbExtendedClipboard_Provide);
    /* The largest text accepted. */
    write_u32(&payload[4], MAX_CLIPBOARD_TEXT);
    return send_extended_clipboard(client, payload, sizeof(payload));
}

static rfbBool send_clipboard_provide(rfbClient *client, const client_state *state) {
    uint32_t plain_length = 4 + state->clipboard_length;
    uint8_t *plain = malloc(plain_length);
    uLong bound = compressBound(plain_length) + 64;
    uint8_t *payload = malloc(4 + bound);
    rfbBool sent = FALSE;
    if (plain && payload) {
        write_u32(plain, state->clipboard_length);
        memcpy(plain + 4, state->clipboard, state->clipboard_length);
        z_stream stream = {0};
        if (deflateInit(&stream, Z_DEFAULT_COMPRESSION) == Z_OK) {
            stream.next_in = plain;
            stream.avail_in = plain_length;
            stream.next_out = payload + 4;
            stream.avail_out = (uInt)bound;
            /* A sync flush rather than the end of the stream: many servers (LibVNCServer among
               them) do not expect inflate to report the end, as LibVNCClient's own sender notes. */
            int result = deflate(&stream, Z_SYNC_FLUSH);
            uint32_t compressed = (uint32_t)stream.total_out;
            deflateEnd(&stream);
            if (result == Z_OK && stream.avail_in == 0) {
                write_u32(payload, rfbExtendedClipboard_Provide | rfbExtendedClipboard_Text);
                sent = send_extended_clipboard(client, payload, 4 + compressed);
            }
        }
    }
    free(plain);
    free(payload);
    return sent;
}

static int inflate_exactly(z_stream *stream, uint8_t *output, uint32_t length) {
    stream->next_out = output;
    stream->avail_out = length;
    while (stream->avail_out > 0) {
        int result = inflate(stream, Z_SYNC_FLUSH);
        if (result == Z_STREAM_END) break;
        if (result != Z_OK) return 0;
    }
    return stream->avail_out == 0;
}

/* A Provide: zlib data holding, for each format in it, a length and the bytes. Text comes first. */
static void deliver_provided_text(rfbClient *client, const uint8_t *data, uint32_t length) {
    marionette_vnc_callbacks *callbacks = callbacks_of(client);
    z_stream stream = {0};
    if (!callbacks || !callbacks->clipboard || inflateInit(&stream) != Z_OK) return;
    stream.next_in = (Bytef *)data;
    stream.avail_in = length;
    uint8_t size[4];
    if (inflate_exactly(&stream, size, sizeof(size))) {
        uint32_t text_length = read_u32(size);
        uint8_t *text = text_length <= MAX_CLIPBOARD_TEXT ? malloc(text_length + 1) : NULL;
        if (text && inflate_exactly(&stream, text, text_length)) {
            callbacks->clipboard(callbacks->context, (const char *)text, (int)text_length, 1);
        }
        free(text);
    }
    inflateEnd(&stream);
}

/* The extended clipboard (rfbproto's "Extended Clipboard Pseudo-Encoding"), text only. LibVNCClient
   handles a Provide and nothing else, and never sends its own capabilities, so a server that only
   announces its clipboard with Notify would never deliver it. */
static rfbBool handle_extended_clipboard(rfbClient *client, const uint8_t *data, uint32_t length) {
    client_state *state = state_of(client);
    if (!state || length < 4) return TRUE;
    uint32_t flags = read_u32(data);
    if (flags & rfbExtendedClipboard_Caps) {
        state->server_clipboard = flags;
        return send_clipboard_caps(client);
    }
    if (flags & rfbExtendedClipboard_Request) {
        return (flags & rfbExtendedClipboard_Text) && state->clipboard ? send_clipboard_provide(client, state) : TRUE;
    }
    if (flags & rfbExtendedClipboard_Peek) {
        return send_clipboard_flags(client, rfbExtendedClipboard_Notify | (state->clipboard ? rfbExtendedClipboard_Text : 0));
    }
    if (flags & rfbExtendedClipboard_Notify) {
        return flags & rfbExtendedClipboard_Text ? send_clipboard_flags(client, rfbExtendedClipboard_Request | rfbExtendedClipboard_Text) : TRUE;
    }
    if ((flags & rfbExtendedClipboard_Provide) && (flags & rfbExtendedClipboard_Text)) {
        deliver_provided_text(client, data + 4, length - 4);
    }
    return TRUE;
}

static rfbBool skip_bytes(rfbClient *client, uint32_t length) {
    char scratch[4096];
    while (length > 0) {
        uint32_t chunk = length < sizeof(scratch) ? length : (uint32_t)sizeof(scratch);
        if (!ReadFromRFBServer(client, scratch, chunk)) return FALSE;
        length -= chunk;
    }
    return TRUE;
}

/* ServerCutText, classic or extended. The sign of the length tells them apart, which LibVNCClient
   does not pass on, so the shim reads these messages itself. */
static rfbBool handle_cut_text(rfbClient *client) {
    uint8_t header[7];
    if (!ReadFromRFBServer(client, (char *)header, sizeof(header))) return FALSE;
    int32_t signed_length = (int32_t)read_u32(&header[3]);
    int extended = signed_length < 0;
    uint32_t length = extended ? (uint32_t)0 - (uint32_t)signed_length : (uint32_t)signed_length;
    uint8_t *payload = length <= MAX_CLIPBOARD_TEXT ? malloc(length + 1) : NULL;
    if (!payload) return skip_bytes(client, length);
    if (!ReadFromRFBServer(client, (char *)payload, length)) {
        free(payload);
        return FALSE;
    }
    rfbBool handled = TRUE;
    if (extended) {
        handled = handle_extended_clipboard(client, payload, length);
    } else {
        marionette_vnc_callbacks *callbacks = callbacks_of(client);
        if (callbacks && callbacks->clipboard && length > 0) callbacks->clipboard(callbacks->context, (const char *)payload, (int)length, 0);
    }
    free(payload);
    return handled;
}

/* Never called: ServerCutText is read by `handle_cut_text` before LibVNCClient sees it. Setting it
   is what makes LibVNCClient ask for the extended clipboard in its SetEncodings. */
static void on_cut_text_utf8(rfbClient *client, const char *text, int length) {
    (void)client;
    (void)text;
    (void)length;
}

// MARK: - Callbacks

static rfbBool on_malloc_framebuffer(rfbClient *client) {
    client_state *state = state_of(client);
    client->frameBuffer = NULL;
    if (!state || !state->callbacks.resize) return FALSE;
    state->pixels = state->callbacks.resize(state->callbacks.context, client->width, client->height);
    if (!state->pixels) return FALSE;
    if (state->low_colour && !allocate_low_pixels(client, state)) return FALSE;
    client->frameBuffer = state->low_colour ? state->low_pixels : state->pixels;
    /* A new size needs the whole desktop: LibVNCClient's own request for it is held back. */
    if (state->in_update) {
        state->resized_in_update = 1;
    } else if (client->requestedResize) {
        state->resized_outside_update = 1;
    }
    return TRUE;
}

static void on_update(rfbClient *client, int x, int y, int width, int height) {
    client_state *state = state_of(client);
    if (!state) return;
    /* An ExtendedDesktopSize earlier in the update cleared it (see `send_request`). */
    client->requestedResize = TRUE;
    if (state->low_colour) expand_rect(client, state, x, y, width, height);
    if (state->callbacks.update) state->callbacks.update(state->callbacks.context, x, y, width, height);
}

static void on_finished(rfbClient *client) {
    client_state *state = state_of(client);
    if (!state) return;
    review_encodings(client, state);
    request_next_update(client, state);
    if (state->callbacks.finished) state->callbacks.finished(state->callbacks.context);
}

static char *on_password(rfbClient *client) {
    marionette_vnc_callbacks *callbacks = callbacks_of(client);
    return callbacks && callbacks->password ? callbacks->password(callbacks->context) : NULL;
}

static rfbCredential *on_credential(rfbClient *client, int type) {
    marionette_vnc_callbacks *callbacks = callbacks_of(client);
    if (type != rfbCredentialTypeUser || !callbacks || !callbacks->credential) return NULL;
    char *username = NULL;
    char *password = NULL;
    if (!callbacks->credential(callbacks->context, &username, &password)) {
        free(username);
        free(password);
        return NULL;
    }
    rfbCredential *credential = calloc(1, sizeof(rfbCredential));
    if (!credential) {
        free(username);
        free(password);
        return NULL;
    }
    credential->userCredential.username = username ? username : strdup("");
    credential->userCredential.password = password ? password : strdup("");
    return credential;
}

static void on_cursor(rfbClient *client, int hotspot_x, int hotspot_y, int width, int height, int bytes_per_pixel) {
    marionette_vnc_callbacks *callbacks = callbacks_of(client);
    if (!callbacks || !callbacks->cursor || !client->rcSource || !client->rcMask || width <= 0 || height <= 0) return;
    if (bytes_per_pixel == 4) {
        callbacks->cursor(callbacks->context, hotspot_x, hotspot_y, width, height, client->rcSource, client->rcMask);
    } else if (bytes_per_pixel == 1) {
        size_t count = (size_t)width * (size_t)height;
        uint8_t *pixels = malloc(count * 4);
        if (!pixels) return;
        expand_low_colour(client->rcSource, pixels, count);
        callbacks->cursor(callbacks->context, hotspot_x, hotspot_y, width, height, pixels, client->rcMask);
        free(pixels);
    }
}

static void on_bell(rfbClient *client) {
    marionette_vnc_callbacks *callbacks = callbacks_of(client);
    if (callbacks && callbacks->bell) callbacks->bell(callbacks->context);
}

// MARK: - Lifecycle

marionette_vnc_client *marionette_vnc_create(const marionette_vnc_callbacks *callbacks) {
    pthread_once(&log_once, install_log_hooks);
    last_error[0] = '\0';
    rfbClient *client = rfbGetClient(8, 3, 4);
    if (!client) return NULL;
    client_state *state = calloc(1, sizeof(client_state));
    if (!state) {
        rfbClientCleanup(client);
        return NULL;
    }
    state->callbacks = *callbacks;
    state->extended_desktop_size = 1;
    state->quality_level = -1;
    rfbClientSetClientData(client, &state_tag, state);

    set_format(&client->format, 0);

    client->canHandleNewFBSize = TRUE;
    client->appData.useRemoteCursor = TRUE;
    client->MallocFrameBuffer = on_malloc_framebuffer;
    client->GotFrameBufferUpdate = on_update;
    client->FinishedFrameBufferUpdate = on_finished;
    client->GetPassword = on_password;
    client->GetCredential = on_credential;
    client->GotCursorShape = on_cursor;
    client->Bell = on_bell;
    client->GotXCutTextUTF8 = on_cut_text_utf8;
    return (marionette_vnc_client *)client;
}

void marionette_vnc_set_encodings(marionette_vnc_client *handle, const char *encodings, int compress_level, int quality_level) {
    rfbClient *client = &handle->rfb;
    client_state *state = state_of(client);
    free(state->encodings);
    state->encodings = strdup(encodings);
    client->appData.encodingsString = state->encodings;
    client->appData.compressLevel = compress_level;
    /* Without JPEG LibVNCClient would still ask for a quality, level 5. */
    client->appData.enableJPEG = quality_level >= 0 ? TRUE : FALSE;
    client->appData.qualityLevel = quality_level;
    state->quality_level = quality_level < 0 ? -1 : quality_level;
}

int marionette_vnc_set_quality(marionette_vnc_client *handle, int quality_level) {
    rfbClient *client = &handle->rfb;
    client_state *state = state_of(client);
    if (quality_level < 0) quality_level = -1;
    if (state->quality_level == quality_level) return 1;
    state->quality_level = quality_level;
    client->appData.enableJPEG = quality_level >= 0 ? TRUE : FALSE;
    client->appData.qualityLevel = quality_level;
    return send_encodings(client, state->encodings, state->extended_desktop_size) ? 1 : 0;
}

int marionette_vnc_set_full_colour(marionette_vnc_client *handle, int full_colour, int refresh) {
    client_state *state = state_of(&handle->rfb);
    /* Before the handshake the server's version is not known, and the wish is kept for it. */
    if (handle->rfb.major != 0 && !can_change_colour(&handle->rfb, state)) return 0;
    state->wanted_low_colour = full_colour ? 0 : 1;
    state->refresh_in_full_colour = refresh;
    return 1;
}

void marionette_vnc_keep_full_colour(marionette_vnc_client *handle) {
    client_state *state = state_of(&handle->rfb);
    state->full_colour_only = 1;
    state->wanted_low_colour = 0;
}

int marionette_vnc_can_change_colour(const marionette_vnc_client *handle) {
    return can_change_colour(&handle->rfb, state_of((rfbClient *)&handle->rfb));
}

static void free_state(client_state *state) {
    if (!state) return;
    free(state->encodings);
    free(state->clipboard);
    free(state->low_pixels);
    free(state);
}

int marionette_vnc_connect(marionette_vnc_client *handle, int socket, int shared) {
    rfbClient *client = &handle->rfb;
    last_error[0] = '\0';
    last_reason[0] = '\0';
    last_failure = MARIONETTE_VNC_FAILURE_OTHER;
    refused_before_authentication = 0;
    server_major = server_minor = 0;
    /* LibVNCClient closes its socket when it gives up, and the caller closes the one it passed:
       each closes its own descriptor, so neither can close a number that has since been reused. */
    int own = dup(socket);
    if (own < 0) {
        snprintf(last_error, sizeof(last_error), "could not duplicate the socket");
        free_state(state_of(client));
        rfbClientCleanup(client);
        return 0;
    }
    int one = 1;
    setsockopt(own, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    client->sock = own;
    /* "Listening" is how LibVNCClient is told the socket is already connected. */
    client->listenSpecified = TRUE;
    client->appData.shareDesktop = shared ? TRUE : FALSE;
    client_state *state = state_of(client);
    /* rfbInitClient frees the client when it fails, so the state must not go down with it unseen. */
    if (!rfbInitClient(client, NULL, NULL)) {
        free_state(state);
        return 0;
    }
    /* From here on these describe how the session ended. */
    last_error[0] = '\0';
    /* rfbInitClient has asked for the first update; the shim asks for the rest (see `send_request`). */
    client->requestedResize = TRUE;
    return 1;
}

int marionette_vnc_width(const marionette_vnc_client *handle) { return handle->rfb.width; }
int marionette_vnc_height(const marionette_vnc_client *handle) { return handle->rfb.height; }
const char *marionette_vnc_desktop_name(const marionette_vnc_client *handle) {
    return handle->rfb.desktopName ? handle->rfb.desktopName : "";
}

int marionette_vnc_wait(marionette_vnc_client *handle, int wake_fd, int timeout_ms) {
    rfbClient *client = &handle->rfb;
    /* Bytes LibVNCClient has already read ahead will not show up in poll(). */
    if (client->buffered > 0) return 1;
    struct pollfd descriptors[2] = {
        {.fd = client->sock, .events = POLLIN},
        {.fd = wake_fd, .events = POLLIN},
    };
    int ready = poll(descriptors, 2, timeout_ms);
    if (ready < 0) return -1;
    int result = 0;
    if (descriptors[0].revents & (POLLIN | POLLHUP | POLLERR)) result |= 1;
    if (descriptors[1].revents & POLLIN) result |= 2;
    return result;
}

/* One server message. The type byte is read here, so ServerCutText can be handled by the shim;
   any other type is given back for LibVNCClient. ReadFromRFBServer always leaves what it returned
   in the client's read-ahead buffer, just behind the read position, so giving it back is moving
   that position one byte back. */
static rfbBool handle_message(rfbClient *client) {
    uint8_t type;
    if (!ReadFromRFBServer(client, (char *)&type, 1)) return FALSE;
    if (type == rfbServerCutText) return handle_cut_text(client);
    client->bufoutptr--;
    client->buffered++;
    client_state *state = state_of(client);
    if (!state) return HandleRFBServerMessage(client);
    if (type == rfbFramebufferUpdate) update_starting(state);
    if (!HandleRFBServerMessage(client)) return FALSE;
    /* UltraVNC's resize messages come between updates, and LibVNCClient's request for the new
       desktop was held back. */
    if (state->resized_outside_update) {
        state->resized_outside_update = 0;
        state->requests_uncertain = 1;
        send_request(client, 0);
    }
    return TRUE;
}

long marionette_vnc_unread_bytes(const marionette_vnc_client *handle) {
    int pending = 0;
    if (ioctl(handle->rfb.sock, FIONREAD, &pending) != 0) pending = 0;
    return (long)pending + (handle->rfb.buffered > 0 ? handle->rfb.buffered : 0);
}

int marionette_vnc_process(marionette_vnc_client *handle) {
    rfbClient *client = &handle->rfb;
    for (;;) {
        /* WaitForMessage only looks at the socket; bytes already read ahead count as well. */
        if (client->buffered <= 0) {
            int ready = WaitForMessage(client, 0);
            if (ready < 0) return 0;
            if (ready == 0) return 1;
        }
        if (!handle_message(client)) return 0;
    }
}

int marionette_vnc_send_key(marionette_vnc_client *handle, uint32_t keysym, int down) {
    return SendKeyEvent(&handle->rfb, keysym, down ? TRUE : FALSE) ? 1 : 0;
}

int marionette_vnc_send_pointer(marionette_vnc_client *handle, int x, int y, int button_mask) {
    return SendPointerEvent(&handle->rfb, x, y, button_mask) ? 1 : 0;
}

int marionette_vnc_send_clipboard(marionette_vnc_client *handle, const char *utf8, int utf8_length, const char *latin1, int latin1_length) {
    rfbClient *client = &handle->rfb;
    client_state *state = state_of(client);
    uint32_t extended = state->server_clipboard;
    if (!(extended & rfbExtendedClipboard_Text) || !(extended & (rfbExtendedClipboard_Notify | rfbExtendedClipboard_Provide))) {
        return SendClientCutText(client, (char *)latin1, latin1_length) ? 1 : 0;
    }
    /* The extended clipboard's text has CR LF line ends and a terminating NUL. */
    size_t line_feeds = 0;
    for (int i = 0; i < utf8_length; i++) {
        if (utf8[i] == '\n' && (i == 0 || utf8[i - 1] != '\r')) line_feeds++;
    }
    char *text = malloc((size_t)utf8_length + line_feeds + 1);
    if (!text) return 0;
    size_t length = 0;
    for (int i = 0; i < utf8_length; i++) {
        if (utf8[i] == '\n' && (i == 0 || utf8[i - 1] != '\r')) text[length++] = '\r';
        text[length++] = utf8[i];
    }
    text[length++] = '\0';
    free(state->clipboard);
    state->clipboard = text;
    state->clipboard_length = (uint32_t)length;
    /* A server that can be told the clipboard changed asks for the text when it wants it. */
    if (extended & rfbExtendedClipboard_Notify) {
        return send_clipboard_flags(client, rfbExtendedClipboard_Notify | rfbExtendedClipboard_Text) ? 1 : 0;
    }
    return send_clipboard_provide(client, state) ? 1 : 0;
}

int marionette_vnc_request_update(marionette_vnc_client *handle, int x, int y, int width, int height, int incremental) {
    rfbClient *client = &handle->rfb;
    client_state *state = state_of(client);
    /* One request beyond the one kept outstanding (see `send_request`). */
    state->requests_uncertain = 1;
    client->requestedResize = FALSE;
    rfbBool sent = SendFramebufferUpdateRequest(client, x, y, width, height, incremental ? TRUE : FALSE);
    client->requestedResize = TRUE;
    return sent ? 1 : 0;
}

void marionette_vnc_destroy(marionette_vnc_client *handle) {
    rfbClient *client = &handle->rfb;
    free_state(state_of(client));
    rfbClientSetClientData(client, &state_tag, NULL);
    /* The framebuffer belongs to the caller; the socket is LibVNCClient's own duplicate and goes
       with it. */
    client->frameBuffer = NULL;
    rfbClientCleanup(client);
}
