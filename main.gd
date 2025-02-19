extends Control

class RequestResult:
	var result: int
	var response_code: int
	var body: PackedByteArray

	func to_dictionary() -> Dictionary:
		var json: Variant = JSON.parse_string(body.get_string_from_utf8())
		if not json is Dictionary: return {}

		return json

	func to_array() -> Array:
		var json: Variant = JSON.parse_string(body.get_string_from_utf8())
		if not json is Array: return []

		return json

const CHECK_INTERVAL: float = 60
const RELEASES_PATH: String = "user://releases"

@onready var http: HTTPRequest = $HTTPRequest
@onready var timer: Timer = $Timer
@onready var username_line_edit: LineEdit = %UsernameLineEdit
@onready var repo_line_edit: LineEdit = %RepoLineEdit
@onready var token_line_edit: LineEdit = %TokenLineEdit
@onready var log_text_edit: TextEdit = %LogTextEdit
@onready var release_option_button: OptionButton = %ReleaseOptionButton
@onready var filter_line_edit: LineEdit = %FilterLineEdit
@onready var start_stop_button: Button = %StartStopButton
@onready var autostart_check_box: CheckBox = %AutostartCheckBox

var running_pid: int

func _ready() -> void:
	get_viewport().get_window().title = "Release Runner"

	timer.wait_time = CHECK_INTERVAL
	timer.timeout.connect(_on_timer_timeout)

	username_line_edit.text = get_value_string("username")
	username_line_edit.text_changed.connect(_on_username_line_edit_text_changed)

	repo_line_edit.text = get_value_string("repo")
	repo_line_edit.text_changed.connect(_on_repo_line_edit_text_changed)

	token_line_edit.text = get_value_string("token")
	token_line_edit.text_changed.connect(_on_token_line_edit_text_changed)

	release_option_button.item_selected.connect(_on_release_option_button_item_selected)
	
	filter_line_edit.text = get_value_string("filter")
	filter_line_edit.text_changed.connect(_on_filter_line_edit_text_changed)

	autostart_check_box.button_pressed = get_value_bool("autostart")
	autostart_check_box.pressed.connect(_on_autostart_check_box_button_up)

	start_stop_button.pressed.connect(_on_start_stop_button_pressed)

	await update_release_tag_names()

	if get_value_bool("autostart"):
		start()

	if username_line_edit.text.is_empty():
		username_line_edit.grab_focus()
	elif repo_line_edit.text.is_empty():
		repo_line_edit.grab_focus()
	elif token_line_edit.text.is_empty():
		token_line_edit.grab_focus()
	else:
		start_stop_button.grab_focus()

func retry_after_timeout(status: String = "") -> void:
	if not status.is_empty():
		log_message(status)

	log_message("Waiting %s seconds to check again" % CHECK_INTERVAL)

	timer.paused = false
	timer.start()

	update_release_tag_names()

func start() -> void:
	if username_line_edit.text.is_empty() or repo_line_edit.text.is_empty() or token_line_edit.text.is_empty():
		return log_message("Missing parameters")

	start_stop_button.text = "Stop"

	username_line_edit.editable = false
	repo_line_edit.editable = false
	token_line_edit.editable = false
	filter_line_edit.editable = false
	autostart_check_box.disabled = true

	ensure_latest_downloaded_and_running(get_url_from_inputs(), token_line_edit.text, get_filter_from_inputs())

func stop() -> void:
	timer.stop()

	start_stop_button.text = "Start"

	username_line_edit.editable = true
	repo_line_edit.editable = true
	token_line_edit.editable = true
	filter_line_edit.editable = true
	autostart_check_box.disabled = false

	if running_pid != 0 and OS.is_process_running(running_pid):
		OS.kill(running_pid)

func get_url_from_inputs() -> String:
	var selected_tag_name: String = release_option_button.get_item_text(release_option_button.selected)

	if selected_tag_name != "Latest":
		return "https://api.github.com/repos/%s/%s/releases/tags/%s" % [username_line_edit.text, repo_line_edit.text, selected_tag_name]

	return "https://api.github.com/repos/%s/%s/releases/latest" % [username_line_edit.text, repo_line_edit.text]
	
func get_filter_from_inputs() -> PackedStringArray:
	var filter: PackedStringArray = filter_line_edit.text.split(",", false)
	
	for index in filter.size():
		var string: String = filter[index]
		filter[index] = string.strip_edges()
		
	return filter

func update_release_tag_names() -> void:
	var releases_url: String = "https://api.github.com/repos/%s/%s/releases" % [username_line_edit.text, repo_line_edit.text]

	var release_result: RequestResult = await request(releases_url, ["Accept: application/vnd.github+json", "Authorization: Bearer %s" % get_value_string("token")])
	if release_result.result != 0: return
	if release_result.response_code != 200: return

	var selected_tag_name: String = get_value_string("tag")

	release_option_button.clear()
	release_option_button.add_item("Latest")

	for release: Dictionary in release_result.to_array():
		var tag_name: String = release.get("tag_name", "")
		if tag_name.is_empty(): continue

		release_option_button.add_item(tag_name)

	for index in release_option_button.item_count:
		var tag_name: String = release_option_button.get_item_text(index)

		if tag_name == selected_tag_name:
			release_option_button.selected = index

