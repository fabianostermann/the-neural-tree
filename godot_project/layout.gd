# layout.gd — hängt am Node "Layout" (Typ: Node)
#
# Liest den Baum aus dem TcpServer-Autoload und berechnet Ruhepositionen.
# Winkel-Layout: der Baum wächst nach oben (-y), jeder Ast zweigt in einem
# Winkel relativ zu seinem Elternast ab. Der Winkelbereich wird nach
# Teilbaumgröße verteilt und leicht Richtung Himmel gezogen.
#
# STAMM: unter jede Wurzel wird ein synthetischer Bodenknoten gesetzt
# (id = GROUND_PREFIX + wurzel_id). Die Kante Boden -> Wurzel ist damit
# der Stamm — eine ganz normale Kante, die senkrecht nach oben wächst.
#
# ANSATZPUNKT: die Baumstruktur lässt jeden Ast an der Spitze des
# Elternastes beginnen. Rein visuell darf aber nur der ÄLTESTE Ast die
# Spitze belegen; alle später hinzugekommenen Geschwister setzen weiter
# unten am Elternast an (att < 1). Deshalb hat jeder Knoten neben rest
# auch attach_rest — den Punkt, aus dem sein Ast herauswächst.
#
# Ausgabe für die anderen Schichten:
#   rest        : Dictionary  id -> Vector2  (Astspitze, Boden bei (0,0))
#   attach_rest : Dictionary  id -> Vector2  (Astfuß am Elternast)
#   att         : Dictionary  id -> float    (0..1 entlang des Elternastes)
#   parent_of   : Dictionary  id -> String   ("" bei Bodenknoten)
#   depth       : Dictionary  id -> int      (Boden = 0, Wurzel = 1)
#   subtree     : Dictionary  id -> int      (für Winkelverteilung)
#   thickness   : Dictionary  id -> float    (aus Python, für die Astdicke)
#   is_leaf     : Dictionary  id -> bool     (Knoten ohne Kinder)
#   max_depth   : int
#   order       : Array[String]  ids, Eltern stets vor ihren Kindern
#   Signal layout_changed nach jeder Neuberechnung

extends Node

signal layout_changed

const GROUND_PREFIX := "__ground:"
const UP_ANGLE := -PI * 0.5          ## in Godot zeigt -y nach oben

@export var TRUNK_LEN := 190.0             ## Länge des Stamms (Boden -> Wurzel)
@export var BRANCH_LEN := 150.0            ## Länge der ersten Kronenäste
@export var LEN_SHRINK := 0.6             ## jede weitere Ebene wird kürzer
@export var LEAF_LEN := 20.0               ## Blätter: überall gleich lang ...
@export var LEAF_SIZE_JITTER := 0.15       ## ... bis auf +/- 15 % pro Blatt

@export var SPREAD := deg_to_rad(85.0)     ## Grundöffnungswinkel bei zwei Kindern
@export var SPREAD_PER_CHILD := deg_to_rad(12.0)  ## Zuwachs je weiterem Kind
@export var SPREAD_MAX := deg_to_rad(170.0)       ## Obergrenze
@export var WEIGHT_POWER := 0.35           ## 0 = alle gleich, 1 = voll nach Teilbaum
@export var THICK_POWER := 0.20            ## zusätzlicher Anteil der Astdicke, 0 = aus

@export var UP_BIAS := 0.22                ## 0 = keine, 1 = alle Äste senkrecht
@export var JITTER := deg_to_rad(8.0)      ## deterministische Unregelmäßigkeit
@export var ROOT_SPACING := 400.0          ## Abstand, falls es mehrere Wurzeln gibt

## Ansatzpunkt der nachrückenden Geschwister, 1.0 = Astspitze
@export var ATT_MIN := 0.30
@export var ATT_MAX := 0.95
@export var ATT_MIN_PARENT_DEPTH := 1      ## 2: Stamm bleibt frei von Seitenästen

var rest: Dictionary = {}
var attach_rest: Dictionary = {}
var att: Dictionary = {}
var parent_of: Dictionary = {}
var depth: Dictionary = {}
var subtree: Dictionary = {}
var thickness: Dictionary = {}
var is_leaf: Dictionary = {}
var max_depth: int = 1
var order: Array[String] = []

var _children: Dictionary = {}       # id -> Array[String]
var _seen: Dictionary = {}           # Zyklenschutz bei fehlerhaften Daten
var _seniority: Dictionary = {}      # id -> Zähler, wann zuerst gesehen
var _next_seniority: int = 0
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
	attach_rest.clear()
	att.clear()
	depth.clear()
	subtree.clear()
	thickness.clear()
	is_leaf.clear()
	order.clear()
	max_depth = 1

	_track_seniority()
	var grounds := _build_children()

	for id in _children:
		is_leaf[id] = _children[id].is_empty()

	# Teilbaumgrößen vorab, sie steuern Winkelverteilung und Astdicke
	_seen.clear()
	for g in grounds:
		_calc_subtree(g)

	var x := -ROOT_SPACING * 0.5 * float(grounds.size() - 1)
	_seen.clear()
	for g in grounds:
		_place(g, 0, UP_ANGLE, Vector2(x, 0.0), Vector2(x, 0.0))
		x += ROOT_SPACING

	layout_changed.emit()


# Merkt sich, in welcher Reihenfolge Knoten zum ersten Mal aufgetaucht sind.
# Nur so lässt sich entscheiden, welcher Ast die Spitze behalten darf —
# die IDs selbst sagen nichts über das Alter aus.
func _track_seniority() -> void:
	for id in TcpServer.nodes:
		if not _seniority.has(id):
			_seniority[id] = _next_seniority
			_next_seniority += 1
	for id in _seniority.keys():
		if not TcpServer.nodes.has(id):
			_seniority.erase(id)


