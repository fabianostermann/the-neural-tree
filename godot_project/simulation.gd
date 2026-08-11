# simulation.gd — hängt am Node "Simulation" (Typ: Node)
#
# Wachstum plus Bewegung über den Ruhepositionen aus Layout.
#
# WINKELMODELL: die Position eines Knotens wird nicht integriert, sondern
# konstruiert:
#
#     pos = anchor + local_rest.rotated(theta_world) * grow
#
# Simuliert wird nur noch theta — die WINKELabweichung des Astes von seiner
# Ruhelage. Damit ist die Richtung eines Astes von der ersten Sekunde an
# festgelegt (sie steht ja im Layout) und Wachstum verlängert ihn lediglich.
# Kräfte können den Ast neigen, aber nie seine Richtung erfinden.
#
# theta_world = theta_world des Elternastes + eigenes theta. Abweichungen
# summieren sich also nach außen auf: der Stamm neigt sich kaum, jeder
# weitere Ast legt etwas drauf, die Spitzen bewegen sich am meisten.
# Genau das lässt eine Windböe durch den Baum laufen.
#
# WEICHE RUHELAGE: kommt ein Geschwisterast dazu, verteilt Layout den
# Öffnungswinkel neu — die Ruhelage ALLER Geschwister ändert sich also
# schlagartig. Deshalb wird jede Größe aus dem Layout (local_rest, att,
# rest, thickness) nicht direkt übernommen, sondern als *_target abgelegt
# und pro Frame weich nachgezogen. Nur neue Knoten übernehmen sofort, damit
# sie von Anfang an in die richtige Richtung wachsen.
#
# Ausgabe für den Renderer:
#   sim   : Dictionary  id -> { pos, anchor, att, parent, depth, subtree,
#                               thick, leaf, grow, rest_len, ... }
#   order : Array[String]  ids, Eltern vor Kindern

extends Node

# --- Stellschrauben --------------------------------------------------------
const GRAVITY := Vector2(0.0, 30.0)         # +y = nach unten, lässt Äste hängen
const WIND_STRENGTH := 20.0
const WIND_DIR := Vector2(1.0, -0.15)

const GROW_SPEED := 20.0                    # Pixel pro Sekunde Astwachstum
const GROW_GATE := 0.4                      # ab hier darf das Kind loslegen

const MAX_BEND := deg_to_rad(35.0)          # Neigung eines EINZELNEN Astes

# Parameterverlauf von Wurzel (erster Wert) zu Blatt (zweiter Wert)
const STIFFNESS_RANGE := Vector2(700.0, 120.0)   # Widerstand gegen Kräfte
const RESPONSE_RANGE := Vector2(18.0, 70.0)      # wie schnell nachgegeben wird
const DAMPING_RANGE := Vector2(0.96, 0.90)       # Ausschwingen pro Schritt
const WEIGHT_RANGE := Vector2(0.15, 1.0)         # Empfindlichkeit für Schwere
const FLEX_RANGE := Vector2(0.05, 1.0)           # Empfindlichkeit für Wind

const LEAF_FLEX_BOOST := 1.6                # Blätter flattern etwas mehr

const THICK_SMOOTH := 4.0                   # Trägheit bei Dickenänderungen
const SHAPE_SMOOTH := 0.5                   # Trägheit bei Layoutänderungen
# ---------------------------------------------------------------------------

var sim: Dictionary = {}
var order: Array[String] = []

var _noise := FastNoiseLite.new()

@onready var _layout: Node = get_node("../Layout")


func _ready() -> void:
	_noise.seed = 7
	_noise.frequency = 1.0        # Koordinaten skalieren wir selbst
	_layout.layout_changed.connect(_on_layout_changed)


# Abgleich gegen das neue Layout: bestehende Knoten behalten grow, ihre
# Winkelauslenkung UND ihre bisherige Ruhelage — sie bekommen lediglich neue
# Zielwerte, die _physics_process weich nachzieht. Neue Knoten übernehmen
# sofort und starten bei grow = 0 und theta = 0, also exakt in der Richtung,
# die ihr Elternast gerade hat. Verschwundene fallen ersatzlos weg.
func _on_layout_changed() -> void:
	var new_sim: Dictionary = {}

	for id in _layout.order:
		var r: Vector2 = _layout.rest[id]
		var base: Vector2 = _layout.attach_rest.get(id, r)
		var d: int = _layout.depth[id]
		var parent: String = _layout.parent_of.get(id, "")

		var local: Vector2 = r - base               # Ruhelage relativ zum Anker
		var a: float = float(_layout.att.get(id, 1.0))
		var thick: float = float(_layout.thickness.get(id, 2.0))

		var n: Dictionary
		if sim.has(id):
			n = sim[id]
		else:
			n = { "pos": base, "anchor": base, "grow": 0.0,
					"theta": 0.0, "omega": 0.0, "theta_world": 0.0,
					"rest": r, "local_rest": local, "att": a, "thick": thick }

		# Zielwerte — die aktuellen Werte gleiten in _physics_process dorthin
		n.rest_target = r
		n.local_rest_target = local
		n.att_target = a
		n.thick_target = thick

		n.rest_len = float(n.local_rest.length())
		n.parent = parent
		n.depth = d
		n.subtree = int(_layout.subtree.get(id, 1))
		n.leaf = bool(_layout.is_leaf.get(id, false))

		if parent == "":
			n.grow = 1.0

		# Nach Tiefe: Stamm starr und träge, Spitzen weich und windanfällig
		var f := float(d) / float(_layout.max_depth)
		n.stiffness = lerpf(STIFFNESS_RANGE.x, STIFFNESS_RANGE.y, f)
		n.response = lerpf(RESPONSE_RANGE.x, RESPONSE_RANGE.y, f)
		n.damping = lerpf(DAMPING_RANGE.x, DAMPING_RANGE.y, f)
		n.weight = lerpf(WEIGHT_RANGE.x, WEIGHT_RANGE.y, f)
		n.flex = lerpf(FLEX_RANGE.x, FLEX_RANGE.y, f)
		if n.leaf:
			n.flex *= LEAF_FLEX_BOOST

		new_sim[id] = n

	sim = new_sim
	order = _layout.order.duplicate()


