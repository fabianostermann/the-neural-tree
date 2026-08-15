// glitch.gdshader — RGB split, block offset and frame displacement
//
// Belongs on a fullscreen ColorRect in a CanvasLayer ABOVE
// the scene.
//
// Three effects, all scaled together via glitch_amount (0..1):
//
//   1. RGB SPLIT       — the three channels are offset against each other.
//                        There is also a permanent, radial
//                        base aberration that increases toward the edge.
//   2. BLOCK OFFSET    — horizontal bands slip sideways.
//   3. FRAME DISPLACEMENT — the whole image jumps briefly.
//
// glitch_amount can be set from outside (see glitch_driver.gd) or
// the shader rolls its own bursts (auto_glitch). Both add
// up, so you can work with auto until the data trigger is in place.
//
// Sampling outside the image yields black instead of clamped edges:
// that way a displaced block really looks displaced and doesn't
// smear the edge pixels out.

shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

// --- Control --------------------------------------------------------------
// Settable from outside, 0 = calm. Adds on top of the auto bursts.
uniform float glitch_amount : hint_range(0.0, 1.0) = 0.0;
// Self-rolled bursts, until the data trigger is in place
uniform bool auto_glitch = true;
uniform float burst_rate : hint_range(0.5, 20.0) = 3.0;    // rolls per second
uniform float burst_chance : hint_range(0.0, 1.0) = 0.12;  // hit rate
uniform float burst_decay : hint_range(1.0, 30.0) = 9.0;   // decay

// --- 1. RGB split ---------------------------------------------------------
uniform float rgb_split : hint_range(0.0, 60.0) = 14.0;    // pixels at full glitch
uniform float rgb_split_base : hint_range(0.0, 12.0) = 2.0; // permanent, radial

// --- 2. Block offset ------------------------------------------------------
uniform float block_shift : hint_range(0.0, 200.0) = 60.0; // max. offset in pixels
uniform float block_count : hint_range(2.0, 80.0) = 18.0;  // number of bands
uniform float block_share : hint_range(0.0, 1.0) = 0.35;   // share of affected bands

// --- 3. Frame displacement ------------------------------------------------
uniform float frame_shift : hint_range(0.0, 60.0) = 10.0;  // pixels at full glitch


float hash11(float p) {
	return fract(sin(p * 127.1) * 43758.5453);
}

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Outside the image: black. The background is black anyway,
// which makes offsets look like real displacements.
vec3 sample_rgb(sampler2D tex, vec2 uv) {
	float inside = step(0.0, uv.x) * step(uv.x, 1.0)
			* step(0.0, uv.y) * step(uv.y, 1.0);
	return texture(tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb * inside;
}


void fragment() {
	vec2 texel = 1.0 / vec2(textureSize(screen_tex, 0));

	// --- Roll a burst -----------------------------------------------------
	// One roll per time slot. If it lands, a burst starts that decays
	// exponentially across the slot: hard onset, soft ending.
	float slot = floor(TIME * burst_rate);
	float phase = fract(TIME * burst_rate);
	float roll = hash11(slot);
	float hit = step(1.0 - burst_chance, roll);
	float auto_g = auto_glitch
			? hit * exp(-phase * burst_decay) * (0.4 + 0.6 * hash11(slot + 7.0))
			: 0.0;

	float g = clamp(glitch_amount + auto_g, 0.0, 1.0);
	// Seed changes per time slot: every burst looks different
	float seed = slot;

	vec2 uv = SCREEN_UV;

	// --- 3. Frame displacement --------------------------------------------
	vec2 jump = vec2(hash11(seed + 1.0) - 0.5, (hash11(seed + 2.0) - 0.5) * 0.35);
	uv += jump * 2.0 * frame_shift * g * texel;

	// --- 2. Block offset --------------------------------------------------
	// Bands in screen height, not in UV: stays the same at a different resolution.
	float band = floor(uv.y * block_count + hash11(seed + 3.0) * 13.0);
	float pick = hash21(vec2(band, seed));
	float band_on = step(1.0 - block_share, pick);
	float off = (hash21(vec2(band, seed + 5.0)) - 0.5) * 2.0;
	uv.x += off * band_on * block_shift * g * texel.x;

	// --- 1. RGB split -----------------------------------------------------
	// Radial base aberration (always on) plus directionless glitch split.
	vec2 from_center = SCREEN_UV - vec2(0.5);
	vec2 base_dir = from_center * 2.0;
	vec2 split = base_dir * rgb_split_base
			+ vec2(hash11(seed + 11.0) - 0.5, (hash11(seed + 13.0) - 0.5) * 0.3)
					* 2.0 * rgb_split * g;

	vec3 col;
	col.r = sample_rgb(screen_tex, uv + split * texel).r;
	col.g = sample_rgb(screen_tex, uv).g;
	col.b = sample_rgb(screen_tex, uv - split * texel).b;

	COLOR = vec4(col, 1.0);
}
