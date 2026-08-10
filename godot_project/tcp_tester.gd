extends Node

func _ready() -> void:
	TcpServer.tree_updated.connect(_on_tree_updated)

func _on_tree_updated(rev: int) -> void:
	print("Neuer Baum, rev %d, %d Knoten" % [rev, TcpServer.nodes.size()])
	for root in TcpServer.roots:
		_walk(root, 0)

func _walk(id: String, depth: int) -> void:
	print("  ".repeat(depth), id)
	for child in TcpServer.get_children_ids(id):
		_walk(child, depth + 1)
