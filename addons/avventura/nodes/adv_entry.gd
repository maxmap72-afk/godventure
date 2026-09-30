@tool
@icon("res://addons/avventura/icons/entry.svg")
class_name AdvEntry
extends Marker2D
## Entry point of a room: where the player appears with `goto ROOM at NAME`.
## Name it like another room to use it automatically when coming from that room.
## A plain Marker2D works too; this node also sets the facing direction.

@export_enum("auto", "left", "right", "up", "down") var face := "auto"
