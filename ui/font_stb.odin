#+build !windows
package ui

import stbtt "vendor:stb/truetype"

// stb_truetype backend. Used off Windows only, by tools/snapshot to render the UI to PNG.

Font_Impl :: struct {
	info:  stbtt.fontinfo,
	scale: f32,
}

font_init_stb :: proc(f: ^Font, id: u8, data: []u8, px: f32) -> bool {
	f.id, f.px = id, px
	if !stbtt.InitFont(&f.impl.info, raw_data(data), stbtt.GetFontOffsetForIndex(raw_data(data), 0)) do return false
	f.impl.scale = stbtt.ScaleForMappingEmToPixels(&f.impl.info, px)
	asc, desc, gap: i32
	stbtt.GetFontVMetrics(&f.impl.info, &asc, &desc, &gap)
	f.ascent  = f32(asc) * f.impl.scale
	f.descent = -f32(desc) * f.impl.scale
	return true
}

@(private)
font_raster :: proc(f: ^Font, cp: rune, out: []u8, stride: i32) -> (r: Raster, ok: bool) {
	g := stbtt.FindGlyphIndex(&f.impl.info, cp)
	if g == 0 && cp != ' ' do return {}, false
	adv, lsb: i32
	stbtt.GetGlyphHMetrics(&f.impl.info, g, &adv, &lsb)
	r.adv = f32(adv) * f.impl.scale
	x0, y0, x1, y1: i32
	stbtt.GetGlyphBitmapBox(&f.impl.info, g, f.impl.scale, f.impl.scale, &x0, &y0, &x1, &y1)
	w, h := x1 - x0, y1 - y0
	if w <= 0 || h <= 0 || w > stride || h > stride do return r, true
	stbtt.MakeGlyphBitmap(&f.impl.info, raw_data(out), w, h, stride, f.impl.scale, f.impl.scale, g)
	r.w, r.h, r.ox, r.oy = w, h, x0, y0
	return r, true
}
