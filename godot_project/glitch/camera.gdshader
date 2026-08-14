// camera.gdshader — "abgefilmter Bildschirm"
//
// Gehört auf ein zweites bildschirmfüllendes ColorRect in einem EIGENEN
// CanvasLayer ÜBER dem Glitch-Layer (z.B. Glitch auf layer = 1, dieser
// auf layer = 2).
//
// Die Reihenfolge im Shader folgt dem echten Signalweg einer Handykamera:
//
//   1. GEOMETRIE   — Handzittern (Versatz) und leichtes Atmen (Zoom)
//   2. OPTIK       — Weichzeichnung, Farbkanäle unschärfer als Helligkeit
//   3. SENSOR      — Moiré (Sensorraster gegen Bildschirmraster),
//                    Rolling-Shutter-Bänder (Bildwiederholung gegen Belichtung)
//   4. VERARBEITUNG— Sättigung, Kontrast, angehobenes Schwarz
//   5. LINSE       — Vignette
//   6. KORN        — zeitlich wechselndes Rauschen, in dunklen Partien stärker
//
// HDR-sicher: keine Operation klemmt auf 1.0, Werte über 1.0 bleiben also
// erhalten und der Glow (der ganz am Ende läuft) funktioniert weiter.

shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

// --- 1. Handkamera --------------------------------------------------------
uniform float handheld : hint_range(0.0, 30.0) = 4.0;      // Versatz in Pixeln
uniform float breathe : hint_range(0.0, 0.05) = 0.006;     // Zoom-Atmen

// --- 2. Optik -------------------------------------------------------------
uniform float softness : hint_range(0.0, 8.0) = 1.6;       // Unschärfe in Pixeln
uniform float chroma_smear : hint_range(0.0, 1.0) = 0.6;   // Farbe unschärfer als Helligkeit

// --- 3. Sensor ------------------------------------------------------------
uniform float moire : hint_range(0.0, 0.5) = 0.10;
uniform float moire_period : hint_range(1.5, 12.0) = 3.0;  // Pixel pro Streifen
uniform float moire_angle : hint_range(0.0, 1.57) = 0.18;  // Verkippung in rad

uniform float rolling : hint_range(0.0, 0.6) = 0.14;       // Bandtiefe
uniform float rolling_bands : hint_range(0.5, 12.0) = 2.2; // Bänder im Bild
uniform float rolling_speed : hint_range(-4.0, 4.0) = 0.7; // Wanderung pro Sekunde

// --- 4. Verarbeitung ------------------------------------------------------
uniform float saturation : hint_range(0.0, 3.0) = 1.45;
uniform float contrast : hint_range(0.5, 3.0) = 1.30;
uniform float black_lift : hint_range(0.0, 0.15) = 0.03;   // Schwarz wird grau
uniform float exposure : hint_range(0.2, 3.0) = 1.05;

// --- 5. Linse -------------------------------------------------------------
uniform float vignette : hint_range(0.0, 1.5) = 0.45;

// --- 6. Korn --------------------------------------------------------------
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

	// --- 1. Handkamera ----------------------------------------------------
	// Summe langsamer Sinus mit unrunden Frequenzen: wirkt organisch,
	// wiederholt sich praktisch nie und kostet fast nichts.
	vec2 shake = vec2(
			sin(TIME * 0.71) * 0.6 + sin(TIME * 1.73 + 1.3) * 0.28
					+ sin(TIME * 3.11 + 2.7) * 0.12,
			sin(TIME * 0.89 + 2.1) * 0.6 + sin(TIME * 2.29 + 0.7) * 0.28
					+ sin(TIME * 3.67 + 1.1) * 0.12);

	float zoom = 1.0 + breathe * sin(TIME * 0.43);
	vec2 uv = (SCREEN_UV - 0.5) / zoom + 0.5 + shake * handheld * texel;

	// --- 2. Optik ---------------------------------------------------------
	// Fünf Abtastungen: Mitte plus Diagonalkreuz. Reicht für Weichheit,
	// ohne den Glow zu zerstören, der ohnehin noch darüberläuft.
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

	// Chroma-Smear: Helligkeit aus dem scharfen, Farbe aus dem weichen Bild.
	// Genau diese Trennung macht die Videokompression im Handy auch —
	// Farbauflösung ist dort halbiert, Helligkeitsauflösung nicht.
	const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
	float l_sharp = dot(sharp, LUMA);
	float l_soft = dot(soft, LUMA);
	vec3 chroma = soft - vec3(l_soft);
	vec3 col = mix(soft, vec3(l_sharp) + chroma, chroma_smear);

	// --- 3. Sensor --------------------------------------------------------
	// Moiré: zwei feine Gitter, eines leicht verkippt. Das Schwebungsmuster
	// aus beiden ist der eigentliche Effekt — deshalb zwei Frequenzen.
	if (moire > 0.001) {
		float ca = cos(moire_angle);
		float sa = sin(moire_angle);
		vec2 p = FRAGCOORD.xy / max(moire_period, 0.5);
		float g1 = sin(p.x * TAU);
		float g2 = sin((p.x * ca + p.y * sa) * TAU * 1.03);
		col *= 1.0 + (g1 * g2) * moire;
	}

	// Rolling Shutter: breite, weiche Bänder, die langsam nach oben wandern.
	if (rolling > 0.001) {
		float band = sin((SCREEN_UV.y * rolling_bands - TIME * rolling_speed) * TAU);
		col *= 1.0 - rolling * (0.5 + 0.5 * band);
	}

	// --- 4. Verarbeitung --------------------------------------------------
	col *= exposure;

	float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(l), col, saturation);

	// Kontrast um 0.5 herum — bleibt monoton, klemmt nicht, HDR überlebt
	col = (col - 0.5) * contrast + 0.5;

	// Erst hier negative Werte abfangen: der Kontrast drückt Schwarz unter
	// null, und die folgende Anhebung würde davon sonst aufgefressen.
	col = max(col, vec3(0.0));

	// Angehobenes Schwarz: ein abgefilmter Bildschirm hat nie echtes Schwarz
	col = col * (1.0 - black_lift) + black_lift;

	// --- 5. Vignette ------------------------------------------------------
	if (vignette > 0.001) {
		vec2 d = SCREEN_UV - 0.5;
		float r = dot(d, d) * 2.0;
		col *= 1.0 - vignette * r * r;
	}

	// --- 6. Korn ----------------------------------------------------------
	if (grain > 0.001) {
		float n = hash13(vec3(FRAGCOORD.xy, floor(TIME * 24.0))) - 0.5;
		float lum = clamp(dot(col, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
		float w = mix(1.0, 1.0 - lum, grain_in_shadows);
		col += n * grain * w;
	}

	col = max(col, vec3(0.0));
	COLOR = vec4(col, 1.0);
}
