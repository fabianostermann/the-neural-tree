# layout.gd — attached to the node "Layout" (type: Node)
#
# Reads the tree from the TcpServer autoload and computes rest positions.
# Angle layout: the tree grows upward (-y), each branch splits off at an
# angle relative to its parent branch. The angle range is distributed by
# subtree size and pulled slightly toward the sky.
#
# TRUNK: a synthetic ground node is placed below every root
# (id = GROUND_PREFIX + root_id). The edge ground -> root is therefore
# the trunk — a perfectly normal edge that grows straight up.
#
# ATTACHMENT POINT: the tree structure lets every branch start at the tip of
# the parent branch. Visually, though, only the OLDEST branch may occupy the
# tip; all siblings added later attach further down the parent branch
# (att < 1). That's why every node has attach_rest besides rest — the point
# its branch grows out of.
#
# Output for the other layers:
#   rest        : Dictionary  id -> Vector2  (branch tip, ground at (0,0))
#   attach_rest : Dictionary  id -> Vector2  (branch foot on the parent branch)
#   att         : Dictionary  id -> float    (0..1 along the parent branch)
#   parent_of   : Dictionary  id -> String   ("" for ground nodes)
#   depth       : Dictionary  id -> int      (ground = 0, root = 1)
#   subtree     : Dictionary  id -> int      (for angle distribution)
#   thickness   : Dictionary  id -> float    (from Python, for branch thickness)
#   is_leaf     : Dictionary  id -> bool     (nodes without children)
#   max_depth   : int
#   order       : Array[String]  ids, parents always before their children
#   Signal layout_changed after every recomputation

extends Node

signal layout_changed

const GROUND_PREFIX := "__ground:"
const UP_ANGLE := -PI * 0.5          ## in Godot, -y points up

@export var TRUNK_LEN := 190.0             ## length of the trunk (ground -> root)
@export var BRANCH_LEN := 150.0            ## length of the first crown branches
@export var LEN_SHRINK := 0.6             ## each further level gets shorter
@export var LEAF_LEN := 20.0               ## leaves: same length everywhere ...
@export var LEAF_SIZE_JITTER := 0.15       ## ... except for +/- 15 % per leaf

@export var SPREAD := deg_to_rad(85.0)     ## base opening angle with two children
@export var SPREAD_PER_CHILD := deg_to_rad(12.0)  ## increase per additional child
@export var SPREAD_MAX := deg_to_rad(170.0)       ## upper limit
@export var WEIGHT_POWER := 0.35           ## 0 = all equal, 1 = fully by subtree
@export var THICK_POWER := 0.20            ## additional share of branch thickness, 0 = off

@export var UP_BIAS := 0.22                ## 0 = none, 1 = all branches vertical
@export var JITTER := deg_to_rad(8.0)      ## deterministic irregularity
@export var ROOT_SPACING := 400.0          ## spacing if there are several roots

## Attachment point of the trailing siblings, 1.0 = branch tip
@export var ATT_MIN := 0.30
@export var ATT_MAX := 0.95
@export var ATT_MIN_PARENT_DEPTH := 1      ## 2: trunk stays free of side branches

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
var _seen: Dictionary = {}           # cycle protection for faulty data
var _seniority: Dictionary = {}      # id -> counter, when first seen
var _next_seniority: int = 0
var _last_rev: int = -1


func _ready() -> void:
	TcpServer.tree_updated.connect(_on_tree_updated)
	# In case data already arrived before we were ready — deferred, so that
	# simulation and renderer have safely finished their _ready().
	if TcpServer.has_data():
		call_deferred("_on_tree_updated", TcpServer.rev)


func _on_tree_updated(rev: int) -> void:
	# Python resends the same snapshot as a keepalive — nothing to do.
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

	# Subtree sizes up front, they drive angle distribution and branch thickness
	_seen.clear()
	for g in grounds:
		_calc_subtree(g)

	var x := -ROOT_SPACING * 0.5 * float(grounds.size() - 1)
	_seen.clear()
	for g in grounds:
		_place(g, 0, UP_ANGLE, Vector2(x, 0.0), Vector2(x, 0.0))
		x += ROOT_SPACING

	layout_changed.emit()


