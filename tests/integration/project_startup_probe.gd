extends Node
## Temporary test autoload: observe the configured entry in a fresh game process.


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_check.call_deferred()


func _check() -> void:
	await get_tree().process_frame
	var session: FactorySession = get_tree().current_scene as FactorySession
	if session == null or session.game != null or session.menu == null or not session.menu.visible:
		_fail("The configured entry did not reach the main menu.")
		return
	# Keep the user's real save slot out of this test.
	session.store.directory = ProjectSettings.globalize_path("res://startup_test_saves")
	var new_world: Button = _find_button(session.menu, "新游戏")
	if new_world == null:
		_fail("The New World button is missing.")
		return
	new_world.pressed.emit()
	var name_confirm: Button = _find_button(session.menu, "确认")
	if name_confirm == null:
		_fail("New Game did not open world naming.")
		return
	name_confirm.pressed.emit()
	await get_tree().physics_frame
	await get_tree().physics_frame
	if session.game == null or session.game.player == null or (
		not session.game.player.is_inside_tree() or not session.game.player.camera.is_current()
		or session.menu.visible or get_tree().paused
	):
		_fail("New World did not mount an active first-person world.")
		return
	var escape: InputEventKey = InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.physical_keycode = KEY_ESCAPE
	escape.pressed = true
	session.game.player.handle_input(escape)
	await get_tree().process_frame
	var resume: Button = _find_button(session.menu, "继续  [Esc]")
	if not get_tree().paused or resume == null or session.game.can_process() or (
		session.game.player.controls_enabled()
	):
		_fail("The pause menu did not become active.")
		return
	resume.pressed.emit()
	await get_tree().physics_frame
	if get_tree().paused or session.menu.visible or not session.game.can_process() or (
		not session.game.player.controls_enabled() or not session.game.player.controls_captured()
	):
		_fail("Resume did not return to the world.")
		return
	print("PROJECT_STARTUP_OK")
	get_tree().quit(0)


func _find_button(node: Node, text: String) -> Button:
	var button: Button = node as Button
	if button != null and button.text == text and button.is_visible_in_tree() and not button.disabled:
		return button
	for child: Node in node.get_children():
		var found: Button = _find_button(child, text)
		if found != null:
			return found
	return null


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
