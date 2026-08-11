import json
import socket
import threading
import time
import subprocess

USES = []
REQUIRES = ["NeuralTree"]
PROVIDES = ["Godot Engine"]

HOST = "127.0.0.1"
PORT = 9999
RECONNECT_DELAY = 0.5      # Pause zwischen Verbindungsversuchen
KEEPALIVE = 1.0            # Snapshot spätestens alle n Sekunden erneut senden

_lock = threading.Lock()
_wake = threading.Event()
_stop = threading.Event()
_thread = None

_latest = None             # aktueller Snapshot als bytes
_latest_rev = 0
_last_nodes_json = None    # zum Erkennen unveränderter Bäume


# ---------------------------------------------------------------- Adapter

def _prepare_data(nodes):
    data = []
    for node in nodes:
        data.append({
            "id": str(id(node)),
            "parent": None if node._parent is None else str(id(node._parent)),
            "children": [] if node._children is None else [str(id(c)) for c in node._children],
            "thickness": node.get_out_size()
        })
    return data

# ---------------------------------------------------------------- Sender

def _sender_loop():
    print("Start _sender_loop()")
    sock = None
    sent_rev = -1
    last_send = 0.0

    while not _stop.is_set():
        if sock is None:
            print(f"TCP: Try socket (re)start")
            try:
                sock = socket.create_connection((HOST, PORT), timeout=2.0)
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                sent_rev = -1          # nach Reconnect aktuellen Stand neu senden
            except OSError:
                sock = None
                _stop.wait(RECONNECT_DELAY)
                continue

        with _lock:
            msg, rev = _latest, _latest_rev

        due = rev != sent_rev or (time.monotonic() - last_send) > KEEPALIVE
        
        print(f"TCP: try to send msg: {msg}")
        if msg is not None and due:
            try:
                sock.sendall(msg)
                sent_rev = rev
                last_send = time.monotonic()
            except OSError:
                sock.close()
                sock = None
                continue

        _wake.wait(0.2)
        _wake.clear()

    if sock is not None:
        sock.close()
        
    print("Exit _sender_loop()")


# ---------------------------------------------------------------- Modul

def _init():
    global _thread
    _stop.clear()
    _thread = threading.Thread(target=_sender_loop, name="godot-sender", daemon=True)
    _thread.start()


def _update(bb):
    global _latest, _latest_rev, _last_nodes_json

    try:
        nodes = _prepare_data(bb.NeuralTree.get_all_nodes())
    except Exception as e:
        print("Baum nicht lesbar:", e)
        return

    nodes_json = json.dumps(nodes)#, sort_keys=True)
    if nodes_json == _last_nodes_json: # no changes
        print("No changes.")
        return
    _last_nodes_json = nodes_json

    with _lock:
        _latest_rev += 1
        _latest = json.dumps({"rev": _latest_rev, "nodes": nodes}).encode() + b"\n"

    _wake.set()


def _close():
    _stop.set()
    _wake.set()
    if _thread is not None:
        _thread.join(timeout=2.0)
        
        
