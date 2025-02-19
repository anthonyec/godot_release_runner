class_name UtilsFileSystem
extends Node

static func scan_directory(path: String, include_directories: bool = false) -> Array[String]:
	var list: Array[String] = []

	if DirAccess.dir_exists_absolute(path):
		var directory: = DirAccess.open(path)
		directory.list_dir_begin()

		var filename: String = directory.get_next()

		while filename != "":
			var file_path: String = path.path_join(filename)

			if directory.current_is_dir():
				if include_directories:
					list.append(file_path)

				list.append_array(scan_directory(file_path, include_directories))
			else:
				list.append(file_path)

			filename = directory.get_next()

	return list
