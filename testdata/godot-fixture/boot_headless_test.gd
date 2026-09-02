extends SceneTree


func _init() -> void:
	assert(ProjectSettings.get_setting("application/config/name") == "qgate-fixture")
	quit(0)
