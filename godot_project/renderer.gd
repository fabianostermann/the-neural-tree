# renderer.gd — hängt am Node "Renderer" (Typ: Node2D)
#
# Liest ausschließlich Simulation.sim und zeichnet daraus.
#
# Beide Formen teilen sich dieselbe Mittellinie: eine quadratische Bezier
# vom Astfuß zur Knotenposition, deren Kontrollpunkt oberhalb der Sehne
# liegt. Je waagerechter, desto stärker die Krümmung nach oben.
#
#   Äste  — Breitenprofil verjüngt sich linear von Fuß zu Spitze.
#   Blätter (Knoten ohne Kinder) — Breitenprofil ist eine Blattform:
#     kurzer Stiel, dann breite Fläche mit Maximum bei ~36 % und
#     auslaufender Spitze. Die Größe hängt an rest_len und ist damit
#     überall gleich, unabhängig von der Tiefe im Baum.
#
# ASTFUSS: die Simulation rechnet den Ansatzpunkt auf der SEHNE des
# Elternastes aus, gezeichnet wird der Elternast aber als Bezier. Deshalb
# bestimmt der Renderer den Fußpunkt hier noch einmal selbst — diesmal auf
# der tatsächlichen Kurve, damit jeder Ast exakt auf dem Elternast sitzt
# statt daneben. Die Differenz beträgt wenige Pixel und wirkt sich nur auf
# den Zeichenpunkt aus, nicht auf die Physik.

extends Node2D

# --- Stellschrauben --------------------------------------------------------
const BOTTOM_MARGIN := 60.0        # Abstand des Stammfußes vom unteren Rand
const FIT_MARGIN := 60.0           # Rand beim automatischen Einpassen
const FIT_SMOOTH := 3.0            # Trägheit der Zoom-Anpassung

const BEND := -0.5                 # Krümmung Richtung Sonne
const SEGMENTS := 15               # Stützpunkte pro Ast
const LEAF_SEGMENTS := 30          # Blätter brauchen eine feinere Kontur

const WIDTH_K := 1.0               # Astdicke (px) = K * thickness^EXP
const WIDTH_EXP := 1.0            # 1.0 = proportional zur Python-Thickness
const WIDTH_MIN := 2.0
const WIDTH_MAX := 10000.0
const BASE_BLEND := 0.35           # wie stark der Astfuß zum Elternast passt

const LEAF_WIDTH := 0.44           # Blattbreite relativ zur Blattlänge
const LEAF_STALK := 0.18           # Anteil der Länge, der Stiel bleibt
const LEAF_STALK_W := 1.4          # Stieldicke
const LEAF_PROFILE_A := 0.45       # Blattform: t^A * (1-t)^B ...
const LEAF_PROFILE_B := 0.80
const LEAF_PROFILE_NORM := 2.26318 # ... normiert auf Maximum 1
const LEAF_HUE_JITTER := 0.05      # Farbstreuung pro Blatt
const MIDRIB := true               # Blattader zeichnen

const COLOR_TRUNK := Color(0.32, 0.24, 0.20)
const COLOR_BRANCH_TIP := Color(0.46, 0.38, 0.28)
const COLOR_LEAF := Color(0.48, 0.76, 0.38)
# ---------------------------------------------------------------------------

var _fit := 1.0

@onready var _sim: Node = get_node("../Simulation")


func _ready() -> void:
	_reposition()
	get_viewport().size_changed.connect(_reposition)


# Layoutursprung (Stammfuß) unten mittig im Viewport verankern.
func _reposition() -> void:
	var vp := get_viewport_rect().size
	position = Vector2(vp.x * 0.5, vp.y - BOTTOM_MARGIN)


func _process(delta: float) -> void:
	_update_fit(delta)
	queue_redraw()


