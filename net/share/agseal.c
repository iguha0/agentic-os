/*
 * agseal — AgentoNet private-share sealing via libsodium
 * ======================================================
 * Anonymous sealed boxes (crypto_box_seal): anyone can encrypt to your
 * public key; only you can open. Ephemeral X25519 + XSalsa20-Poly1305.
 *
 *   agseal seal   <file> <recipient_pubkey_b64> <outfile>
 *   agseal open   <sealed_file> <outfile>
 *   agseal pubkey                        print this device's enc pubkey (b64)
 *
 * Keypair lives at /usr/share/agentic/identity/enc.{skey,spk,addr}
 * (generated on first use; separate from the ed25519 signing identity).
 *
 * Build:
 *   aarch64-linux-musl-gcc -static -O2 -o agseal agseal.c \
 *       -I<install>/include <install>/lib/libsodium.a -lpthread
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sodium.h>

#ifndef AGENTIC_ID_DIR
#define AGENTIC_ID_DIR "/usr/share/agentic/identity"
#endif
#define ID_DIR   (getenv("AGENTIC_IDENTITY_DIR") ? getenv("AGENTIC_IDENTITY_DIR") : AGENTIC_ID_DIR)
#define SKEY_F   (snprintf(path_buf, sizeof path_buf, "%s/enc.skey", ID_DIR), path_buf)
#define SPK_F    (snprintf(path_buf, sizeof path_buf, "%s/enc.spk",  ID_DIR), path_buf)
#define ADDR_F   (snprintf(path_buf, sizeof path_buf, "%s/enc.addr", ID_DIR), path_buf)

static char path_buf[512];

static unsigned char skey[crypto_box_SECRETKEYBYTES];
static unsigned char spk[crypto_box_PUBLICKEYBYTES];

static int load_or_make_keypair(void) {
    FILE *f;
    mkdir(ID_DIR, 0700);

    f = fopen(SKEY_F, "rb");
    if (f) {
        if (fread(skey, 1, sizeof skey, f) != sizeof skey) { fclose(f); return -1; }
        fclose(f);
        f = fopen(SPK_F, "rb");
        if (!f) return -1;
        if (fread(spk, 1, sizeof spk, f) != sizeof spk) { fclose(f); return -1; }
        fclose(f);
        return 0;
    }

    crypto_box_keypair(spk, skey);
    f = fopen(SKEY_F, "wb");  if (!f || fwrite(skey, 1, sizeof skey, f) != sizeof skey) return -1;
    fclose(f); chmod(SKEY_F, 0600);
    f = fopen(SPK_F, "wb");   if (!f || fwrite(spk, 1, sizeof spk, f) != sizeof spk) return -1;
    fclose(f);
    return 0;
}

static void export_addr(void) {
    char b64[64];
    size_t b64len;
    sodium_bin2base64(b64, sizeof b64, spk, sizeof spk, sodium_base64_VARIANT_ORIGINAL);
    FILE *f = fopen(ADDR_F, "w");
    if (f) { fprintf(f, "%s\n", b64); fclose(f); }
    (void)b64len;
}

static int b64_decode(const char *in, unsigned char *out, size_t outlen) {
    size_t binlen;
    if (sodium_base642bin(out, outlen, in, strlen(in), NULL, &binlen, NULL,
                          sodium_base64_VARIANT_ORIGINAL) != 0) return -1;
    return (int)binlen;
}

static unsigned char *read_all(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return NULL; }
    unsigned char *buf = malloc(sz);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, sz, f) != (size_t)sz) { free(buf); fclose(f); return NULL; }
    fclose(f);
    *len = sz;
    return buf;
}

static int cmd_seal(const char *file, const char *pub_b64, const char *out) {
    unsigned char rpk[crypto_box_PUBLICKEYBYTES];
    if (b64_decode(pub_b64, rpk, sizeof rpk) != crypto_box_PUBLICKEYBYTES) {
        fprintf(stderr, "agseal: bad recipient pubkey (need 32-byte base64)\n");
        return 1;
    }
    size_t plen;
    unsigned char *plain = read_all(file, &plen);
    if (!plain) { perror("read"); return 1; }

    size_t clen = crypto_box_SEALBYTES + plen;
    unsigned char *cipher = malloc(clen);
    if (!cipher) return 1;

    if (crypto_box_seal(cipher, plain, (unsigned long long)plen, rpk) != 0) {
        fprintf(stderr, "agseal: seal failed\n");
        return 1;
    }
    FILE *fo = fopen(out, "wb");
    if (!fo || fwrite(cipher, 1, clen, fo) != clen) { perror("write"); return 1; }
    fclose(fo);
    fprintf(stderr, "agseal: sealed %ld bytes -> %s\n", (long)plen, out);
    return 0;
}

static int cmd_open(const char *file, const char *out) {
    size_t clen;
    unsigned char *cipher = read_all(file, &clen);
    if (!cipher || clen < crypto_box_SEALBYTES) { fprintf(stderr, "agseal: bad input\n"); return 1; }

    size_t plen = clen - crypto_box_SEALBYTES;
    unsigned char *plain = malloc(plen ? plen : 1);
    if (!plain) return 1;

    if (crypto_box_seal_open(plain, cipher, (unsigned long long)clen, spk, skey) != 0) {
        fprintf(stderr, "agseal: open failed (not for this keypair?)\n");
        return 1;
    }
    FILE *fo = fopen(out, "wb");
    if (!fo || fwrite(plain, 1, plen, fo) != plen) { perror("write"); return 1; }
    fclose(fo);
    fprintf(stderr, "agseal: opened %s -> %ld bytes\n", file, (long)plen);
    return 0;
}

int main(int argc, char **argv) {
    if (sodium_init() < 0) return 1;

    if (argc == 2 && strcmp(argv[1], "pubkey") == 0) {
        if (load_or_make_keypair() != 0) { perror("keypair"); return 1; }
        export_addr();
        char b64[64];
        sodium_bin2base64(b64, sizeof b64, spk, sizeof spk, sodium_base64_VARIANT_ORIGINAL);
        printf("%s\n", b64);
        return 0;
    }
    if (argc == 5 && strcmp(argv[1], "seal") == 0)
        return cmd_seal(argv[2], argv[3], argv[4]);
    if (argc == 4 && strcmp(argv[1], "open") == 0) {
        if (load_or_make_keypair() != 0) { perror("keypair"); return 1; }
        return cmd_open(argv[2], argv[3]);
    }

    fprintf(stderr,
        "Usage: agseal seal <file> <recipient_pubkey_b64> <out>\n"
        "       agseal open <sealed> <out>\n"
        "       agseal pubkey\n");
    return 2;
}
