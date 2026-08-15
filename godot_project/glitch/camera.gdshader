// camera.gdshader — "screen filmed off a screen"
//
// Belongs on a second fullscreen ColorRect in its OWN
// CanvasLayer ABOVE the glitch layer (e.g. glitch on layer = 1, this one
// on layer = 2).
//
// The order in the shader follows the real signal path of a phone camera:
//
//   1. GEOMETRY    — hand shake (offset) and slight breathing (zoom)
//   2. OPTICS      — softening, color channels blurrier than brightness
//   3. SENSOR      — moiré (sensor grid against screen grid),
//                    rolling shutter bands (refresh rate against exposure)
//   4. PROCESSING  — saturation, contrast, lifted blacks
//   5. LENS        — vignette
//   6. GRAIN       — temporally changing noise, stronger in dark areas
//
// HDR-safe: no operation clamps at 1.0, so values above 1.0 are
// preserved and the glow (which runs at the very end) keeps working.

shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

// --- 1. Handheld camera ---------------------------------------------------
uniform float handheld : hint_range(0.0, 30.0) = 4.0;      // offset in pixels
uniform float breathe : hint_range(0.0, 0.05) = 0.006;     // zoom breathing

// --- 2. Optics ------------------------------------------------------------
uniform float softness : hint_range(0.0, 8.0) = 1.6;       // blur in pixels
uniform float chroma_smear : hint_range(0.0, 1.0) = 0.6;   // color blurrier than brightness

// --- 3. Sensor ------------------------------------------------------------
uniform float moire : hint_range(0.0, 0.5) = 0.10;
uniform float moire_period : hint_range(1.5, 12.0) = 3.0;  // pixels per stripe
uniform float moire_angle : hint_range(0.0, 1.57) = 0.18;  // tilt in rad

uniform float rolling : hint_range(0.0, 0.6) = 0.14;       // band depth
uniform float rolling_bands : hint_range(0.5, 12.0) = 2.2; // bands in the image
uniform float rolling_speed : hint_range(-4.0, 4.0) = 0.7; // travel per second

// --- 4. Processing --------------------------------------------------------
uniform float saturation : hint_range(0.0, 3.0) = 1.45;
uniform float contrast : hint_range(0.5, 3.0) = 1.30;
uniform float black_lift : hint_range(0.0, 0.15) = 0.03;   // black turns gray
uniform float exposure : hint_range(0.2, 3.0) = 1.05;

// --- 5. Lens --------------------------------------------------------------
uniform float vignette : hint_range(0.0, 1.5) = 0.45;

// --- 6. Grain -------------------------------------------------------------
uniform float grain : hint_range(0.0, 0.3) = 0.05;
uniform float grain_in_shadows : hint_range(0.0, 1.0) = 0.7;


float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

vec3 sample_rgb(vec2 uv) {
	float inside = step(0.0, uv.x) * step(uv.x, 1.0)
			* step(0.0, uv.y) * step(uv.y, 1.0);
	return texture(screen_tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb * inside;
}


void fragment() {
	vec2 tex_size = vec2(textureSize(screen_tex, 0));
	vec2 texel = 1.0 / tex_size;

	// --- 1. Handheld camera -----------------------------------------------
	// Sum of slow sines with non-round frequencies: looks organic,
	// practically never repeats and costs almost nothing.
	vec2 shake = vec2(
			sin(TIME * 0.71) * 0.6 + sin(TIME * 1.73 + 1.3) * 0.28
					+ sin(TIME * 3.11 + 2.7) * 0.12,
			sin(TIME * 0.89 + 2.1) * 0.6 + sin(TIME * 2.29 + 0.7) * 0.28
					+ sin(TIME * 3.67 + 1.1) * 0.12);

	float zoom = 1.0 + breathe * sin(TIME * 0.43);
	vec2 uv = (SCREEN_UV - 0.5) / zoom + 0.5 + shake * handheld * texel;

	// --- 2. Optics --------------------------------------------------------
	// Five samples: center plus diagonal cross. Enough for softness,
	// without destroying the glow that runs on top of it anyway.
	vec3 sharp = sample_rgb(uv);
	vec3 soft = sharp;
	if (softness > 0.01) {
		vec2 o = softness * texel;
		soft = sharp * 0.36
				+ sample_rgb(uv + vec2( o.x,  o.y)) * 0.16
				+ sample_rgb(uv + vec2(-o.x,  o.y)) * 0.16
				+ sample_rgb(uv + vec2( o.x, -o.y)) * 0.16
				+ sample_rgb(uv + vec2(-o.x, -o.y)) * 0.16;
	}

	// Chroma smear: brightness from the sharp, color from the soft image.
	// Exactly this separation is what the video compression in the phone does —
	// color resolution is halved there, brightness resolution is not.
	const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
	float l_sharp = dot(sharp, LUMA);
	float l_soft = dot(soft, LUMA);
	vec3 chroma = soft - vec3(l_soft);
	vec3 col = mix(soft, vec3(l_sharp) + chroma, chroma_smear);

	// --- 3. Sensor --------------------------------------------------------
	// Moiré: two fine grids, one slightly tilted. The beat pattern
	// from both is the actual effect — hence two frequencies.
	if (moire > 0.001) {
		float ca = cos(moire_angle);
		float sa = sin(moire_angle);
		vec2 p = FRAGCOORD.xy / max(moire_period, 0.5);
		float g1 = sin(p.x * TAU);
		float g2 = sin((p.x * ca + p.y * sa) * TAU * 1.03);
		col *= 1.0 + (g1 * g2) * moire;
	}

	// Rolling shutter: wide, soft bands that slowly travel upward.
	if (rolling > 0.001) {
		float band = sin((SCREEN_UV.y * rolling_bands - TIME * rolling_speed) * TAU);
		col *= 1.0 - rolling * (0.5 + 0.5 * band);
	}

	// --- 4. Processing ----------------------------------------------------
	col *= exposure;

	float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(l), col, saturation);

	// Contrast around 0.5 — stays monotonic, doesn't clamp, HDR survives
	col = (col - 0.5) * contrast + 0.5;

	// Only here catch negative values: the contrast pushes black below
	// zero, and the following lift would otherwise be eaten up by it.
	col = max(col, vec3(0.0));

	// Lifted black: a screen filmed off a screen never has true black
	col = col * (1.0 - black_lift) + black_lift;

	// --- 5. Vignette ------------------------------------------------------
	if (vignette > 0.001) {
		vec2 d = SCREEN_UV - 0.5;
		float r = dot(d, d) * 2.0;
		col *= 1.0 - vignette * r * r;
	}

	// --- 6. Grain ---------------------------------------------------------
	if (grain > 0.001) {
		float n = hash13(vec3(FRAGCOORD.xy, floor(TIME * 24.0))) - 0.5;
		float lum = clamp(dot(col, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
		float w = mix(1.0, 1.0 - lum, grain_in_shadows);
		col += n * grain * w;
	}

	col = max(col, vec3(0.0));
	COLOR = vec4(col, 1.0);
}
