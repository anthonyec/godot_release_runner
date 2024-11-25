extends Control

class RequestResult:
	var result: int
	var response_code: int
	var body: PackedByteArray
	
	func to_dictionary() -> Dictionary:
		var json: Variant = JSON.parse_string(body.get_string_from_utf8())
		if not json is Dictionary: return {}
		
		return json

const CHECK_INTERVAL: float = 60 # seconds.

@onready var http: HTTPRequest = $HTTPRequest
@onready var timer: Timer = $Timer
@onready var username_line_edit: LineEdit = %UsernameLineEdit
@onready var repo_line_edit: LineEdit = %RepoLineEdit
@onready var token_line_edit: LineEdit = %TokenLineEdit
@onready var log_text_edit: TextEdit = %LogTextEdit
@onready var start_stop_button: Button = %StartStopButton

var running_pid: int

func _ready() -> void:
	get_viewport().get_window().title = "Build Runner"
	
	timer.wait_time = CHECK_INTERVAL
	timer.timeout.connect(ensure_latest_downloaded_and_running)
	
	username_line_edit.text = get_value("username")
	username_line_edit.text_changed.connect(_on_username_line_edit_text_changed)
	
	repo_line_edit.text = get_value("repo")
	repo_line_edit.text_changed.connect(_on_repo_line_edit_text_changed)
	
	token_line_edit.text = get_value("token")
	token_line_edit.text_changed.connect(_on_token_line_edit_text_changed)
	
	start_stop_button.pressed.connect(_on_start_stop_button_pressed)
	
func retry_after_timeout(status: String = "") -> void:
	if not status.is_empty():
		log_message(status)
	
	log_message("Waiting %s seconds to check again" % CHECK_INTERVAL)
	timer.start()
	start_stop_button.text = "Stop"
	
func start() -> void:
	if username_line_edit.text.is_empty() or repo_line_edit.text.is_empty() or token_line_edit.text.is_empty(): 
		return log_message("Missing parameters")
		
	var url: String = "https://api.github.com/repos/%s/%s/releases/latest" % [username_line_edit.text, repo_line_edit.text]
	
	log_message("Started")
	ensure_latest_downloaded_and_running(url, token_line_edit.text)

func stop() -> void:
	log_message("Stopped")
	timer.stop()
	start_stop_button.text = "Start"

	if running_pid != 0 and OS.is_process_running(running_pid):
		OS.kill(running_pid)
	
func has_downloaded_release(id: int) -> bool:
	var directory: DirAccess = DirAccess.open("user://")
	return directory.dir_exists(str(id))

func download_and_extract_latest_release(latest_release_response: Dictionary) -> String:
	var id: int = latest_release_response.get("id", -1) as int
	if id == -1: return "Could not find ID in latest release: %s" % str(latest_release_response)
	
	var assets: Array = latest_release_response.get("assets", []) as Array
	if assets.is_empty(): return "No assets array"
	
	for asset: Dictionary in assets:
		var download_url: String = asset.get("browser_download_url", "") as String
		if download_url.is_empty(): return "No download file URL"
		
		var content_type: String = asset.get("content_type", "") as String
		if content_type != "application/zip": continue
		
		var download_result: RequestResult = await request(download_url)
		if download_result.result != 0: return "Failed to download with result code: %s" % download_result.result
		
		var zip_file_path: String = "user://%s.zip" % str(id)
		var download_zip_file: FileAccess = FileAccess.open(zip_file_path, FileAccess.WRITE)
		download_zip_file.store_buffer(download_result.body)
		download_zip_file.close()
		
		var directory: DirAccess = DirAccess.open("user://")
		directory.make_dir("user://%s" % str(id))
		
		var zip_reader: ZIPReader = ZIPReader.new()
		var zip_error: Error = zip_reader.open(zip_file_path)
		if zip_error != OK: return "Failed to open ZIP file %s: %s" % [zip_file_path, zip_error]
		
		var zip_files: PackedStringArray = zip_reader.get_files()
		
		for file_path in zip_files:
			directory.make_dir_recursive("user://%s/%s" % [str(id), file_path.get_base_dir()])
			
			var file_data: PackedByteArray = zip_reader.read_file(file_path)
			if file_data.is_empty(): continue # Empty files are directories.
			
			var file: FileAccess = FileAccess.open("user://%s/%s" % [str(id), file_path], FileAccess.WRITE)
			if not file: return "Failed to write file user://%s/%s" % [str(id), file_path]
			
			file.store_buffer(file_data)
			file.close()
	
	return ""

