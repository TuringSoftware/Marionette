/*
 * Copyright © 2026 Turing Software, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Build configuration for libssh2 on Apple platforms, written by hand in place of the one its
 * CMake build would generate. Crypto comes from OpenSSL.
 */
#ifndef MARIONETTE_LIBSSH2_CONFIG_H
#define MARIONETTE_LIBSSH2_CONFIG_H

#define LIBSSH2_OPENSSL 1

#define HAVE_UNISTD_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_UN_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_STRTOLL 1
#define HAVE_SNPRINTF 1
#define HAVE_MEMSET_S 1
#define HAVE_POLL 1
#define HAVE_SELECT 1
#define HAVE_O_NONBLOCK 1

#endif
