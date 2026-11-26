#+build !windows
package ui

import "core:math"

// Glyph cache: one fixed 8-bit atlas + open-addressed table. Glyphs are rasterized on first
// use by the platform backend (GDI on Windows, stb_truetype elsewhere) and shelf-packed.
// When the atlas or table fills up, the whole cache resets (rare: a DPI change does it too).

ATLAS       :: 512
GLYPH_SLOTS :: 2048 // power of two
SCRATCH     :: 128  // max glyph bitmap side

Font :: struct {
	id:      u8,  // 1..255, part of the cache key
	px:      f32, // em size in pixels
	ascent:  f32, // baseline offset from the top of the line box
	descent: f32,
	impl:    Font_Impl,
}

Glyph :: struct {
	key:    u32, // 0 = empty slot
	x, y:   u16, // atlas position
	w, h:   u16,
	ox, oy: i16, // bitmap offset from pen position on the baseline
	adv:    f32,
}

Glyph_Cache :: struct {
	atlas:   [ATLAS * ATLAS]u8,
	slots:   [GLYPH_SLOTS]Glyph,
	count:   int,
	shelf_x: i32,
	shelf_y: i32,
	shelf_h: i32,
}

// What a backend produces into a caller-provided scratch bitmap.
Raster :: struct {
	w, h:   i32,
	ox, oy: i32,
	adv:    f32,
}

glyph_cache_reset :: proc "contextless" (gc: ^Glyph_Cache) {
	gc.slots = {}
	gc.count = 0
	gc.shelf_x, gc.shelf_y, gc.shelf_h = 0, 0, 0
}

@(private)
glyph_get :: proc(gc: ^Glyph_Cache, f: ^Font, cp: rune) -> Glyph {
	key := u32(f.id) << 24 | (u32(cp) & 0x00FFFFFF)
	mask := u32(GLYPH_SLOTS - 1)
	i := (key * 2654435761) >> 21 & mask
	for {
		s := &gc.slots[i]
		if s.key == key do return s^
		if s.key == 0 do break
		i = (i + 1) & mask
	}

	// Miss: rasterize into scratch, then pack.
	scratch: [SCRATCH * SCRATCH]u8
	r, ok := font_raster(f, cp, scratch[:], SCRATCH)
	if !ok {
		if cp != '?' do return glyph_get(gc, f, '?')
		return {}
	}
	if gc.count >= GLYPH_SLOTS * 3 / 4 do glyph_cache_reset(gc)
	if gc.shelf_x + r.w > ATLAS { gc.shelf_x = 0; gc.shelf_y += gc.shelf_h + 1; gc.shelf_h = 0 }
	if gc.shelf_y + r.h > ATLAS {
		glyph_cache_reset(gc)
		return glyph_get(gc, f, cp) // table is empty now; this can't recurse again
	}
	g := Glyph{
		key = key,
		x = u16(gc.shelf_x), y = u16(gc.shelf_y),
		w = u16(r.w), h = u16(r.h),
		ox = i16(r.ox), oy = i16(r.oy),
		adv = r.adv,
	}
	for row in 0 ..< r.h {
		copy(gc.atlas[(gc.shelf_y + row) * ATLAS + gc.shelf_x:][:r.w], scratch[row * SCRATCH:][:r.w])
	}
	gc.shelf_x += r.w + 1
	gc.shelf_h = max(gc.shelf_h, r.h)

	i = (key * 2654435761) >> 21 & mask
	for gc.slots[i].key != 0 do i = (i + 1) & mask
	gc.slots[i] = g
	gc.count += 1
	return g
}

// Draws s with its baseline at y. Returns the pen x after the last glyph.
draw_text :: proc(c: ^Canvas, gc: ^Glyph_Cache, f: ^Font, x, y: f32, s: string, col: Color) -> f32 {
	pen := x
	by := i32(math.round(y))
	for cp in s {
		g := glyph_get(gc, f, cp)
		if g.w > 0 {
			gx := i32(math.round(pen)) + i32(g.ox)
			gy := by + i32(g.oy)
			x0, y0 := max(gx, c.clip.x0), max(gy, c.clip.y0)
			x1, y1 := min(gx + i32(g.w), c.clip.x1), min(gy + i32(g.h), c.clip.y1)
			for py in y0 ..< y1 {
				src := gc.atlas[(i32(g.y) + py - gy) * ATLAS + i32(g.x):]
				row := c.px[py * c.w:]
				for px in x0 ..< x1 {
					a := src[px - gx]
					if a != 0 do blend(&row[px], col, f32(a) * (1.0 / 255))
				}
			}
		}
		pen += g.adv
	}
	return pen
}

text_width :: proc(gc: ^Glyph_Cache, f: ^Font, s: string) -> f32 {
	w: f32
	for cp in s do w += glyph_get(gc, f, cp).adv
	return w
}

// Longest prefix of s that fits in max_w with a trailing "…"; the whole string if it fits.
text_fit :: proc(gc: ^Glyph_Cache, f: ^Font, s: string, max_w: f32) -> (prefix: string, ellipsis: bool) {
	if text_width(gc, f, s) <= max_w do return s, false
	budget := max_w - glyph_get(gc, f, '…').adv
	w: f32
	for cp, i in s {
		w += glyph_get(gc, f, cp).adv
		if w > budget do return s[:i], true
	}
	return s, false
}

// Draws text vertically centered on cy, aligned left/center/right of x.
Align :: enum u8 { Left, Center, Right }

draw_label :: proc(c: ^Canvas, gc: ^Glyph_Cache, f: ^Font, x, cy: f32, s: string, col: Color, align := Align.Left, max_w: f32 = 0) {
	text := s
	ell := false
	if max_w > 0 do text, ell = text_fit(gc, f, s, max_w)
	w := text_width(gc, f, text)
	if ell do w += glyph_get(gc, f, '…').adv
	x0 := x
	switch align {
	case .Left:
	case .Center: x0 = x - w * 0.5
	case .Right:  x0 = x - w
	}
	base := cy + (f.ascent - f.descent) * 0.5 // optical center of the line box
	pen := draw_text(c, gc, f, x0, base, text, col)
	if ell do draw_text(c, gc, f, pen, base, "…", col)
}
