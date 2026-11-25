/*
 * Copyright © 2026 Turing Software, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * libssh2's public API, plus plain functions for the parts of it that are function-like macros,
 * which Swift cannot call.
 */
#ifndef MARIONETTE_CLIBSSH2_H
#define MARIONETTE_CLIBSSH2_H

#include "../libssh2/include/libssh2.h"
#include "../libssh2/include/libssh2_sftp.h"

LIBSSH2_SESSION *marionette_ssh2_session_init(void *abstract);
int marionette_ssh2_session_disconnect(LIBSSH2_SESSION *session, const char *description);
int marionette_ssh2_userauth_password(LIBSSH2_SESSION *session, const char *username, const char *password);
int marionette_ssh2_userauth_keyboard_interactive(LIBSSH2_SESSION *session, const char *username,
                                           LIBSSH2_USERAUTH_KBDINT_RESPONSE_FUNC((*callback)));
LIBSSH2_CHANNEL *marionette_ssh2_channel_open_session(LIBSSH2_SESSION *session);
LIBSSH2_CHANNEL *marionette_ssh2_channel_direct_tcpip(LIBSSH2_SESSION *session, const char *host, int port,
                                                      const char *source_host, int source_port, unsigned int window_size);
int marionette_ssh2_channel_exec(LIBSSH2_CHANNEL *channel, const char *command);
ssize_t marionette_ssh2_channel_read(LIBSSH2_CHANNEL *channel, int stream, char *buffer, size_t length);
ssize_t marionette_ssh2_channel_write(LIBSSH2_CHANNEL *channel, const char *buffer, size_t length);
LIBSSH2_SFTP_HANDLE *marionette_ssh2_sftp_open(LIBSSH2_SFTP *sftp, const char *path, unsigned long flags, long mode);
LIBSSH2_SFTP_HANDLE *marionette_ssh2_sftp_opendir(LIBSSH2_SFTP *sftp, const char *path);
int marionette_ssh2_sftp_readdir(LIBSSH2_SFTP_HANDLE *handle, char *buffer, size_t length, LIBSSH2_SFTP_ATTRIBUTES *attributes);
int marionette_ssh2_sftp_stat(LIBSSH2_SFTP *sftp, const char *path, LIBSSH2_SFTP_ATTRIBUTES *attributes);
int marionette_ssh2_sftp_mkdir(LIBSSH2_SFTP *sftp, const char *path, long mode);
int marionette_ssh2_sftp_rmdir(LIBSSH2_SFTP *sftp, const char *path);
int marionette_ssh2_sftp_unlink(LIBSSH2_SFTP *sftp, const char *path);
int marionette_ssh2_sftp_rename(LIBSSH2_SFTP *sftp, const char *source, const char *destination);
int marionette_ssh2_sftp_realpath(LIBSSH2_SFTP *sftp, const char *path, char *target, unsigned int length);

#endif