func has_downloaded_release(id: int) -> bool:
	var directory: DirAccess = DirAccess.open(RELEASES_PATH)
	if not directory: return false

	var release_directory_exists: bool = directory.dir_exists(str(id))
	if not release_directory_exists: return false

	return DirAccess.get_files_at(RELEASES_PATH.path_join(str(id))).size() > 0

func extract_zip(source_path: String, output_path: String, depth: int = 0) -> String:
	var os_name: String = OS.get_name().to_lower()

	if os_name == "macos":
		var output: Array = []
		var result: int = OS.execute("tar", ["-xzf", ProjectSettings.globalize_path(source_path), "-C", ProjectSettings.globalize_path(output_path)], output, true)
		if result != 0: return "Failed to extract on %s with exit code %s:\n%s" % [os_name, result, "".join(PackedStringArray(output))]

		if depth == 0:
			var directory: DirAccess = DirAccess.open(output_path)
			if not directory: return "Failed to open output directory"

			for file in directory.get_files():
				if file.ends_with(".zip"):
					extract_zip("%s/%s" % [output_path, file], output_path, depth + 1)

	if os_name == "windows":
		var windows_source_path: String = ProjectSettings.globalize_path(source_path).replace("/", "\\")
		var windows_output_path: String = ProjectSettings.globalize_path(output_path).replace("/", "\\")

		var output: Array = []
		var result: int = OS.execute("tar", ["-xzf", windows_source_path, "-C", windows_output_path], output, true)
		if result != 0: return "Failed to extract on %s with exit code %s:\n%s" % [os_name, result, "".join(PackedStringArray(output))]

	return ""
	
func is_filename_allowed(filename: String, filter: PackedStringArray) -> bool:
	for string in filter:
		if not filename.contains(string):
			return false
			
	return true

func download_and_extract_latest_release(latest_release_response: Dictionary, token: String, filter: PackedStringArray = []) -> String:
	var release_id: int = latest_release_response.get("id", -1) as int
	if release_id == -1: return "Could not find `id` in release info response: %s" % str(latest_release_response)

	var assets: Array = latest_release_response.get("assets", []) as Array
	if assets.is_empty(): return "No assets array"

	var user_directory: DirAccess = DirAccess.open("user://")
	if not user_directory: return "Failed to open downloads directory"

	user_directory.make_dir_recursive(RELEASES_PATH.path_join(str(release_id)))

	for asset: Dictionary in assets:
		var asset_url: String = asset.get("url", "") as String
		if asset_url.is_empty(): return "No download file URL"

		var asset_name: String = asset.get("name", "") as String
		if not asset_name.ends_with(".zip"): continue
		
		if not is_filename_allowed(asset_name, filter):
			continue
		
		log_message("Downloading %s" % asset_name)
		var download_result: RequestResult = await request(asset_url, ["Accept: application/octet-stream", "Authorization: Bearer %s" % token])
		if download_result.response_code != 200: return "Failed to download with response code: %s" % download_result.response_code

		var zip_file_path: String = RELEASES_PATH.path_join(str(release_id)).path_join(asset_name.get_basename()) + ".zip"
		var download_zip_file: FileAccess = FileAccess.open(zip_file_path, FileAccess.WRITE)
		download_zip_file.store_buffer(download_result.body)
		download_zip_file.close()

		var extraction_path: String = RELEASES_PATH.path_join(str(release_id)).path_join(asset_name.get_basename())
		user_directory.make_dir_recursive(extraction_path)

		var status: String = extract_zip(zip_file_path, extraction_path)
		if not status.is_empty(): return status

	return ""

func run_downloaded_release(release_id: int) -> String:
	var release_path: String = RELEASES_PATH.path_join(str(release_id))
	var os_name: String = OS.get_name().to_lower()

	var files: PackedStringArray = UtilsFileSystem.scan_directory(release_path, true)
	var executable_file_path: String = ""

	for file in files:
		if os_name == "windows" and file.ends_with(".exe"):
			executable_file_path = file
			break

		if os_name == "macos" and file.ends_with(".app"):
			executable_file_path = file
			break

		if os_name == "linux" and file.ends_with(".x86_64"):
			executable_file_path = file
			break

	if executable_file_path.is_empty():
		return "Failed to find executable for %s" % os_name

	running_pid = OS.create_process(ProjectSettings.globalize_path(executable_file_path), [], false)
	return ""

