// glitch.gdshader — RGB-Split, Blockversatz und Bildverschiebung
//
// Gehört auf ein bildschirmfüllendes ColorRect in einem CanvasLayer ÜBER
// der Szene (wie der Blur zuvor).
//
// Drei Effekte, alle über glitch_amount (0..1) gemeinsam skaliert:
//
//   1. RGB-SPLIT      — die drei Kanäle werden gegeneinander versetzt.
//                       Zusätzlich gibt es eine dauerhafte, radiale
//                       Grundaberration, die zum Rand hin zunimmt.
//   2. BLOCKVERSATZ   — waagerechte Bänder rutschen seitlich weg.
//   3. BILDVERSCHIEBUNG — das ganze Bild springt kurz.
//
// glitch_amount kann von außen gesetzt werden (siehe glitch_driver.gd) oder
// der Shader würfelt sich selbst Ausbrüche (auto_glitch). Beide addieren
// sich, du kannst also mit auto arbeiten, bis der Datentrigger steht.
//
// Sampling außerhalb des Bildes liefert Schwarz statt geklemmter Ränder:
// so sieht ein verschobener Block wirklich verschoben aus und schmiert
// nicht die Randpixel in die Länge.

shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

// --- Ansteuerung ----------------------------------------------------------
// Von außen setzbar, 0 = ruhig. Addiert sich auf die Auto-Ausbrüche.
uniform float glitch_amount : hint_range(0.0, 1.0) = 0.0;
// Selbst würfelnde Ausbrüche, bis der Datentrigger steht
uniform bool auto_glitch = true;
uniform float burst_rate : hint_range(0.5, 20.0) = 3.0;    // Würfe pro Sekunde
uniform float burst_chance : hint_range(0.0, 1.0) = 0.12;  // Trefferquote
uniform float burst_decay : hint_range(1.0, 30.0) = 9.0;   // Abklingen

// --- 1. RGB-Split ---------------------------------------------------------
uniform float rgb_split : hint_range(0.0, 60.0) = 14.0;    // Pixel bei vollem Glitch
uniform float rgb_split_base : hint_range(0.0, 12.0) = 2.0; // dauerhaft, radial

// --- 2. Blockversatz ------------------------------------------------------
uniform float block_shift : hint_range(0.0, 200.0) = 60.0; // max. Versatz in Pixeln
uniform float block_count : hint_range(2.0, 80.0) = 18.0;  // Zahl der Bänder
uniform float block_share : hint_range(0.0, 1.0) = 0.35;   // Anteil betroffener Bänder

// --- 3. Bildverschiebung --------------------------------------------------
uniform float frame_shift : hint_range(0.0, 60.0) = 10.0;  // Pixel bei vollem Glitch


float hash11(float p) {
	return fract(sin(p * 127.1) * 43758.5453);
}

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Außerhalb des Bildes: Schwarz. Der Hintergrund ist ohnehin schwarz,
// dadurch wirken Versätze wie echte Verschiebungen.
vec3 sample_rgb(sampler2D tex, vec2 uv) {
	float inside = step(0.0, uv.x) * step(uv.x, 1.0)
			* step(0.0, uv.y) * step(uv.y, 1.0);
	return texture(tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb * inside;
}


void fragment() {
	vec2 texel = 1.0 / vec2(textureSize(screen_tex, 0));

	// --- Ausbruch würfeln -------------------------------------------------
	// Pro Zeitfenster ein Wurf. Fällt er, startet ein Ausbruch, der über
	// das Fenster hinweg exponentiell abklingt: harter Einsatz, weiches Ende.
	float slot = floor(TIME * burst_rate);
	float phase = fract(TIME * burst_rate);
	float roll = hash11(slot);
	float hit = step(1.0 - burst_chance, roll);
	float auto_g = auto_glitch
			? hit * exp(-phase * burst_decay) * (0.4 + 0.6 * hash11(slot + 7.0))
			: 0.0;

	float g = clamp(glitch_amount + auto_g, 0.0, 1.0);
	// Seed wechselt pro Zeitfenster: jeder Ausbruch sieht anders aus
	float seed = slot;

	vec2 uv = SCREEN_UV;

	// --- 3. Bildverschiebung ----------------------------------------------
	vec2 jump = vec2(hash11(seed + 1.0) - 0.5, (hash11(seed + 2.0) - 0.5) * 0.35);
	uv += jump * 2.0 * frame_shift * g * texel;

	// --- 2. Blockversatz --------------------------------------------------
	// Bänder in Bildschirmhöhe, nicht in UV: bleibt bei anderer Auflösung gleich.
	float band = floor(uv.y * block_count + hash11(seed + 3.0) * 13.0);
	float pick = hash21(vec2(band, seed));
	float band_on = step(1.0 - block_share, pick);
	float off = (hash21(vec2(band, seed + 5.0)) - 0.5) * 2.0;
	uv.x += off * band_on * block_shift * g * texel.x;

	// --- 1. RGB-Split -----------------------------------------------------
	// Radiale Grundaberration (immer an) plus richtungsloser Glitch-Split.
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
