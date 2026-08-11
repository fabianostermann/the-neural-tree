# simulation.gd — hängt am Node "Simulation" (Typ: Node)
#
# Verlet-Simulation über den Ruhepositionen aus Layout, plus Wachstum.
#
# Wachstum: jeder Knoten hat grow (0..1). Die Astlänge im Constraint ist
# rest_len * grow, der Ast schiebt sich also physikalisch aus dem Elternast
# heraus statt nur eingeblendet zu werden. Ein Kind beginnt erst zu wachsen,
# wenn sein Elternast weit genug ist — dadurch läuft das Wachstum von innen
# nach außen durch den Baum. Entfernte Knoten verschwinden sofort.
#
# Die Feder zieht zu einer Ruhelage RELATIV zum Elternknoten
# (p.pos + local_rest * grow). Ein Ast merkt sich damit seinen Winkel zum
# Elternast, nicht seine absolute Position — nur so bewegt sich beim
# Schwanken des Stamms die ganze Krone mit.
#
# Ausgabe für den Renderer:
#   sim   : Dictionary  id -> { pos, prev, parent, depth, subtree, grow, ... }
#   order : Array[String]  ids, Eltern vor Kindern

extends Node

# --- Stellschrauben --------------------------------------------------------
const ITERATIONS := 4                       # Constraint-Durchläufe pro Schritt
const GRAVITY := Vector2(0.0, 240.0)        # +y = nach unten, lässt Äste hängen
const WIND_STRENGTH := 400.0
const WIND_DIR := Vector2(1.0, -0.15)

const GROW_SPEED := 220.0                   # Pixel pro Sekunde Astwachstum
const GROW_GATE := 0.55                     # ab hier darf das Kind loslegen

# Parameterverlauf von Wurzel (erster Wert) zu Blatt (zweiter Wert)
const STIFFNESS_RANGE := Vector2(160.0, 14.0)
const FLEX_RANGE := Vector2(0.05, 1.0)
const WEIGHT_RANGE := Vector2(0.15, 1.0)
const DAMPING_RANGE := Vector2(0.98, 0.90)
# ---------------------------------------------------------------------------

var sim: Dictionary = {}
var order: Array[String] = []

var _noise := FastNoiseLite.new()

@onready var _layout: Node = get_node("../Layout")


func _ready() -> void:
	_noise.seed = 7
	_noise.frequency = 1.0        # Koordinaten skalieren wir selbst
	_layout.layout_changed.connect(_on_layout_changed)


# Abgleich gegen das neue Layout: bestehende Knoten behalten pos/prev/grow
# und damit ihren Bewegungs- und Wachstumszustand, neue starten bei grow = 0
# an der Position ihres Elternknotens, verschwundene fallen ersatzlos weg.
func _on_layout_changed() -> void:
	var new_sim: Dictionary = {}

	for id in _layout.order:
		var r: Vector2 = _layout.rest[id]
		var d: int = _layout.depth[id]
		var parent: String = TcpServer.get_parent_id(id)

		var n: Dictionary
		if sim.has(id):
			n = sim[id]
		else:
			var spawn := r
			if parent != "" and sim.has(parent):
				spawn = sim[parent].pos            # wächst aus dem Elternast
			elif parent != "" and _layout.rest.has(parent):
				spawn = _layout.rest[parent]
			n = { "pos": spawn, "prev": spawn, "grow": 0.0 }

		# Ruhelage als fester Versatz zum Elternknoten
		var local_rest := Vector2.ZERO
		if parent != "" and _layout.rest.has(parent):
			local_rest = r - _layout.rest[parent]

		n.rest = r
		n.local_rest = local_rest
		n.rest_len = local_rest.length()
		n.parent = parent
		n.depth = d
		n.subtree = int(_layout.subtree.get(id, 1))

		if parent == "":
			n.grow = 1.0

		# Nach Tiefe: Stamm starr und träge, Spitzen weich und windanfällig
		var f := float(d) / float(_layout.max_depth)
		n.stiffness = lerpf(STIFFNESS_RANGE.x, STIFFNESS_RANGE.y, f)
		n.flex = lerpf(FLEX_RANGE.x, FLEX_RANGE.y, f)
		n.weight = lerpf(WEIGHT_RANGE.x, WEIGHT_RANGE.y, f)
		n.damping = lerpf(DAMPING_RANGE.x, DAMPING_RANGE.y, f)

		new_sim[id] = n

	sim = new_sim
	order = _layout.order.duplicate()


func _physics_process(delta: float) -> void:
	if sim.is_empty():
		return
	var t := Time.get_ticks_msec() / 1000.0

	# 1. Wachstum — order garantiert, dass der Elternwert schon aktuell ist
	for id in order:
		var n: Dictionary = sim[id]
		if n.parent == "":
			n.grow = 1.0
			continue
		if n.grow >= 1.0 or not sim.has(n.parent):
			continue
		if sim[n.parent].grow < GROW_GATE:
			continue
		n.grow = minf(1.0, n.grow + delta * GROW_SPEED / maxf(n.rest_len, 1.0))

	# 2. Integration
	for id in order:
		var n: Dictionary = sim[id]
		if n.parent == "" or not sim.has(n.parent):
			n.pos = n.rest                       # Wurzel ist verankert
			n.prev = n.rest
			continue

		var p: Dictionary = sim[n.parent]
		var target: Vector2 = p.pos + n.local_rest * n.grow

		var acc := Vector2.ZERO
		acc += GRAVITY * n.weight
		acc += _wind(n.pos, t) * n.flex * n.grow
		acc += (target - n.pos) * n.stiffness

		var vel: Vector2 = (n.pos - n.prev) * n.damping
		n.prev = n.pos
		n.pos += vel + acc * delta * delta

	# 3. Constraints: aktuelle Astlänge einhalten, Eltern vor Kindern,
	#    dabei nur das Kind bewegen (Bewegung propagiert nach außen)
	for _i in ITERATIONS:
		for id in order:
			var n: Dictionary = sim[id]
			if n.parent == "" or not sim.has(n.parent):
				continue
			var p: Dictionary = sim[n.parent]
			var target_len: float = n.rest_len * n.grow
			var d: Vector2 = n.pos - p.pos
			var l := d.length()
			if l > 0.001:
				n.pos = p.pos + d / l * target_len
			else:
				n.pos = p.pos + n.local_rest.normalized() * target_len


# Räumlich kohärentes Windfeld: benachbarte Äste sehen ähnliche Kräfte,
# Böen wandern von links nach rechts durchs Bild, und eine separate,
# viel langsamere Kurve lässt den Wind an- und abschwellen.
func _wind(p: Vector2, t: float) -> Vector2:
	var n := _noise.get_noise_3d(p.x * 0.006 - t * 0.5, p.y * 0.006, t * 0.4)
	var gust := 0.5 + 0.5 * _noise.get_noise_2d(t * 0.15, 500.0)
	return WIND_DIR * n * WIND_STRENGTH * gust
