extends Node
## Main scene of an Avventura game: it only boots the engine.
## You can use your own main scene (a splash screen...) as long as it calls Adv.boot(self).


func _ready() -> void:
	Adv.boot(self)
