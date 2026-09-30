extends Node
## GDScript functions callable from AdvScript with `call` (fixture).


func game_helper(n: int) -> void:
	await get_tree().process_frame
	Adv.set_var("helper_result", n * 2)


func double(n: int) -> int:
	return n * 2
