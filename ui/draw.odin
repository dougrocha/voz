#+build !windows
package ui

import "core:math"

// Software 2D: a 32-bit BGRA canvas (Win32 DIB layout, 0xAARRGGBB), antialiased shapes by
// signed distance coverage. Portable; no allocation. Everything is clipped to canvas.clip.

Color :: distinct u32 // 0xAARRGGBB

rgb :: #force_inline proc "contextless" (r, g, b: u8) -> Color {
	return Color(0xFF000000 | u32(r) << 16 | u32(g) << 8 | u32(b))
}

with_alpha :: #force_inline proc "contextless" (c: Color, a: f32) -> Color {
	return Color(u32(c) & 0x00FFFFFF | u32(clamp(a, 0, 1) * 255 + 0.5) << 24)
}

// Linear mix in sRGB space (fine for UI tints).
mix :: proc "contextless" (a, b: Color, t: f32) -> Color {
	ch :: proc "contextless" (a, b: Color, shift: u32, t: f32) -> u32 {
		x := f32((u32(a) >> shift) & 0xFF)
		y := f32((u32(b) >> shift) & 0xFF)
		return u32(x + (y - x) * t + 0.5) << shift
	}
	return Color(ch(a, b, 24, t) | ch(a, b, 16, t) | ch(a, b, 8, t) | ch(a, b, 0, t))
}

Rect :: struct { x, y, w, h: f32 }

Clip :: struct { x0, y0, x1, y1: i32 } // half-open, physical pixels

Canvas :: struct {
	px:   [^]u32, // top-down rows
	w, h: i32,
	clip: Clip,
}

canvas_full_clip :: proc "contextless" (c: ^Canvas) { c.clip = {0, 0, c.w, c.h} }

rect_contains :: #force_inline proc "contextless" (r: Rect, x, y: f32) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

rect_inset :: #force_inline proc "contextless" (r: Rect, d: f32) -> Rect {
	return {r.x + d, r.y + d, r.w - 2 * d, r.h - 2 * d}
}

// Bounding box of r (+pad) intersected with the clip, in pixels.
@(private)
span :: #force_inline proc "contextless" (c: ^Canvas, r: Rect, pad: f32) -> (x0, y0, x1, y1: i32) {
	x0 = max(i32(math.floor(r.x - pad)), c.clip.x0)
	y0 = max(i32(math.floor(r.y - pad)), c.clip.y0)
	x1 = min(i32(math.ceil(r.x + r.w + pad)), c.clip.x1)
	y1 = min(i32(math.ceil(r.y + r.h + pad)), c.clip.y1)
	return
}

// dst = col over dst, with coverage in [0, 1]. dst is always opaque.
@(private)
blend :: #force_inline proc "contextless" (dst: ^u32, col: Color, cov: f32) {
	a := u32(f32(u32(col) >> 24) * cov + 0.5)
	if a == 0 do return
	if a >= 255 { dst^ = u32(col) | 0xFF000000; return }
	ia := 255 - a
	d, s := dst^, u32(col)
	rb := (s & 0x00FF00FF) * a + (d & 0x00FF00FF) * ia
	g  := (s & 0x0000FF00) * a + (d & 0x0000FF00) * ia
	rb = (rb + 0x00800080 + ((rb >> 8) & 0x00FF00FF)) >> 8 // exact /255
	g  = (g + 0x00008000 + ((g >> 8) & 0x0000FF00)) >> 8
	dst^ = 0xFF000000 | (rb & 0x00FF00FF) | (g & 0x0000FF00)
}

// Signed distance to a rounded box centered at the origin (half size hx, hy).
// Only corner pixels pay for the sqrt.
@(private)
sd_rbox :: #force_inline proc "contextless" (px, py, hx, hy, r: f32) -> f32 {
	qx := abs(px) - hx + r
	qy := abs(py) - hy + r
	if qx <= 0 || qy <= 0 do return max(qx, qy) - r
	return math.sqrt(qx * qx + qy * qy) - r
}

fill_rect :: proc "contextless" (c: ^Canvas, r: Rect, col: Color) {
	fill_rrect(c, r, 0, col)
}

fill_rrect :: proc "contextless" (c: ^Canvas, r: Rect, radius: f32, col: Color) {
	if r.w <= 0 || r.h <= 0 do return
	x0, y0, x1, y1 := span(c, r, 1)
	hx, hy := r.w * 0.5, r.h * 0.5
	cx, cy := r.x + hx, r.y + hy
	rad := clamp(radius, 0, min(hx, hy))
	opaque := u32(col) >> 24 == 255
	for y in y0 ..< y1 {
		py := f32(y) + 0.5 - cy
		row := c.px[y * c.w:]
		// Solid span: pixel centers at least 0.5 px inside every edge. Corner rows narrow it.
		sx0, sx1 := x1, x1
		if abs(py) <= hy - 0.5 {
			inset := abs(py) > hy - rad ? rad : 0
			sx0 = clamp(i32(math.ceil(r.x + inset)), x0, x1)
			sx1 = clamp(i32(math.floor(r.x + r.w - inset)), sx0, x1)
		}
		for x in x0 ..< sx0 {
			d := sd_rbox(f32(x) + 0.5 - cx, py, hx, hy, rad)
			if d < 0.5 do blend(&row[x], col, clamp(0.5 - d, 0, 1))
		}
		if opaque {
			for x in sx0 ..< sx1 do row[x] = u32(col)
		} else {
			for x in sx0 ..< sx1 do blend(&row[x], col, 1)
		}
		for x in sx1 ..< x1 {
			d := sd_rbox(f32(x) + 0.5 - cx, py, hx, hy, rad)
			if d < 0.5 do blend(&row[x], col, clamp(0.5 - d, 0, 1))
		}
	}
}

