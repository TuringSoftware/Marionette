// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// Reads strings out of a system framework. Frameworks live in the dyld shared cache, not on disk,
// so this loads one and reads it in memory. Addresses in and out are unslid, as `dyld_info
// -disassemble <path>` prints them.
//
//   cc -o dyldread dyldread.c
//   dyldread find <framework binary> <text>…      strings containing any text, with their addresses
//   dyldread at <framework binary> <address>…     the C string at each address
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: dyldread find|at <framework binary> <text or address>…\n");
        return 64;
    }
    const char *command = argv[1], *path = argv[2];
    if (!dlopen(path, RTLD_LAZY)) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), path) == 0) {
            header = (const void *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!header) {
        fprintf(stderr, "%s is not among the loaded images; give the binary's full path\n", path);
        return 1;
    }

    if (strcmp(command, "find") == 0) {
        const char *sections[] = {"__cstring", "__oslogstring"};
        for (int s = 0; s < 2; s++) {
            unsigned long size;
            uint8_t *data = getsectiondata(header, "__TEXT", sections[s], &size);
            if (!data) continue;
            for (int a = 3; a < argc; a++) {
                uint8_t *hit = data;
                while ((hit = memmem(hit, size - (hit - data), argv[a], strlen(argv[a])))) {
                    uint8_t *start = hit;
                    while (start > data && start[-1]) start--;
                    printf("%s %llx: %s\n", sections[s], (unsigned long long)((uintptr_t)start - slide), start);
                    hit += strlen((char *)hit) + 1;
                    if (hit >= data + size) break;
                }
            }
        }
    } else if (strcmp(command, "at") == 0) {
        for (int a = 3; a < argc; a++) {
            printf("%s: \"%s\"\n", argv[a], (char *)(strtoull(argv[a], NULL, 16) + slide));
        }
    } else {
        fprintf(stderr, "unknown command %s\n", command);
        return 64;
    }
    return 0;
}