func run_downloaded_release(release_id: int) -> String:
	var directory: DirAccess = DirAccess.open("user://%s" % str(release_id))
	if not directory: return "Failed to open release directory"
	
	var files: PackedStringArray = directory.get_files()
	
	var executable_file_path: String = ""
	
	for file in files:
		var os_name: String = OS.get_name().to_lower()
		
		if os_name == "windows" and file.ends_with(".exe"):
			executable_file_path = file
			break
			
		if os_name == "macos" and file.ends_with(".app"):
			executable_file_path = file
			break
		
	if executable_file_path.is_empty():
		return "Failed to find executable"
	
	running_pid = OS.create_process(executable_file_path, [])
	return ""

func ensure_latest_downloaded_and_running(release_url: String, token: String) -> void:
	log_message("Downloading latest release JSON")
	var latest_release_result: RequestResult = await request(release_url, ["Accept: application/vnd.github+json", "Authorization: Bearer %s" % token])
	if latest_release_result.result != 0: return retry_after_timeout("Failed latest release request with result code: %s" % latest_release_result.result)
	if latest_release_result.response_code != 200: return retry_after_timeout("Failed latest release request with status code: %s" % latest_release_result.response_code)
	
	var latest_release_response: Dictionary = latest_release_result.to_dictionary()
	
	var latest_release_id: int = latest_release_response.get("id", -1)
	if latest_release_id == -1: return retry_after_timeout("Could not find ID in latest release: %s" % str(latest_release_response))
	
	log_message("Checking if latest release download %s exists" % str(latest_release_id))
	var is_new_release: int = not has_downloaded_release(latest_release_id)
	
	if is_new_release:
		log_message("Downloading and extraxcting new latest release")
		var status: String = await download_and_extract_latest_release(latest_release_response)
		if not status.is_empty(): return retry_after_timeout("Failed to download latest release: %s" % status)
	else:
		log_message("Latest already downloaded")
		
	if is_new_release and OS.is_process_running(running_pid):
		log_message("Killing running app %s" % str(running_pid))
		OS.kill(running_pid)
		running_pid = 0
	
	if not OS.is_process_running(running_pid) or running_pid == 0:
		log_message("Running downloaded release")
		var status: String = run_downloaded_release(latest_release_id)
		if not status.is_empty(): return retry_after_timeout("Failed to run downloaded release: %s" % status)
	else:
		log_message("Release is already running")
	
	retry_after_timeout()

func request(url: String, headers: PackedStringArray = []) -> RequestResult:
	var request_result: RequestResult = RequestResult.new()
	
	var _on_http_request_completed: Callable = func (result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
		request_result.result = result
		request_result.response_code = response_code
		request_result.body = body
	
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
	
func get_values() -> Dictionary:
	var file: FileAccess = FileAccess.open("user://settings.json", FileAccess.READ)
	if not file: return {}
	
	var text: String = file.get_as_text()
	
	var json: Variant = JSON.parse_string("{}" if text.is_empty() else text)
	if not json is Dictionary: return {}
	
	return json as Dictionary

func get_value(key: String) -> String:
	var json: Dictionary = get_values()
	if not json.has(key): return ""
	
	return json[key]
	
func set_value(key: String, value: String) -> void:
	var json: Dictionary = get_values()
	json[key] = value
	
	var file: FileAccess = FileAccess.open("user://settings.json", FileAccess.WRITE)
	
	file.store_string(JSON.stringify(json))
	file.close()

func _on_start_stop_button_pressed() -> void:
	if timer.is_stopped():
		return start()
	
	stop()

func _on_username_line_edit_text_changed(new_text: String) -> void:
	set_value("username", new_text)
	
func _on_repo_line_edit_text_changed(new_text: String) -> void:
	set_value("repo", new_text)
	
func _on_token_line_edit_text_changed(new_text: String) -> void:
	set_value("token", new_text)