# Remembers the order in which nodes first appeared.
# It's the only way to decide which branch may keep the tip —
# the IDs themselves say nothing about age.
func _track_seniority() -> void:
	for id in TcpServer.nodes:
		if not _seniority.has(id):
			_seniority[id] = _next_seniority
			_next_seniority += 1
	for id in _seniority.keys():
		if not TcpServer.nodes.has(id):
			_seniority.erase(id)


# parent pointers are the truth; we deliberately ignore the children lists
# from the JSON so that there is only one source.
# Returns the list of synthetic ground nodes.
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

	# Sorted, so that a structurally identical tree always looks the same
	for id in _children:
		_children[id].sort()

	# Hang a ground node below every root -> that becomes the trunk
	var grounds: Array[String] = []
	for root in TcpServer.roots:
		var gid: String = GROUND_PREFIX + root
		_children[gid] = [root]
		parent_of[gid] = ""
		parent_of[root] = gid
		# The trunk foot blends in the renderer to the thickness of the "parent
		# branch" — for the trunk that's the ground node, which therefore needs
		# the same thickness as the root.
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


# anchor is the foot point of the own branch, pos its tip.
# Children attach somewhere along the stretch anchor -> pos.
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

	# The oldest branch keeps the tip, all others move further down
	var senior: String = kids[0]
	for c in kids:
		if int(_seniority.get(c, 0)) < int(_seniority.get(senior, 0)):
			senior = c

	# A single child continues the branch in a straight line. With several, the
	# opening angle grows with their number, otherwise it gets cramped.
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
		ca = lerp_angle(ca, UP_ANGLE, UP_BIAS)      # toward the sun
		if d > 0:
			ca += _jitter(c)                        # trunk stays vertical

		var a := 1.0
		if c != senior and d >= ATT_MIN_PARENT_DEPTH:
			a = _rand_att(c)
		att[c] = a

		var base: Vector2 = anchor.lerp(pos, a)
		_place(c, d + 1, ca, base + Vector2.from_angle(ca) * _seg_len(d, c),
				base)


# How much opening angle a child gets. The subtree size says how much will
# still come of it; the branch thickness, how much area the branch already
# occupies now. Both exponents dampen strongly — at full weighting (1.0),
# small siblings would only get one or two degrees and overlap each other.
func _angle_weight(id: String) -> float:
	var s: float = pow(maxf(float(subtree.get(id, 1)), 1.0), WEIGHT_POWER)
	var w: float = pow(maxf(float(thickness.get(id, 2.0)), 1.0), THICK_POWER)
	return s * w


# d is the depth of the PARENT node.
# d == 0 -> ground to root: the trunk, fixed length.
# Leaves are the same size everywhere, independent of their depth.
func _seg_len(d: int, child: String) -> float:
	if d == 0:
		return TRUNK_LEN
	if _children.get(child, []).is_empty():
		return LEAF_LEN * _leaf_scale(child)
	return BRANCH_LEN * pow(LEN_SHRINK, float(d - 1))


# All three scatters hang on the ID and are therefore stable across updates —
# the same node always gets the same value. Different salts make sure the
# scatters are independent of each other.
func _hash01(id: String, salt: String) -> float:
	return float(absi(hash(id + salt)) % 10000) / 10000.0


func _jitter(id: String) -> float:
	return (_hash01(id, "|angle") * 2.0 - 1.0) * JITTER


func _leaf_scale(id: String) -> float:
	return 1.0 + (_hash01(id, "|leaf") * 2.0 - 1.0) * LEAF_SIZE_JITTER


func _rand_att(id: String) -> float:
	return lerpf(ATT_MIN, ATT_MAX, _hash01(id, "|att"))
