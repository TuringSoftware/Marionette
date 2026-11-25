/*
 * Copyright © 2026 Turing Software, LLC
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The part of the TurboJPEG API that LibVNCClient's Tight decoder calls, on the system's own JPEG
 * decoder. Tight sends photographic areas as JPEG; with this, the Tight encoding (the one most
 * servers compress best with) needs no JPEG library of its own.
 */
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include "turbojpeg.h"
#include "../include/CLibVNCClient.h"

static _Thread_local char jpeg_error[128];

/* LibVNCClient only checks the handle for NULL and passes it back; there is no decoder state. */
static char decompressor;

tjhandle tjInitDecompress(void) {
    return &decompressor;
}

int tjDestroy(tjhandle handle) {
    (void)handle;
    return 0;
}

char *tjGetErrorStr(void) {
    return jpeg_error;
}

int tjDecompress(tjhandle handle, unsigned char *jpegBuf, unsigned long jpegSize, unsigned char *dstBuf,
                 int width, int pitch, int height, int pixelSize, int flags) {
    (void)handle;
    /* The client asks the server for 32-bit little-endian pixels, so Tight wants four bytes a
       pixel, blue first, with the padding byte last. */
    if (pixelSize != 4 || (flags & TJ_ALPHAFIRST)) {
        snprintf(jpeg_error, sizeof(jpeg_error), "unsupported pixel layout (%d bytes, flags %d)", pixelSize, flags);
        return -1;
    }
    return marionette_vnc_decode_jpeg(jpegBuf, jpegSize, dstBuf, width, height, pitch, (flags & TJ_BGR) != 0) ? 0 : -1;
}

int marionette_vnc_decode_jpeg(const uint8_t *jpeg, unsigned long length, uint8_t *pixels, int width, int height, int bytes_per_row, int blue_first) {
    jpeg_error[0] = '\0';
    if (!jpeg || !pixels || width <= 0 || height <= 0 || bytes_per_row < width * 4) {
        snprintf(jpeg_error, sizeof(jpeg_error), "bad arguments");
        return 0;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, jpeg, length, NULL);
    CGImageRef image = provider ? CGImageCreateWithJPEGDataProvider(provider, NULL, false, kCGRenderingIntentDefault) : NULL;
    CGDataProviderRelease(provider);
    if (!image) {
        snprintf(jpeg_error, sizeof(jpeg_error), "not a JPEG image");
        return 0;
    }
    if ((int)CGImageGetWidth(image) != width || (int)CGImageGetHeight(image) != height) {
        snprintf(jpeg_error, sizeof(jpeg_error), "JPEG is %zu × %zu, not %d × %d", CGImageGetWidth(image), CGImageGetHeight(image), width, height);
        CGImageRelease(image);
        return 0;
    }
    /* Drawing in the image's own colour space keeps the server's values as they are; a grey image
       (no colour space of three components) is drawn into device RGB. */
    CGColorSpaceRef space = CGImageGetColorSpace(image);
    CGColorSpaceRef device = NULL;
    if (!space || CGColorSpaceGetNumberOfComponents(space) != 3) {
        device = CGColorSpaceCreateDeviceRGB();
        space = device;
    }
    CGBitmapInfo layout = blue_first
        ? (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little
        : (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(pixels, (size_t)width, (size_t)height, 8, (size_t)bytes_per_row, space, layout);
    CGColorSpaceRelease(device);
    if (!context) {
        snprintf(jpeg_error, sizeof(jpeg_error), "could not draw into the framebuffer");
        CGImageRelease(image);
        return 0;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(context, kCGInterpolationNone);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGImageRelease(image);
    return 1;
}
