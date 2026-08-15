# glitch_driver.gd — attached to the ColorRect with the glitch material
#
# Couples the glitch to real structural changes: on every NEW snapshot
# from Python, glitch_amount jumps to PULSE and decays exponentially.
#
# The rev check matters: TcpServer also fires tree_updated on the
# keepalive packets that Python sends every second. Without the comparison
# the image would twitch every second, even if nothing had changed.
#
# As long as this script is active, auto_glitch in the shader can stay off —
# otherwise both add up.

extends ColorRect

@export var pulse := 1.0        # height of the spike per update
@export var decay := 4.0        # decay, larger = shorter

@export var disable_auto := true

var _g := 0.0
var _last_rev := -1
var _mat: ShaderMaterial


func _ready() -> void:
	_mat = material as ShaderMaterial
	if _mat == null:
		push_error("glitch_driver: no ShaderMaterial on the ColorRect")
		set_process(false)
		return
	if disable_auto:
		_mat.set_shader_parameter("auto_glitch", false)
	TcpServer.tree_updated.connect(_on_tree_updated)


func _on_tree_updated(rev: int) -> void:
	if rev == _last_rev:
		return                  # keepalive, no real change
	_last_rev = rev
	_g = pulse


func _process(delta: float) -> void:
	if _g <= 0.001:
		if _g != 0.0:
			_g = 0.0
			_mat.set_shader_parameter("glitch_amount", 0.0)
		return
	_g *= exp(-decay * delta)
	_mat.set_shader_parameter("glitch_amount", _g)