func _physics_process(delta: float) -> void:
	if sim.is_empty():
		return
	var t := Time.get_ticks_msec() / 1000.0

	var k_shape := 1.0 - exp(-SHAPE_SMOOTH * delta)
	var k_thick := 1.0 - exp(-THICK_SMOOTH * delta)

	# Ein einziger Durchgang. order liefert Eltern vor Kindern, also stehen
	# anchor und theta_world des Elternastes jeweils schon fest.
	for id in order:
		var n: Dictionary = sim[id]

		# 0. Layout- und Dickenänderungen weich nachziehen. local_rest wird
		#    über Winkel UND Länge interpoliert, nicht komponentenweise:
		#    sonst würde der Ast beim Drehen über die Sehne abkürzen und
		#    dabei kurz schrumpfen.
		n.rest = n.rest.lerp(n.rest_target, k_shape)
		n.local_rest = _approach(n.local_rest, n.local_rest_target, k_shape)
		n.att = lerpf(n.att, n.att_target, k_shape)
		n.rest_len = n.local_rest.length()
		n.thick = lerpf(n.thick, n.thick_target, k_thick)

		if n.parent == "" or not sim.has(n.parent):
			n.pos = n.rest                        # Bodenpunkt ist verankert
			n.anchor = n.rest
			n.theta_world = 0.0
			n.grow = 1.0
			continue

		var p: Dictionary = sim[n.parent]

		# 1. Wachstum. Ein Seitenast wartet, bis der Elternast überhaupt
		#    bis zu seinem Ansatzpunkt gewachsen ist.
		if n.grow < 1.0 and p.grow >= maxf(GROW_GATE, n.att):
			n.grow = minf(1.0,
					n.grow + delta * GROW_SPEED / maxf(n.rest_len, 1.0))

		# 2. Ansatzpunkt auf dem Elternast
		n.anchor = p.anchor.lerp(p.pos, n.att)

		# 3. Winkel. Das Drehmoment ist die Querkomponente der Kräfte
		#    bezogen auf die Astrichtung: ein senkrechter Ast hängt unter
		#    Schwerkraft nicht durch, ein waagerechter maximal.
		var dir: Vector2 = n.local_rest.rotated(p.theta_world + n.theta)
		if dir.length_squared() > 0.0001:
			dir = dir.normalized()

			var force: Vector2 = GRAVITY * n.weight + _wind(n.pos, t) * n.flex
			var torque: float = dir.cross(force) * n.grow
			var target: float = clampf(torque / n.stiffness,
					-MAX_BEND, MAX_BEND)

			n.omega += (target - n.theta) * n.response * delta
			n.omega *= n.damping
			n.theta += n.omega * delta
			if absf(n.theta) > MAX_BEND:
				n.theta = clampf(n.theta, -MAX_BEND, MAX_BEND)
				n.omega = 0.0                     # nicht am Anschlag kleben

		# 4. Position — Richtung aus dem Layout, Länge aus dem Wachstum
		n.theta_world = p.theta_world + n.theta
		n.pos = n.anchor + n.local_rest.rotated(n.theta_world) * n.grow


# Nähert einen Vektor seinem Ziel an, indem Winkel und Länge GETRENNT
# interpoliert werden — bei einer Drehung um 40° würde die komponentenweise
# Interpolation den Vektor zwischenzeitlich um rund 6 % verkürzen.
func _approach(cur: Vector2, target: Vector2, k: float) -> Vector2:
	var tl := target.length()
	var cl := cur.length()
	if tl < 0.001 and cl < 0.001:
		return target
	var ta := target.angle() if tl > 0.001 else cur.angle()
	var ca := cur.angle() if cl > 0.001 else ta
	return Vector2.from_angle(lerp_angle(ca, ta, k)) * lerpf(cl, tl, k)


# Räumlich kohärentes Windfeld: benachbarte Äste sehen ähnliche Kräfte,
# Böen wandern von links nach rechts durchs Bild, und eine separate,
# viel langsamere Kurve lässt den Wind an- und abschwellen.
func _wind(p: Vector2, t: float) -> Vector2:
	var n := _noise.get_noise_3d(p.x * 0.006 - t * 0.5, p.y * 0.006, t * 0.4)
	var gust := 0.5 + 0.5 * _noise.get_noise_2d(t * 0.15, 500.0)
	return WIND_DIR * n * WIND_STRENGTH * gust
