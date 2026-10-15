// SPDX-License-Identifier: MIT
//
// The player's zip reader (firmware/apps/nes_bench/cart_zip.c) on the PC:
// each .zip named on the command line is unpacked and, where a .nes of the
// same name sits beside it, compared with it byte for byte; a file that is
// not a zip, and refusals, are reported.  Exit 1 on any refusal or mismatch.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cart_zip.h"

static unsigned char *slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	unsigned char *p = malloc(n > 0 ? (size_t)n : 1);
	if (p && fread(p, 1, (size_t)n, f) != (size_t)n) {
		free(p);
		p = NULL;
	}
	fclose(f);
	*len = (size_t)n;
	return p;
}

int main(int argc, char **argv)
{
	int ok = 0, compared = 0, bad = 0;
	for (int i = 1; i < argc; i++) {
		size_t zlen = 0;
		unsigned char *zip = slurp(argv[i], &zlen);
		if (!zip || !cart_is_zip(zip, zlen)) {
			printf("NOT A ZIP %s\n", argv[i]);
			bad++;
			free(zip);
			continue;
		}
		unsigned char *nes = NULL;
		size_t len = 0;
		char name[256];
		const char *why = cart_unzip(zip, zlen, 2u << 20, &nes, &len, name, sizeof name);
		if (why) {
			printf("REFUSED %s: %s\n", argv[i], why);
			bad++;
			free(zip);
			continue;
		}
		char twin[4096];
		snprintf(twin, sizeof twin, "%.*s.nes", (int)(strlen(argv[i]) - 4), argv[i]);
		size_t tlen = 0;
		unsigned char *ref = slurp(twin, &tlen);
		if (ref) {
			compared++;
			if (tlen != len || memcmp(ref, nes, len)) {
				printf("DIFFERS %s\n", argv[i]);
				bad++;
			}
		}
		ok++;
		free(ref);
		free(nes);
		free(zip);
	}
	printf("%d unpacked, %d compared with their .nes, %d bad\n", ok, compared, bad);
	return bad != 0;
}
