# renderer.gd — hängt am Node "Renderer" (Typ: Node2D)
#
# Liest ausschließlich Simulation.sim und zeichnet daraus.
# Jeder Ast ist eine quadratische Bezier von der Elternposition zur
# Knotenposition, als sich verjüngendes Polygon gefüllt. Der Kontrollpunkt
# liegt oberhalb der Sehne, wodurch sich Äste nach oben biegen — je
# waagerechter der Ast, desto stärker.
#
# Die Wachstumsanimation entsteht komplett in der Simulation (die Astlänge
# selbst wächst), hier wird nur zusätzlich die Spitze dünner gehalten,
# solange der Ast noch jung ist.

extends Node2D

# --- Stellschrauben --------------------------------------------------------
const BOTTOM_MARGIN := 60.0        # Abstand des Stammfußes vom unteren Rand
const FIT_MARGIN := 60.0           # Rand beim automatischen Einpassen
const FIT_SMOOTH := 3.0            # Trägheit der Zoom-Anpassung

const BEND := 0.20                 # Krümmung Richtung Sonne
const SEGMENTS := 10               # Stützpunkte pro Ast

const WIDTH_K := 2.0               # Astdicke = K * subtree^EXP
const WIDTH_EXP := 0.42
const WIDTH_MIN := 1.6
const WIDTH_MAX := 26.0
const BASE_BLEND := 0.35           # wie stark der Astfuß zum Elternast passt

const COLOR_TRUNK := Color(0.32, 0.24, 0.20)
const COLOR_TIP := Color(0.55, 0.78, 0.45)
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

	# order läuft von der Wurzel nach außen: dicke Äste zuerst,
	# dünne Zweige zeichnen sich sauber darüber
	for id in _sim.order:
		if not sim.has(id):
			continue
		var n: Dictionary = sim[id]
		if n.parent == "" or not sim.has(n.parent):
			continue
		if n.grow <= 0.001:
			continue

		var p: Dictionary = sim[n.parent]
		var a: Vector2 = p.pos
		var b: Vector2 = n.pos
		if a.distance_squared_to(b) < 0.25:
			continue

		var w_self := _width(n.subtree)
		var w_base: float = lerpf(_width(p.subtree), w_self, BASE_BLEND)
		var w_tip: float = w_self * lerpf(0.30, 1.0, n.grow)

		var f: float = float(n.depth) / max_d
		var col := COLOR_TRUNK.lerp(COLOR_TIP, f)

		draw_colored_polygon(_branch(a, b, w_base, w_tip), col)


func _width(subtree_size: int) -> float:
	return clampf(WIDTH_K * pow(float(maxi(subtree_size, 1)), WIDTH_EXP),
			WIDTH_MIN, WIDTH_MAX)


# Quadratische Bezier von a nach b, als sich verjüngendes Polygon.
# Der Kontrollpunkt liegt oberhalb der Mitte; waagerechte Äste bekommen
# die stärkste Krümmung, senkrechte bleiben gerade.
func _branch(a: Vector2, b: Vector2, w_a: float, w_b: float) -> PackedVector2Array:
	var d := b - a
	var l := d.length()
	var dir := d / l
	var bend := l * BEND * (1.0 - absf(dir.y))
	var ctrl := (a + b) * 0.5 + Vector2(0.0, -bend)

	var left := PackedVector2Array()
	var right := PackedVector2Array()

	for i in SEGMENTS + 1:
		var t := float(i) / float(SEGMENTS)
		var inv := 1.0 - t

		var pt := a * (inv * inv) + ctrl * (2.0 * inv * t) + b * (t * t)
		var tan := (ctrl - a) * (2.0 * inv) + (b - ctrl) * (2.0 * t)
		if tan.length_squared() < 0.0001:
			tan = d
		var nrm := tan.normalized().orthogonal()

		var hw: float = lerpf(w_a, w_b, t) * 0.5
		left.append(pt + nrm * hw)
		right.append(pt - nrm * hw)

	# Umlaufender Polygonzug: eine Seite hin, die andere zurück
	var poly := left
	for i in range(right.size() - 1, -1, -1):
		poly.append(right[i])
	return poly
