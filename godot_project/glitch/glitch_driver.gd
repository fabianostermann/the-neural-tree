# glitch_driver.gd — hängt am ColorRect mit dem Glitch-Material
#
# Koppelt den Glitch an echte Strukturänderungen: bei jedem NEUEN Snapshot
# aus Python springt glitch_amount auf PULSE und klingt exponentiell ab.
#
# Wichtig ist die rev-Prüfung: TcpServer feuert tree_updated auch bei den
# Keepalive-Paketen, die Python im Sekundentakt schickt. Ohne den Vergleich
# würde das Bild jede Sekunde zucken, auch wenn sich nichts geändert hat.
#
# Solange dieses Skript aktiv ist, kann auto_glitch im Shader aus bleiben —
# beide addieren sich sonst.

extends ColorRect

@export var pulse := 1.0        # Höhe des Ausschlags pro Update
@export var decay := 4.0        # Abklingen, größer = kürzer
@export var disable_auto := true

var _g := 0.0
var _last_rev := -1
var _mat: ShaderMaterial


func _ready() -> void:
	_mat = material as ShaderMaterial
	if _mat == null:
		push_error("glitch_driver: kein ShaderMaterial am ColorRect")
		set_process(false)
		return
	if disable_auto:
		_mat.set_shader_parameter("auto_glitch", false)
	TcpServer.tree_updated.connect(_on_tree_updated)


func _on_tree_updated(rev: int) -> void:
	if rev == _last_rev:
		return                  # Keepalive, keine echte Änderung
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