func ensure_latest_downloaded_and_running(release_url: String, token: String, filter: PackedStringArray = []) -> void:
	log_message("Getting latest release info")
	var latest_release_result: RequestResult = await request(release_url, [
		"Accept: application/vnd.github+json", 
		"Authorization: Bearer %s" % token
	])
	if latest_release_result.result != 0: return retry_after_timeout("Failed request to get release info with result code: %s" % latest_release_result.result)
	if latest_release_result.response_code != 200: return retry_after_timeout("Failed request to get release info with status code: %s" % latest_release_result.response_code)

	var latest_release_response: Dictionary = latest_release_result.to_dictionary()

	var latest_release_id: int = latest_release_response.get("id", -1)
	if latest_release_id == -1: return retry_after_timeout("Could not find `id` in release info response: %s" % str(latest_release_response))

	var latest_release_name: String = latest_release_response.get("name", "<No Title>")
	var latest_release_created_at: String = latest_release_response.get("created_at", "<No Date>")
	log_message("The latest release is %s (%s) created at %s." % [latest_release_id, latest_release_name, latest_release_created_at])

	log_message("Checking if release %s has already been downloaded" % str(latest_release_id))
	var is_new_release: int = not has_downloaded_release(latest_release_id)

	if is_new_release:
		log_message("It hasn't, downloading and extracting it...")
		var status: String = await download_and_extract_latest_release(latest_release_response, token, filter)
		if not status.is_empty(): return retry_after_timeout("Failed to download release: %s" % status)
	else:
		log_message("Release %s has already been downloaded" % str(latest_release_id))

	if is_new_release and OS.is_process_running(running_pid):
		log_message("Killing running app with PID: %s" % str(running_pid))
		OS.kill(running_pid)
		running_pid = 0

	if not OS.is_process_running(running_pid) or running_pid == 0:
		log_message("Running release")
		var status: String = run_downloaded_release(latest_release_id)

		if not status.is_empty():
			OS.move_to_trash(ProjectSettings.globalize_path(RELEASES_PATH.path_join(str(latest_release_id))))

			return retry_after_timeout("Failed to run downloaded release: %s" % status)
	else:
		log_message("Release is already running")

	retry_after_timeout()

func request(url: String, headers: PackedStringArray = []) -> RequestResult:
	var request_result: RequestResult = RequestResult.new()

	var _on_http_request_completed: Callable = func(result: int, response_code: int, response_headers: PackedStringArray, body: PackedByteArray) -> void:
		request_result.result = result
		request_result.response_code = response_code
		request_result.body = body

	http.cancel_request()
	var error: Error = http.request(url, headers)

	if error != OK:
			request_result.result = error
			request_result.response_code = -1
			return request_result

	http.request_completed.connect(_on_http_request_completed)
	await http.request_completed

	return request_result

func log_message(message: String) -> void:
	var time: String = Time.get_datetime_string_from_system()

	print(time, ": ", message)
	log_text_edit.text += "[%s] %s \n" % [time, message]
	log_text_edit.scroll_vertical = log_text_edit.text.length()

func get_value_variant(key: String) -> Variant:
	var config: ConfigFile = ConfigFile.new()
	config.load("user://config.cfg")

	if not config.has_section_key("settings", key):
			return null

	return config.get_value("settings", key, null)

func set_value_variant(key: String, value: Variant) -> void:
	var config: ConfigFile = ConfigFile.new()
	config.load("user://config.cfg")

	config.set_value("settings", key, value)
	config.save("user://config.cfg")

func get_value_string(key: String) -> String:
	var value: Variant = get_value_variant(key)

	if value is String:
			return value

	return ""

func set_value_string(key: String, value: String) -> void:
	set_value_variant(key, value)

func get_value_bool(key: String) -> bool:
	var value: Variant = get_value_variant(key)

	if value is bool:
			return value

	return false

func set_value_bool(key: String, value: bool) -> void:
	set_value_variant(key, value)

func _on_start_stop_button_pressed() -> void:
	if timer.is_stopped():
			log_message("Started")
			return start()

	log_message("Stopped")
	stop()

func _on_username_line_edit_text_changed(new_text: String) -> void:
	set_value_string("username", new_text)

func _on_repo_line_edit_text_changed(new_text: String) -> void:
	set_value_string("repo", new_text)

func _on_token_line_edit_text_changed(new_text: String) -> void:
	set_value_string("token", new_text)

func _on_timer_timeout() -> void:
	ensure_latest_downloaded_and_running(get_url_from_inputs(), token_line_edit.text, get_filter_from_inputs())

func _on_autostart_check_box_button_up() -> void:
	set_value_bool("autostart", autostart_check_box.button_pressed)

func _on_release_option_button_item_selected(index: int) -> void:
	set_value_string("tag", release_option_button.get_item_text(index))

func _on_filter_line_edit_text_changed(new_text: String) -> void:
	set_value_string("filter", new_text)
