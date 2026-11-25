/*
 * Copyright © 2026 Turing Software, LLC
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdlib.h>
#include <string.h>
#include "../include/CLibSSH2.h"

LIBSSH2_SESSION *marionette_ssh2_session_init(void *abstract) {
    return libssh2_session_init_ex(NULL, NULL, NULL, abstract);
}

int marionette_ssh2_session_disconnect(LIBSSH2_SESSION *session, const char *description) {
    return libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, description, "");
}

int marionette_ssh2_userauth_password(LIBSSH2_SESSION *session, const char *username, const char *password) {
    return libssh2_userauth_password_ex(session, username, (unsigned int)strlen(username),
                                        password, (unsigned int)strlen(password), NULL);
}

int marionette_ssh2_userauth_keyboard_interactive(LIBSSH2_SESSION *session, const char *username,
                                           LIBSSH2_USERAUTH_KBDINT_RESPONSE_FUNC((*callback))) {
    return libssh2_userauth_keyboard_interactive_ex(session, username, (unsigned int)strlen(username), callback);
}

LIBSSH2_CHANNEL *marionette_ssh2_channel_open_session(LIBSSH2_SESSION *session) {
    return libssh2_channel_open_ex(session, "session", sizeof("session") - 1,
                                   LIBSSH2_CHANNEL_WINDOW_DEFAULT, LIBSSH2_CHANNEL_PACKET_DEFAULT, NULL, 0);
}

static void store_u32(unsigned char **cursor, uint32_t value) {
    (*cursor)[0] = (unsigned char)(value >> 24);
    (*cursor)[1] = (unsigned char)(value >> 16);
    (*cursor)[2] = (unsigned char)(value >> 8);
    (*cursor)[3] = (unsigned char)value;
    *cursor += 4;
}

static void store_string(unsigned char **cursor, const char *text, size_t length) {
    store_u32(cursor, (uint32_t)length);
    memcpy(*cursor, text, length);
    *cursor += length;
}

/*
 * libssh2_channel_direct_tcpip_ex with a receive window of the caller's choosing; libssh2's own
 * always asks for LIBSSH2_CHANNEL_WINDOW_DEFAULT (2 MiB). The request body is the one RFC 4254
 * section 7.2 gives, built as libssh2 builds it. Call again with the same arguments after
 * LIBSSH2_ERROR_EAGAIN, as with any non-blocking libssh2 call; libssh2 does not keep the body.
 */
LIBSSH2_CHANNEL *marionette_ssh2_channel_direct_tcpip(LIBSSH2_SESSION *session, const char *host, int port,
                                                      const char *source_host, int source_port, unsigned int window_size) {
    size_t host_length = strlen(host);
    size_t source_length = strlen(source_host);
    size_t length = host_length + source_length + 16;
    unsigned char *message = malloc(length);
    if (!message) {
        return NULL;
    }
    unsigned char *cursor = message;
    store_string(&cursor, host, host_length);
    store_u32(&cursor, (uint32_t)port);
    store_string(&cursor, source_host, source_length);
    store_u32(&cursor, (uint32_t)source_port);
    LIBSSH2_CHANNEL *channel = libssh2_channel_open_ex(session, "direct-tcpip", sizeof("direct-tcpip") - 1, window_size,
                                                       LIBSSH2_CHANNEL_PACKET_DEFAULT, (const char *)message, (unsigned int)length);
    free(message);
    return channel;
}

int marionette_ssh2_channel_exec(LIBSSH2_CHANNEL *channel, const char *command) {
    return libssh2_channel_process_startup(channel, "exec", sizeof("exec") - 1, command, (unsigned int)strlen(command));
}

ssize_t marionette_ssh2_channel_read(LIBSSH2_CHANNEL *channel, int stream, char *buffer, size_t length) {
    return libssh2_channel_read_ex(channel, stream, buffer, length);
}

ssize_t marionette_ssh2_channel_write(LIBSSH2_CHANNEL *channel, const char *buffer, size_t length) {
    return libssh2_channel_write_ex(channel, 0, buffer, length);
}

LIBSSH2_SFTP_HANDLE *marionette_ssh2_sftp_open(LIBSSH2_SFTP *sftp, const char *path, unsigned long flags, long mode) {
    return libssh2_sftp_open_ex(sftp, path, (unsigned int)strlen(path), flags, mode, LIBSSH2_SFTP_OPENFILE);
}

LIBSSH2_SFTP_HANDLE *marionette_ssh2_sftp_opendir(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_open_ex(sftp, path, (unsigned int)strlen(path), 0, 0, LIBSSH2_SFTP_OPENDIR);
}

int marionette_ssh2_sftp_readdir(LIBSSH2_SFTP_HANDLE *handle, char *buffer, size_t length, LIBSSH2_SFTP_ATTRIBUTES *attributes) {
    return libssh2_sftp_readdir_ex(handle, buffer, length, NULL, 0, attributes);
}

int marionette_ssh2_sftp_stat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attributes) {
    return libssh2_sftp_stat_ex(sftp, path, (unsigned int)strlen(path), LIBSSH2_SFTP_STAT, attributes);
}

int marionette_ssh2_sftp_mkdir(LIBSSH2_SFTP *sftp, const char *path, long mode) {
    return libssh2_sftp_mkdir_ex(sftp, path, (unsigned int)strlen(path), mode);
}

int marionette_ssh2_sftp_rmdir(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_rmdir_ex(sftp, path, (unsigned int)strlen(path));
}

int marionette_ssh2_sftp_unlink(LIBSSH2_SFTP *sftp, const char *path) {
    return libssh2_sftp_unlink_ex(sftp, path, (unsigned int)strlen(path));
}

int marionette_ssh2_sftp_rename(LIBSSH2_SFTP *sftp, const char *source, const char *destination) {
    return libssh2_sftp_rename_ex(sftp, source, (unsigned int)strlen(source), destination, (unsigned int)strlen(destination),
                                  LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE);
}

int marionette_ssh2_sftp_realpath(LIBSSH2_SFTP *sftp, const char *path, char *target, unsigned int length) {
    return libssh2_sftp_symlink_ex(sftp, path, (unsigned int)strlen(path), target, length, LIBSSH2_SFTP_REALPATH);
}