# parent-Zeiger sind die Wahrheit; die children-Listen aus dem JSON
# ignorieren wir bewusst, damit es nur eine Quelle gibt.
# Gibt die Liste der synthetischen Bodenknoten zurück.
func _build_children() -> Array[String]:
	_children.clear()
	parent_of.clear()

	for id in TcpServer.nodes:
		_children[id] = []
		thickness[id] = TcpServer.get_thickness(id)
	for id in TcpServer.nodes:
		var p: String = TcpServer.nodes[id].parent
		parent_of[id] = p
		if p != "" and _children.has(p):
			_children[p].append(id)

	# Sortiert, damit ein inhaltlich gleicher Baum immer gleich aussieht
	for id in _children:
		_children[id].sort()

	# Unter jede Wurzel einen Bodenknoten hängen -> daraus wird der Stamm
	var grounds: Array[String] = []
	for root in TcpServer.roots:
		var gid: String = GROUND_PREFIX + root
		_children[gid] = [root]
		parent_of[gid] = ""
		parent_of[root] = gid
		# Der Stammfuß blendet im Renderer zur Dicke des "Elternastes" —
		# beim Stamm ist das der Bodenknoten, der deshalb dieselbe Dicke
		# wie die Wurzel braucht.
		thickness[gid] = thickness.get(root, 2.0)
		grounds.append(gid)
	return grounds


func _calc_subtree(id: String) -> int:
	if _seen.has(id):
		return 0
	_seen[id] = true
	var s := 1
	for c in _children.get(id, []):
		s += _calc_subtree(c)
	subtree[id] = s
	return s


# anchor ist der Fußpunkt des eigenen Astes, pos dessen Spitze.
# Kinder setzen irgendwo auf der Strecke anchor -> pos an.
func _place(id: String, d: int, angle: float, pos: Vector2,
		anchor: Vector2) -> void:
	if _seen.has(id):
		return
	_seen[id] = true

	rest[id] = pos
	attach_rest[id] = anchor
	depth[id] = d
	max_depth = maxi(max_depth, d)
	order.append(id)

	var kids: Array = _children.get(id, [])
	if kids.is_empty():
		return

	# Der älteste Ast behält die Spitze, alle anderen rücken nach unten
	var senior: String = kids[0]
	for c in kids:
		if int(_seniority.get(c, 0)) < int(_seniority.get(senior, 0)):
			senior = c

	# Ein einzelnes Kind setzt den Ast geradlinig fort. Bei mehreren wächst
	# der Öffnungswinkel mit ihrer Zahl, sonst wird es eng.
	var span := 0.0
	if kids.size() > 1:
		span = minf(SPREAD + SPREAD_PER_CHILD * float(kids.size() - 2),
				SPREAD_MAX)
				
	var total := 0.0
	for c in kids:
		total += _angle_weight(c)

	if total <= 0.0:
		total = 1.0

	var cursor := angle - span * 0.5

	for c in kids:
		var share: float = span * _angle_weight(c) / total
		var ca := cursor + share * 0.5
		cursor += share
		ca = lerp_angle(ca, UP_ANGLE, UP_BIAS)      # Richtung Sonne
		if d > 0:
			ca += _jitter(c)                        # Stamm bleibt senkrecht

		var a := 1.0
		if c != senior and d >= ATT_MIN_PARENT_DEPTH:
			a = _rand_att(c)
		att[c] = a

		var base: Vector2 = anchor.lerp(pos, a)
		_place(c, d + 1, ca, base + Vector2.from_angle(ca) * _seg_len(d, c),
				base)


# Wie viel Öffnungswinkel ein Kind bekommt. Die Teilbaumgröße sagt, wie viel
# noch daraus wird; die Astdicke, wie viel Fläche der Ast schon jetzt belegt.
# Beide Exponenten dämpfen kräftig — mit voller Gewichtung (1.0) bekämen
# kleine Geschwister nur noch ein bis zwei Grad und lägen übereinander.
func _angle_weight(id: String) -> float:
	var s: float = pow(maxf(float(subtree.get(id, 1)), 1.0), WEIGHT_POWER)
	var w: float = pow(maxf(float(thickness.get(id, 2.0)), 1.0), THICK_POWER)
	return s * w


# d ist die Tiefe des ELTERNknotens.
# d == 0 -> Boden zur Wurzel: der Stamm, feste Länge.
# Blätter sind überall gleich groß, unabhängig von ihrer Tiefe.
func _seg_len(d: int, child: String) -> float:
	if d == 0:
		return TRUNK_LEN
	if _children.get(child, []).is_empty():
		return LEAF_LEN * _leaf_scale(child)
	return BRANCH_LEN * pow(LEN_SHRINK, float(d - 1))


# Alle drei Streuungen hängen an der ID und sind damit über Updates hinweg
# stabil — derselbe Knoten bekommt immer denselben Wert. Unterschiedliche
# Salze sorgen dafür, dass die Streuungen voneinander unabhängig sind.
func _hash01(id: String, salt: String) -> float:
	return float(absi(hash(id + salt)) % 10000) / 10000.0


func _jitter(id: String) -> float:
	return (_hash01(id, "|angle") * 2.0 - 1.0) * JITTER


func _leaf_scale(id: String) -> float:
	return 1.0 + (_hash01(id, "|leaf") * 2.0 - 1.0) * LEAF_SIZE_JITTER


func _rand_att(id: String) -> float:
	return lerpf(ATT_MIN, ATT_MAX, _hash01(id, "|att"))
