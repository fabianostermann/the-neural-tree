# renderer.gd — attached to the node "Renderer" (type: Node2D)
#
# Reads Simulation.sim exclusively and draws from it.
#
# Both shapes share the same centerline: a quadratic Bezier from the branch
# foot to the node position, whose control point lies above the chord. The
# more horizontal, the stronger the upward curvature.
#
#   Branches — width profile tapers linearly from foot to tip.
#   Leaves (nodes without children) — width profile is a leaf shape:
#     short stalk, then a wide blade peaking at ~36 % and a tapering
#     tip. The size hangs on rest_len and is therefore the same
#     everywhere, independent of the depth in the tree.
#
# BRANCH FOOT: the simulation computes the attachment point on the CHORD of
# the parent branch, but the parent branch is drawn as a Bezier. That's why
# the renderer determines the foot point here once more itself — this time on
# the actual curve, so that every branch sits exactly on the parent branch
# instead of beside it. The difference is a few pixels and only affects
# the drawing point, not the physics.

extends Node2D

# --- Tuning knobs ----------------------------------------------------------
@export var BOTTOM_MARGIN := 60.0        ## distance of the trunk foot from the bottom edge
@export var FIT_MARGIN := 60.0           ## margin for automatic fitting
@export var FIT_SMOOTH := 0.2            ## inertia of the zoom adjustment
@export var FIT_MIN := 0.1              ## smallest allowed auto scale
@export var FIT_MAX := 2.0               ## largest allowed auto scale (>1 enlarges!)
@export var ZOOM := 1.0                  ## manual multiplier on top of the auto fit
@export var FIT_MIN_EXTENT := 60.0       ## below this size, don't fit yet (avoids startup blow-up)

@export var BEND := -0.5                 ## curvature toward the sun
@export var SEGMENTS := 20               ## support points per branch
@export var LEAF_SEGMENTS := 30         ## leaves need a finer contour

@export var WIDTH_K := 1.0               ## branch thickness (px) = K * thickness^EXP
@export var WIDTH_EXP := 1.0            ## 1.0 = proportional to the Python thickness
@export var WIDTH_MIN := 2.0
@export var WIDTH_MAX := 10000.0
@export var BASE_BLEND := 0.5           ## how strongly the branch foot matches the parent branch

@export var LEAF_WIDTH := 0.55           ## leaf width relative to leaf length
@export var LEAF_STALK := 0.08          ## share of the length that stays stalk
@export var LEAF_STALK_W := 1.8          ## stalk thickness
@export var LEAF_PROFILE_A := 0.45       ## leaf shape: t^A * (1-t)^B ...
@export var LEAF_PROFILE_B := 0.80
@export var LEAF_PROFILE_NORM := 2.26318 ## ... normalized to maximum 1
@export var LEAF_HUE_JITTER := 0.15      ## color scatter per leaf
@export var MIDRIB := true               ## draw leaf vein

#@export var COLOR_TRUNK := Color(0.267, 0.198, 0.163, 1.0)
#@export var COLOR_BRANCH_TIP := Color(0.46, 0.38, 0.28)
#@export var COLOR_LEAF := Color(0.48, 0.76, 0.38)
@export var COLOR_TRUNK := Color(0.149, 0.189, 0.367, 1.0)
@export var COLOR_BRANCH_TIP := Color(0.675, 0.637, 0.743, 1.0)
@export var COLOR_LEAF := Color(0.449, 0.629, 0.826, 1.0)

@export var GLOW := 1.5
# ---------------------------------------------------------------------------

var _fit := 1.0

@onready var _sim: Node = get_node("../Simulation")


func _ready() -> void:
	_reposition()
	get_viewport().size_changed.connect(_reposition)


# Anchor the layout origin (trunk foot) at the bottom center of the viewport.
func _reposition() -> void:
	var vp := get_viewport_rect().size
	position = Vector2(vp.x * 0.5, vp.y - BOTTOM_MARGIN)


func _process(delta: float) -> void:
	_update_fit(delta)
	queue_redraw()


