extends Node

## Empfängt Baum-Snapshots aus dem Python-Framework.
## Als Autoload registrieren: Projekt > Projekteinstellungen > Autoload,
## Pfad auf dieses Skript, Name "TcpServer".
## Zugriff von überall: TcpServer.nodes, TcpServer.roots, TcpServer.rev

signal tree_updated(rev: int)
signal peer_changed(connected: bool)

const PORT := 9999
const BIND_ADDRESS := "127.0.0.1"
const MAX_BUFFER := 1 << 20          # 1 MB Notbremse gegen Müll-Daten

# ---------------------------------------------------------------- Zustand

## id -> { "id": String, "parent": String, "children": Array[String],
##          "thickness": float }
## "parent" ist "" bei Wurzelknoten. "thickness" kommt aus Python (>= 2).
var nodes: Dictionary = {}
var roots: Array[String]
var rev: int = -1
var last_update_msec: int = 0
var peer_connected: bool = false

# ---------------------------------------------------------------- Intern

var _server := TCPServer.new()
var _peer: StreamPeerTCP = null
var _buffer := PackedByteArray()


func _ready() -> void:
	var err := _server.listen(PORT, BIND_ADDRESS)
	if err != OK:
		push_error("TcpServer: listen auf %s:%d fehlgeschlagen (%d)" % [BIND_ADDRESS, PORT, err])
	else:
		print("TcpServer: warte auf %s:%d" % [BIND_ADDRESS, PORT])


func _exit_tree() -> void:
	_drop_peer()
	_server.stop()


func _process(_delta: float) -> void:
	_accept()
	_receive()


func _accept() -> void:
	if not _server.is_connection_available():
		return
	# Neue Verbindung ersetzt die alte (z.B. nach Python-Neustart)
	_drop_peer()
	_peer = _server.take_connection()
	_buffer.clear()
	peer_connected = true
	peer_changed.emit(true)
	print("TcpServer: verbunden")


func _drop_peer() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_buffer.clear()
	if peer_connected:
		peer_connected = false
		peer_changed.emit(false)
		print("TcpServer: getrennt")


func _receive() -> void:
	if _peer == null:
		return

	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_drop_peer()
		return

	var avail := _peer.get_available_bytes()
	if avail > 0:
		var res: Array = _peer.get_partial_data(avail)
		if res[0] == OK:
			_buffer.append_array(res[1])

	if _buffer.size() > MAX_BUFFER:
		push_warning("TcpServer: Puffer übergelaufen, verwerfe Verbindung")
		_drop_peer()
		return

	# Alle vollständigen Zeilen durchgehen, nur die letzte verwenden
	var last_line := ""
	var start := 0
	var i := _buffer.find(10, start)          # 10 == '\n'
	while i != -1:
		last_line = _buffer.slice(start, i).get_string_from_utf8()
		start = i + 1
		i = _buffer.find(10, start)

	if start > 0:
		_buffer = _buffer.slice(start)        # angefangene Zeile aufheben

	if last_line.strip_edges() == "":
		return

	var data: Variant = JSON.parse_string(last_line)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("TcpServer: Nachricht nicht lesbar")
		return

	print("Received data:", data)

	_apply(data)


func _apply(data: Dictionary) -> void:
	var incoming_rev := int(data.get("rev", -1))
	var raw: Variant = data.get("nodes", [])
	if not (raw is Array):
		return

	var new_nodes: Dictionary = {}
	var new_roots: Array[String] = []

	for entry in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var nid := _as_id(entry.get("id"))
		if nid == "":
			continue

		var pid := _as_id(entry.get("parent"))

		var kids: Array[String] = []
		var raw_kids: Variant = entry.get("children", [])
		if raw_kids is Array:
			for k in raw_kids:
				var kid := _as_id(k)
				if kid != "":
					kids.append(kid)

		# Thickness aus Python: int in [2, inf]. Fehlt der Wert oder ist er
		# kein Zahlentyp, greift der Mindestwert 2.
		var thick := 2.0
		var raw_thick: Variant = entry.get("thickness", 2.0)
		if typeof(raw_thick) == TYPE_FLOAT or typeof(raw_thick) == TYPE_INT:
			thick = maxf(2.0, float(raw_thick))

		new_nodes[nid] = { "id": nid, "parent": pid, "children": kids,
				"thickness": thick }
		if pid == "":
			new_roots.append(nid)
			
	# Verwaiste Knoten abfangen: Parent zeigt auf eine unbekannte ID
	for nid in new_nodes:
		var pid: String = new_nodes[nid].parent
		if pid != "" and not new_nodes.has(pid):
			push_warning("TcpServer: Knoten %s verweist auf unbekannten Parent %s" % [nid, pid])
			new_nodes[nid].parent = ""
			new_roots.append(nid)

	nodes = new_nodes
	roots = new_roots
	rev = incoming_rev
	last_update_msec = Time.get_ticks_msec()
	tree_updated.emit(rev)


## Akzeptiert String, int oder float und liefert immer einen String zurück.
func _as_id(v: Variant) -> String:
	match typeof(v):
		TYPE_NIL:
			return ""
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v)
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			return "%d" % int(v)
		_:
			return str(v)


# ---------------------------------------------------------------- Zugriff

func has_data() -> bool:
	return not nodes.is_empty()

func get_parent_id(node_id: String) -> String:
	return nodes.get(node_id, {}).get("parent", "")

func get_children_ids(node_id: String) -> Array:
	return nodes.get(node_id, {}).get("children", [])

func get_thickness(node_id: String) -> float:
	return nodes.get(node_id, {}).get("thickness", 2.0)

func get_depth(node_id: String) -> int:
	var d := 0
	var cur := node_id
	while nodes.has(cur):
		var p: String = nodes[cur].parent
		if p == "":
			break
		cur = p
		d += 1
		if d > 1000:            # Schutz gegen Zyklen in fehlerhaften Daten
			break
	return d