# Der Baum ändert während der Performance seine Größe — hier wird er
# sanft so skaliert, dass er ins Bild passt. Skaliert wird um den
# Stammfuß, der dadurch an seinem Platz bleibt.
func _update_fit(delta: float) -> void:
	var sim: Dictionary = _sim.sim
	if sim.is_empty():
		return

	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for id in sim:
		var p: Vector2 = sim[id].pos
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))

	var vp := get_viewport_rect().size
	var avail_w := maxf(vp.x - FIT_MARGIN * 2.0, 1.0)
	var avail_h := maxf(vp.y - BOTTOM_MARGIN - FIT_MARGIN, 1.0)

	# Breite symmetrisch um den Stamm, Höhe nur nach oben
	var need_w := maxf(absf(lo.x), absf(hi.x)) * 2.0
	var need_h := absf(minf(lo.y, 0.0))

	var target := 1.0
	if need_w > 1.0:
		target = minf(target, avail_w / need_w)
	if need_h > 1.0:
		target = minf(target, avail_h / need_h)
	target = clampf(target, 0.05, 1.0)

	_fit = lerpf(_fit, target, 1.0 - exp(-FIT_SMOOTH * delta))
	scale = Vector2(_fit, _fit)


func _draw() -> void:
	var sim: Dictionary = _sim.sim

	if sim.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(-70.0, -200.0),
				"Warte auf Daten ...", HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				Color(1, 1, 1, 0.4))
		return

	var max_d := 1.0
	for id in sim:
		max_d = maxf(max_d, float(sim[id].depth))

	# Astfüße auf der gezeichneten Kurve — in einem Durchgang, weil
	# order Eltern vor Kindern liefert und der Fuß eines Astes auf der
	# Kurve des Elternastes liegt, die ihrerseits an dessen Fuß beginnt.
	var base: Dictionary = {}
	for id in _sim.order:
		if not sim.has(id):
			continue
		var n: Dictionary = sim[id]
		if n.parent == "" or not base.has(n.parent):
			base[id] = n.pos          # Bodenpunkt: Fuß ist er selbst
			continue
		var p: Dictionary = sim[n.parent]
		base[id] = _curve_point(base[n.parent], p.pos, n.att)

	# Erst das Holz (order läuft von innen nach außen: dicke Äste zuerst),
	# danach die Blätter, damit sie darüber liegen
	for id in _sim.order:
		var n := _edge(sim, base, id)
		if n.is_empty() or n.leaf:
			continue
		_draw_branch(sim, base[id], n, max_d)

	for id in _sim.order:
		var n := _edge(sim, base, id)
		if n.is_empty() or not n.leaf:
			continue
		_draw_leaf(id, base[id], n)


# Liefert den Knoten, wenn er eine zeichenbare Kante hat, sonst ein
# leeres Dictionary.
func _edge(sim: Dictionary, base: Dictionary, id: String) -> Dictionary:
	if not sim.has(id) or not base.has(id):
		return {}
	var n: Dictionary = sim[id]
	if n.parent == "" or not sim.has(n.parent):
		return {}
	if n.grow <= 0.001:
		return {}
	if base[id].distance_squared_to(n.pos) < 0.25:
		return {}
	return n


func _draw_branch(sim: Dictionary, a: Vector2, n: Dictionary,
		max_d: float) -> void:
	var p: Dictionary = sim[n.parent]
	var w_self := _width(n.thick)
	var w_base: float = lerpf(_width(p.thick), w_self, BASE_BLEND)
	var w_tip: float = w_self * lerpf(0.30, 1.0, n.grow)

	var f: float = float(n.depth) / max_d
	var col := COLOR_TRUNK.lerp(COLOR_BRANCH_TIP, f)

	draw_colored_polygon(_shape(a, n.pos, SEGMENTS,
			func(t: float) -> float: return lerpf(w_base, w_tip, t)), col)


