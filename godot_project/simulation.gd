# simulation.gd — attached to the node "Simulation" (type: Node)
#
# Growth plus motion on top of the rest positions from Layout.
#
# ANGLE MODEL: a node's position is not integrated, but
# constructed:
#
#     pos = anchor + local_rest.rotated(theta_world) * grow
#
# Only theta is simulated — the ANGULAR deviation of the branch from its
# rest pose. This fixes a branch's direction from the first second on
# (it's in the layout, after all) and growth merely lengthens it.
# Forces can tilt the branch, but never invent its direction.
#
# theta_world = theta_world of the parent branch + own theta. Deviations
# therefore accumulate outward: the trunk barely tilts, each
# further branch adds a bit, the tips move the most.
# That's exactly what lets a gust of wind run through the tree.
#
# SOFT REST POSE: when a sibling branch is added, Layout redistributes the
# opening angle — so the rest pose of ALL siblings changes
# abruptly. That's why every quantity from the layout (local_rest, att,
# rest, thickness) is not adopted directly, but stored as *_target
# and eased toward per frame. Only new nodes adopt immediately, so that
# they grow in the right direction from the start.
#
# Output for the renderer:
#   sim   : Dictionary  id -> { pos, anchor, att, parent, depth, subtree,
#                               thick, leaf, grow, rest_len, ... }
#   order : Array[String]  ids, parents before children

extends Node

# --- Tuning knobs ----------------------------------------------------------
@export var GRAVITY := Vector2(0.0, 30.0)         ## +y = downward, makes branches droop
@export var WIND_STRENGTH := 20.0
@export var WIND_DIR := Vector2(1.0, -0.15)

@export var GROW_SPEED := 20.0                   ## pixels per second of branch growth
@export var GROW_GATE := 0.1                      ## from here on the child may start

@export var MAX_BEND := deg_to_rad(35.0)          ## tilt of a SINGLE branch

# Parameter gradient from root (first value) to leaf (second value)
@export var STIFFNESS_RANGE := Vector2(1000.0, 200.0)   ## resistance against forces
@export var RESPONSE_RANGE := Vector2(18.0, 140.0)      ## how quickly it yields
@export var DAMPING_RANGE := Vector2(0.99, 0.95)       ## ring-out per step
@export var WEIGHT_RANGE := Vector2(0.15, 1.0)         ## sensitivity to gravity
@export var FLEX_RANGE := Vector2(0.05, 1.0)           ## sensitivity to wind

@export var LEAF_FLEX_BOOST := 15              ## leaves flutter a bit more

@export var THICK_SMOOTH := 4.0                   ## inertia on thickness changes
@export var SHAPE_SMOOTH := 0.5                   ## inertia on layout changes
# ---------------------------------------------------------------------------

var sim: Dictionary = {}
var order: Array[String] = []

var _noise := FastNoiseLite.new()

@onready var _layout: Node = get_node("../Layout")


func _ready() -> void:
	_noise.seed = 7
	_noise.frequency = 1.0        # we scale the coordinates ourselves
	_layout.layout_changed.connect(_on_layout_changed)


# Reconciliation against the new layout: existing nodes keep grow, their
# angular deflection AND their previous rest pose — they merely get new
# target values that _physics_process eases toward. New nodes adopt
# immediately and start at grow = 0 and theta = 0, i.e. exactly in the direction
# their parent branch currently has. Vanished ones are simply dropped.
func _on_layout_changed() -> void:
	var new_sim: Dictionary = {}

	for id in _layout.order:
		var r: Vector2 = _layout.rest[id]
		var base: Vector2 = _layout.attach_rest.get(id, r)
		var d: int = _layout.depth[id]
		var parent: String = _layout.parent_of.get(id, "")

		var local: Vector2 = r - base               # rest pose relative to the anchor
		var a: float = float(_layout.att.get(id, 1.0))
		var thick: float = float(_layout.thickness.get(id, 2.0))

		var n: Dictionary
		if sim.has(id):
			n = sim[id]
		else:
			n = { "pos": base, "anchor": base, "grow": 0.0,
					"theta": 0.0, "omega": 0.0, "theta_world": 0.0,
					"rest": r, "local_rest": local, "att": a, "thick": thick }

		# Target values — the current values glide toward them in _physics_process
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

		# By depth: trunk rigid and sluggish, tips soft and wind-prone
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

	# A single pass. order delivers parents before children, so
	# anchor and theta_world of the parent branch are already fixed each time.
	for id in order:
		var n: Dictionary = sim[id]

		# 0. Ease toward layout and thickness changes. local_rest is
		#    interpolated over angle AND length, not component-wise:
		#    otherwise the branch would cut across the chord while turning
		#    and briefly shrink in the process.
		n.rest = n.rest.lerp(n.rest_target, k_shape)
		n.local_rest = _approach(n.local_rest, n.local_rest_target, k_shape)
		n.att = lerpf(n.att, n.att_target, k_shape)
		n.rest_len = n.local_rest.length()
		n.thick = lerpf(n.thick, n.thick_target, k_thick)

		if n.parent == "" or not sim.has(n.parent):
			n.pos = n.rest                        # ground point is anchored
			n.anchor = n.rest
			n.theta_world = 0.0
			n.grow = 1.0
			continue

		var p: Dictionary = sim[n.parent]

		# 1. Growth. A side branch waits until the parent branch has actually
		#    grown up to its attachment point.
		if n.grow < 1.0 and p.grow >= maxf(GROW_GATE, n.att):
			n.grow = minf(1.0,
					n.grow + delta * GROW_SPEED / maxf(n.rest_len, 1.0))

		# 2. Attachment point on the parent branch
		n.anchor = p.anchor.lerp(p.pos, n.att)

		# 3. Angle. The torque is the transverse component of the forces
		#    relative to the branch direction: a vertical branch doesn't sag
		#    under gravity, a horizontal one sags maximally.
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
				n.omega = 0.0                     # don't stick at the limit

		# 4. Position — direction from the layout, length from the growth
		n.theta_world = p.theta_world + n.theta
		n.pos = n.anchor + n.local_rest.rotated(n.theta_world) * n.grow


# Approaches a vector toward its target by interpolating angle and length
# SEPARATELY — for a rotation of 40°, component-wise interpolation would
# shorten the vector by around 6 % along the way.
func _approach(cur: Vector2, target: Vector2, k: float) -> Vector2:
	var tl := target.length()
	var cl := cur.length()
	if tl < 0.001 and cl < 0.001:
		return target
	var ta := target.angle() if tl > 0.001 else cur.angle()
	var ca := cur.angle() if cl > 0.001 else ta
	return Vector2.from_angle(lerp_angle(ca, ta, k)) * lerpf(cl, tl, k)


# Spatially coherent wind field: neighboring branches see similar forces,
# gusts travel from left to right across the image, and a separate,
# much slower curve makes the wind swell and subside.
func _wind(p: Vector2, t: float) -> Vector2:
	var n := _noise.get_noise_3d(p.x * 0.006 - t * 0.5, p.y * 0.006, t * 0.4)
	var gust := 0.5 + 0.5 * _noise.get_noise_2d(t * 0.15, 500.0)
	return WIND_DIR * n * WIND_STRENGTH * gust
