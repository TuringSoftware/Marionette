/*
 * Copyright © 2026 Turing Software, LLC
 * SPDX-License-Identifier: Apache-2.0
 *
 * Build configuration for libsrtp on Apple platforms, written by hand in place of the one its
 * CMake or autoconf build would generate. Internal crypto only: AES-ICM and HMAC-SHA1, no external
 * crypto library.
 */
#ifndef MARIONETTE_LIBSRTP_CONFIG_H
#define MARIONETTE_LIBSRTP_CONFIG_H

#define PACKAGE_VERSION "2.8.2"
#define PACKAGE_STRING "libsrtp2 2.8.2"

/* Assume cheap unaligned byte access; true of every Apple CPU. */
#define CPU_CISC 1

#define HAVE_ARPA_INET_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_MACHINE_TYPES_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_INET_ATON 1
#define HAVE_INET_PTON 1
#define HAVE_SIGACTION 1
#define HAVE_USLEEP 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1
#define HAVE_INT32_T 1
#define HAVE_INLINE 1

#define SIZEOF_UNSIGNED_LONG 8
#define SIZEOF_UNSIGNED_LONG_LONG 8

#endif