// Border of `width` drawn inside the shape's edge.
stroke_rrect :: proc "contextless" (c: ^Canvas, r: Rect, radius, width: f32, col: Color) {
	if r.w <= 0 || r.h <= 0 do return
	x0, y0, x1, y1 := span(c, r, 1)
	hx, hy := r.w * 0.5, r.h * 0.5
	cx, cy := r.x + hx, r.y + hy
	rad := clamp(radius, 0, min(hx, hy))
	edge := i32(math.ceil(width)) + 2
	for y in y0 ..< y1 {
		py := f32(y) + 0.5 - cy
		row := c.px[y * c.w:]
		// Rows clear of the top/bottom border and corners only touch the left/right edges.
		skip0, skip1 := x1, x1
		if abs(py) < hy - rad - width - 1 {
			skip0 = clamp(i32(math.floor(r.x)) + edge, x0, x1)
			skip1 = clamp(i32(math.ceil(r.x + r.w)) - edge, skip0, x1)
		}
		for x in x0 ..< skip0 {
			d := sd_rbox(f32(x) + 0.5 - cx, py, hx, hy, rad)
			cov := clamp(0.5 - d, 0, 1) - clamp(0.5 - d - width, 0, 1)
			if cov > 0 do blend(&row[x], col, cov)
		}
		for x in skip1 ..< x1 {
			d := sd_rbox(f32(x) + 0.5 - cx, py, hx, hy, rad)
			cov := clamp(0.5 - d, 0, 1) - clamp(0.5 - d - width, 0, 1)
			if cov > 0 do blend(&row[x], col, cov)
		}
	}
}

// Soft shadow: coverage falls off over `blur` pixels outside the shape.
fill_shadow :: proc "contextless" (c: ^Canvas, r: Rect, radius, blur: f32, col: Color) {
	x0, y0, x1, y1 := span(c, r, blur + 1)
	hx, hy := r.w * 0.5, r.h * 0.5
	cx, cy := r.x + hx, r.y + hy
	rad := clamp(radius, 0, min(hx, hy))
	inv := 1 / max(blur, 0.5)
	for y in y0 ..< y1 {
		py := f32(y) + 0.5 - cy
		row := c.px[y * c.w:]
		for x in x0 ..< x1 {
			d := sd_rbox(f32(x) + 0.5 - cx, py, hx, hy, rad)
			t := clamp(1 - d * inv, 0, 1)
			if t > 0 do blend(&row[x], col, t * t)
		}
	}
}

fill_circle :: proc "contextless" (c: ^Canvas, cx, cy, radius: f32, col: Color) {
	fill_rrect(c, {cx - radius, cy - radius, 2 * radius, 2 * radius}, radius, col)
}

// Antialiased capsule from (ax, ay) to (bx, by).
stroke_line :: proc "contextless" (c: ^Canvas, ax, ay, bx, by, width: f32, col: Color) {
	hw := width * 0.5
	r := Rect{min(ax, bx), min(ay, by), abs(bx - ax), abs(by - ay)}
	x0, y0, x1, y1 := span(c, r, hw + 1)
	dx, dy := bx - ax, by - ay
	inv_len2 := 1 / max(dx * dx + dy * dy, 1e-6)
	for y in y0 ..< y1 {
		py := f32(y) + 0.5 - ay
		row := c.px[y * c.w:]
		for x in x0 ..< x1 {
			px := f32(x) + 0.5 - ax
			t := clamp((px * dx + py * dy) * inv_len2, 0, 1)
			ex, ey := px - dx * t, py - dy * t
			d := math.sqrt(ex * ex + ey * ey) - hw
			if d < 0.5 do blend(&row[x], col, clamp(0.5 - d, 0, 1))
		}
	}
}

// Down-pointing chevron centered at (cx, cy), `size` = half width.
chevron_down :: proc "contextless" (c: ^Canvas, cx, cy, size, width: f32, col: Color) {
	stroke_line(c, cx - size, cy - size * 0.5, cx, cy + size * 0.5, width, col)
	stroke_line(c, cx, cy + size * 0.5, cx + size, cy - size * 0.5, width, col)
}

chevron_right :: proc "contextless" (c: ^Canvas, cx, cy, size, width: f32, col: Color) {
	stroke_line(c, cx - size * 0.5, cy - size, cx + size * 0.5, cy, width, col)
	stroke_line(c, cx + size * 0.5, cy, cx - size * 0.5, cy + size, width, col)
}

chevron_left :: proc "contextless" (c: ^Canvas, cx, cy, size, width: f32, col: Color) {
	stroke_line(c, cx + size * 0.5, cy - size, cx - size * 0.5, cy, width, col)
	stroke_line(c, cx - size * 0.5, cy, cx + size * 0.5, cy + size, width, col)
}

// Diagonal hatch inside r (meter's gated zone).
hatch :: proc "contextless" (c: ^Canvas, r: Rect, spacing, width: f32, col: Color) {
	x0, y0, x1, y1 := span(c, r, 0)
	for y in y0 ..< y1 {
		row := c.px[y * c.w:]
		for x in x0 ..< x1 {
			t := math.mod(f32(x) + f32(y), spacing)
			d := min(t, spacing - t) - width * 0.5
			if d < 0.5 do blend(&row[x], col, clamp(0.5 - d, 0, 1))
		}
	}
}