func _draw_leaf(id: String, a: Vector2, n: Dictionary) -> void:
	var b: Vector2 = n.pos
	# Größe aus der Ruhelänge, nicht aus dem aktuellen Abstand: damit
	# bleiben Blätter überall gleich groß und zappeln nicht in der Breite.
	var blade: float = float(n.rest_len) * LEAF_WIDTH * n.grow

	var profile := func(t: float) -> float:
		# Stiel, der zur Blattfläche hin ausläuft ...
		var stalk: float = LEAF_STALK_W * maxf(0.0, 1.0 - t / LEAF_STALK)
		# ... und die Blattfläche selbst
		var u: float = clampf((t - LEAF_STALK) / (1.0 - LEAF_STALK), 0.0, 1.0)
		var w: float = blade * LEAF_PROFILE_NORM \
				* pow(u, LEAF_PROFILE_A) * pow(1.0 - u, LEAF_PROFILE_B)
		return maxf(maxf(stalk, w), 0.6)

	# Deterministische Farbstreuung: dasselbe Blatt bleibt sich treu
	var j := (float(absi(hash(id)) % 1000) / 1000.0 - 0.5) * 2.0
	var col := COLOR_LEAF
	col.h = fposmod(col.h + j * LEAF_HUE_JITTER, 1.0)
	col.v = clampf(col.v + j * 0.10, 0.0, 1.0)

	draw_colored_polygon(_shape(a, b, LEAF_SEGMENTS, profile), col)

	if MIDRIB:
		draw_polyline(_centerline(a, b, LEAF_SEGMENTS),
				col.darkened(0.35), maxf(blade * 0.06, 0.7), true)


# Bildet die Python-Thickness [2, inf] auf eine Pixelbreite ab.
func _width(thick: float) -> float:
	return clampf(WIDTH_K * pow(maxf(thick, 2.0), WIDTH_EXP),
			WIDTH_MIN, WIDTH_MAX)


# Kontrollpunkt der gemeinsamen Mittellinie: oberhalb der Sehne, mit
# der stärksten Krümmung bei waagerechten und ohne bei senkrechten Ästen.
func _control(a: Vector2, b: Vector2) -> Vector2:
	var d := b - a
	var l := d.length()
	if l < 0.001:
		return (a + b) * 0.5
	var bend := l * BEND * (1.0 - absf(d.y / l))
	return (a + b) * 0.5 + Vector2(0.0, -bend)


func _curve_point(a: Vector2, b: Vector2, t: float) -> Vector2:
	if t >= 1.0:
		return b
	var ctrl := _control(a, b)
	var inv := 1.0 - t
	return a * (inv * inv) + ctrl * (2.0 * inv * t) + b * (t * t)


func _centerline(a: Vector2, b: Vector2, segments: int) -> PackedVector2Array:
	var ctrl := _control(a, b)
	var pts := PackedVector2Array()
	for i in segments + 1:
		var t := float(i) / float(segments)
		var inv := 1.0 - t
		pts.append(a * (inv * inv) + ctrl * (2.0 * inv * t) + b * (t * t))
	return pts


# Baut ein Polygon um die Mittellinie; width_at(t) liefert die Breite.
func _shape(a: Vector2, b: Vector2, segments: int,
		width_at: Callable) -> PackedVector2Array:
	var ctrl := _control(a, b)
	var fallback := b - a

	var left := PackedVector2Array()
	var right := PackedVector2Array()

	for i in segments + 1:
		var t := float(i) / float(segments)
		var inv := 1.0 - t

		var pt := a * (inv * inv) + ctrl * (2.0 * inv * t) + b * (t * t)
		var tan := (ctrl - a) * (2.0 * inv) + (b - ctrl) * (2.0 * t)
		if tan.length_squared() < 0.0001:
			tan = fallback
		var nrm := tan.normalized().orthogonal()

		var hw: float = float(width_at.call(t)) * 0.5
		left.append(pt + nrm * hw)
		right.append(pt - nrm * hw)

	# Umlaufender Polygonzug: eine Seite hin, die andere zurück
	var poly := left
	for i in range(right.size() - 1, -1, -1):
		poly.append(right[i])
	return poly
