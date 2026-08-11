# layout.gd — hängt am Node "Layout" (Typ: Node)
#
# Liest den Baum aus dem TcpServer-Autoload und berechnet Ruhepositionen.
# Winkel-Layout: die Wurzel sitzt bei (0,0) und wächst nach oben (-y),
# jeder Ast zweigt in einem Winkel relativ zu seinem Elternast ab.
# Der Winkelbereich wird nach Teilbaumgröße verteilt, damit große Äste
# mehr Platz bekommen, und leicht Richtung Himmel gezogen (Phototropismus).
#
# Ausgabe für die anderen Schichten:
#   rest      : Dictionary  id -> Vector2   (Ruheposition, Wurzel bei (0,0))
#   depth     : Dictionary  id -> int
#   subtree   : Dictionary  id -> int       (Knoten im Teilbaum, für Astdicke)
#   max_depth : int
#   order     : Array[String]  ids, Eltern stets vor ihren Kindern
#   Signal layout_changed nach jeder Neuberechnung

extends Node

signal layout_changed

const UP_ANGLE := -PI * 0.5          # in Godot zeigt -y nach oben

const BRANCH_LEN := 150.0            # Länge des Stammsegments
const LEN_SHRINK := 0.80             # jede Ebene wird um diesen Faktor kürzer
const SPREAD := deg_to_rad(85.0)     # Öffnungswinkel über alle Kinder
const UP_BIAS := 0.22                # 0 = keine, 1 = alle Äste senkrecht
const JITTER := deg_to_rad(8.0)      # deterministische Unregelmäßigkeit
const ROOT_SPACING := 400.0          # Abstand, falls es mehrere Wurzeln gibt

var rest: Dictionary = {}
var depth: Dictionary = {}
var subtree: Dictionary = {}
var max_depth: int = 1
var order: Array[String] = []

var _children: Dictionary = {}       # id -> Array[String], aus parent-Zeigern
var _seen: Dictionary = {}           # Zyklenschutz bei fehlerhaften Daten
var _last_rev: int = -1


func _ready() -> void:
	TcpServer.tree_updated.connect(_on_tree_updated)
	# Falls schon Daten anliegen, bevor wir bereit waren — deferred, damit
	# Simulation und Renderer ihr _ready() sicher hinter sich haben.
	if TcpServer.has_data():
		call_deferred("_on_tree_updated", TcpServer.rev)


func _on_tree_updated(rev: int) -> void:
	# Python sendet als Keepalive denselben Snapshot erneut — nichts zu tun.
	if rev == _last_rev and not rest.is_empty():
		return
	_last_rev = rev

	rest.clear()
	depth.clear()
	subtree.clear()
	order.clear()
	max_depth = 1

	_build_children()

	# Teilbaumgrößen vorab, sie steuern Winkelverteilung und Astdicke
	_seen.clear()
	for root in TcpServer.roots:
		_calc_subtree(root)

	var roots := TcpServer.roots
	var x := -ROOT_SPACING * 0.5 * float(roots.size() - 1)
	_seen.clear()
	for root in roots:
		_place(root, 0, UP_ANGLE, Vector2(x, 0.0))
		x += ROOT_SPACING

	layout_changed.emit()


# parent-Zeiger sind die Wahrheit; die children-Listen aus dem JSON
# ignorieren wir bewusst, damit es nur eine Quelle gibt.
func _build_children() -> void:
	_children.clear()
	for id in TcpServer.nodes:
		_children[id] = []
	for id in TcpServer.nodes:
		var p: String = TcpServer.nodes[id].parent
		if p != "" and _children.has(p):
			_children[p].append(id)
	# Sortiert, damit ein inhaltlich gleicher Baum immer gleich aussieht
	for id in _children:
		_children[id].sort()


func _calc_subtree(id: String) -> int:
	if _seen.has(id):
		return 0
	_seen[id] = true
	var s := 1
	for c in _children.get(id, []):
		s += _calc_subtree(c)
	subtree[id] = s
	return s


func _place(id: String, d: int, angle: float, pos: Vector2) -> void:
	if _seen.has(id):
		return
	_seen[id] = true

	rest[id] = pos
	depth[id] = d
	max_depth = maxi(max_depth, d)
	order.append(id)

	var kids: Array = _children.get(id, [])
	if kids.is_empty():
		return

	# Ein einzelnes Kind setzt den Ast geradlinig fort
	var span := SPREAD if kids.size() > 1 else 0.0

	var total := 0.0
	for c in kids:
		total += float(subtree.get(c, 1))
	if total <= 0.0:
		total = 1.0

	var seg_len: float = BRANCH_LEN * pow(LEN_SHRINK, float(d))
	var cursor := angle - span * 0.5

	for c in kids:
		var share: float = span * float(subtree.get(c, 1)) / total
		var ca := cursor + share * 0.5
		cursor += share
		ca = lerp_angle(ca, UP_ANGLE, UP_BIAS)   # Richtung Sonne
		ca += _jitter(c)
		_place(c, d + 1, ca, pos + Vector2.from_angle(ca) * seg_len)


# Aus der ID abgeleitet und damit über Updates hinweg stabil:
# derselbe Knoten bekommt immer denselben Versatz.
func _jitter(id: String) -> float:
	var h := absi(hash(id)) % 2000
	return (float(h) / 1000.0 - 1.0) * JITTER
