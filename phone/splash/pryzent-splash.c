/*
 * pryzent-splash — draw boot status text straight onto the phone's
 * framebuffer (/dev/fb0). Phones have no serial console, so without this a
 * failed boot is just a black screen.
 *
 *   pryzent-splash [-e] [-d /dev/fb0] "headline" ["detail line" ...]
 *
 *   -e   error style (red accent)
 *   -d   framebuffer device (default /dev/fb0)
 *
 * Supports 16/24/32 bpp framebuffers. Static, no deps beyond libc.
 *
 * Copyright (C) Indrajit Guha — AGPL-3.0
 */
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "font.h"

static struct fb_var_screeninfo vi;
static struct fb_fix_screeninfo fi;
static uint8_t *fb;

static void put_px(int x, int y, uint32_t rgb)
{
    if (x < 0 || y < 0 || x >= (int)vi.xres || y >= (int)vi.yres)
        return;
    uint8_t r = rgb >> 16, g = rgb >> 8, b = rgb;
    uint32_t v = ((uint32_t)(r >> (8 - vi.red.length)) << vi.red.offset) |
                 ((uint32_t)(g >> (8 - vi.green.length)) << vi.green.offset) |
                 ((uint32_t)(b >> (8 - vi.blue.length)) << vi.blue.offset);
    if (vi.transp.length)
        v |= ((1u << vi.transp.length) - 1) << vi.transp.offset;
    uint8_t *p = fb + (size_t)(y + vi.yoffset) * fi.line_length +
                 (size_t)(x + vi.xoffset) * (vi.bits_per_pixel / 8);
    switch (vi.bits_per_pixel) {
    case 32: *(uint32_t *)p = v; break;
    case 24: p[0] = v; p[1] = v >> 8; p[2] = v >> 16; break;
    case 16: *(uint16_t *)p = v; break;
    }
}

static void fill(int x0, int y0, int w, int h, uint32_t rgb)
{
    for (int y = y0; y < y0 + h; y++)
        for (int x = x0; x < x0 + w; x++)
            put_px(x, y, rgb);
}

static int draw_text(int x, int y, const char *s, int scale, uint32_t rgb, int max_w)
{
    int cx = x, cw = FONT_W * scale;
    for (; *s; s++) {
        unsigned char c = *s;
        if (c == ' ' && cx != x) {
            /* Word wrap: break here if the next word will not fit. */
            int wl = 0;
            while (s[1 + wl] && s[1 + wl] != ' ' && s[1 + wl] != '\n')
                wl++;
            if (cx + (1 + wl) * cw > x + max_w && (wl + 1) * cw <= max_w) {
                cx = x;
                y += FONT_H * scale;
                continue;
            }
        }
        if (c == '\n' || cx + cw > x + max_w) {
            cx = x;
            y += FONT_H * scale;
            if (c == '\n')
                continue;
        }
        if (c < FONT_FIRST || c > FONT_LAST)
            c = '?';
        const unsigned char *g = font_bits[c - FONT_FIRST];
        for (int gy = 0; gy < FONT_H; gy++)
            for (int gx = 0; gx < FONT_W; gx++)
                if (g[gy] & (0x80 >> gx))
                    fill(cx + gx * scale, y + gy * scale, scale, scale, rgb);
        cx += FONT_W * scale;
    }
    return y + FONT_H * scale;
}

int main(int argc, char **argv)
{
    const char *dev = "/dev/fb0";
    int err = 0, i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) {
        if (!strcmp(argv[i], "-e"))
            err = 1;
        else if (!strcmp(argv[i], "-d") && i + 1 < argc)
            dev = argv[++i];
    }

    int fd = open(dev, O_RDWR);
    if (fd < 0)
        return 1;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &vi) || ioctl(fd, FBIOGET_FSCREENINFO, &fi))
        return 1;
    if (vi.bits_per_pixel != 16 && vi.bits_per_pixel != 24 && vi.bits_per_pixel != 32)
        return 1;
    fb = mmap(NULL, fi.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (fb == MAP_FAILED)
        return 1;
    ioctl(fd, FBIOBLANK, FB_BLANK_UNBLANK);

    int W = vi.xres, H = vi.yres;
    /* Scale text to the panel: ~22 columns of headline on a phone screen. */
    int big = W / (FONT_W * 11); if (big < 2) big = 2;
    int small = W / (FONT_W * 36); if (small < 1) small = 1;
    int margin = W / 14;
    uint32_t accent = err ? 0xff5a5a : 0x7c5cff;

    /* Background: dark vertical gradient. */
    for (int y = 0; y < H; y++)
        fill(0, y, W, 1, ((10 + y * 14 / H) << 16) | ((10 + y * 8 / H) << 8) | (24 + y * 30 / H));

    int y = H / 4;
    y = draw_text(margin, y, "PryzentOS", big, 0xffffff, W - 2 * margin);
    fill(margin, y + big * 4, W / 4, big * 2, accent);
    y += big * 12;

    if (i < argc)
        y = draw_text(margin, y, argv[i++], small * 2, err ? 0xffb4b4 : 0xe8e4ff, W - 2 * margin);
    y += small * 8;
    for (; i < argc; i++)
        y = draw_text(margin, y, argv[i], small, 0xa8a4c0, W - 2 * margin) + small * 4;

    draw_text(margin, H - margin - FONT_H * small, "The home screen is an agent.", small, 0x6a6690, W);

    /* Some panels (e.g. MediaTek command-mode) only refresh on a pan. */
    ioctl(fd, FBIOPAN_DISPLAY, &vi);
    munmap(fb, fi.smem_len);
    close(fd);
    return 0;
}