# The tree changes its size during the performance — here it is gently
# scaled so that it FILLS the frame. Scaling happens around the trunk foot,
# which thereby stays in place.
#
# Note: the scale is allowed to exceed 1.0. The layout works in its own
# units (trunk ~190 px), which has nothing to do with the screen size — so
# a small tree has to be enlarged, not just shrunk when it gets too big.
func _update_fit(delta: float) -> void:
	var sim: Dictionary = _sim.sim
	if sim.is_empty():
		return

	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var half_w := 0.0
	for id in sim:
		var p: Vector2 = sim[id].pos
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		# Branch widths count too, otherwise thick branches get clipped
		half_w = maxf(half_w, _width(sim[id].thick) * 0.5)

	var vp := get_viewport_rect().size
	var avail_w := maxf(vp.x - FIT_MARGIN * 2.0, 1.0)
	var avail_h := maxf(vp.y - BOTTOM_MARGIN - FIT_MARGIN, 1.0)

	# Width symmetrical around the trunk, height only upward
	var need_w := maxf(absf(lo.x), absf(hi.x)) * 2.0 + half_w * 2.0
	var need_h := absf(minf(lo.y, 0.0)) + half_w

	# While the trunk is still sprouting, the extent is near zero and any
	# fit would zoom in absurdly far. Wait until there is something to see.
	if need_w < FIT_MIN_EXTENT and need_h < FIT_MIN_EXTENT:
		return

	# Start from the upper bound and let each axis pull it down — that is
	# what allows enlarging, unlike starting from 1.0.
	var target := FIT_MAX
	if need_w > 1.0:
		target = minf(target, avail_w / need_w)
	if need_h > 1.0:
		target = minf(target, avail_h / need_h)
	target = clampf(target * ZOOM, FIT_MIN, FIT_MAX)

	_fit = lerpf(_fit, target, 1.0 - exp(-FIT_SMOOTH * delta))
	scale = Vector2(_fit, _fit)


func _draw() -> void:
	var sim: Dictionary = _sim.sim

	if sim.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(-400.0, -250.0),
				"THE NEURAL TREE", 0, -1, 100,
				Color(1, 1, 1, 0.4))
		return

	var max_d := 1.0
	for id in sim:
		max_d = maxf(max_d, float(sim[id].depth))

	# Branch feet on the drawn curve — in a single pass, because
	# order delivers parents before children and the foot of a branch lies on
	# the curve of the parent branch, which in turn begins at its foot.
	var base: Dictionary = {}
	for id in _sim.order:
		if not sim.has(id):
			continue
		var n: Dictionary = sim[id]
		if n.parent == "" or not base.has(n.parent):
			base[id] = n.pos          # ground point: it is its own foot
			continue
		var p: Dictionary = sim[n.parent]
		base[id] = _curve_point(base[n.parent], p.pos, n.att)

	# First the wood (order runs from inside out: thick branches first),
	# then the leaves, so that they lie on top
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


# Returns the node if it has a drawable edge, otherwise an
# empty dictionary.
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
	col *= GLOW
	col.a = 1.0

	draw_colored_polygon(_shape(a, n.pos, SEGMENTS,
			func(t: float) -> float: return lerpf(w_base, w_tip, t)), col)


func _draw_leaf(id: String, a: Vector2, n: Dictionary) -> void:
	var b: Vector2 = n.pos
	# Size from the rest length, not from the current distance: this keeps
	# leaves the same size everywhere and stops them jittering in width.
	var blade: float = float(n.rest_len) * LEAF_WIDTH * n.grow

	var profile := func(t: float) -> float:
		# stalk that tapers out toward the blade ...
		var stalk: float = LEAF_STALK_W * maxf(0.0, 1.0 - t / LEAF_STALK)
		# ... and the blade itself
		var u: float = clampf((t - LEAF_STALK) / (1.0 - LEAF_STALK), 0.0, 1.0)
		var w: float = blade * LEAF_PROFILE_NORM \
				* pow(u, LEAF_PROFILE_A) * pow(1.0 - u, LEAF_PROFILE_B)
		return maxf(maxf(stalk, w), 0.6)

	# Deterministic color scatter: the same leaf stays true to itself
	var j := (float(absi(hash(id)) % 1000) / 1000.0 - 0.5) * 2.0
	var col := COLOR_LEAF
	col.h = fposmod(col.h + j * LEAF_HUE_JITTER, 1.0)
	col.v = clampf(col.v + j * 0.10, 0.0, 1.0)
	
	col *= GLOW
	col.a = 1.0

	draw_colored_polygon(_shape(a, b, LEAF_SEGMENTS, profile), col)

	if MIDRIB:
		draw_polyline(_centerline(a, b, LEAF_SEGMENTS),
				col.darkened(0.05), maxf(blade * 0.06, 0.7), true)


# Maps the Python thickness [2, inf] onto a pixel width.
func _width(thick: float) -> float:
	return clampf(WIDTH_K * pow(maxf(thick, 2.0), WIDTH_EXP),
			WIDTH_MIN, WIDTH_MAX)


# Control point of the shared centerline: above the chord, with
# the strongest curvature on horizontal and none on vertical branches.
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


# Builds a polygon around the centerline; width_at(t) supplies the width.
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

	# Closed polygon outline: one side out, the other back
	var poly := left
	for i in range(right.size() - 1, -1, -1):
		poly.append(right[i])
	return poly
