extends SceneTree
func _init():
	var paths: Array = []
	_collect("res://", paths)
	for p in paths:
		ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)
	print("SCANNED ", paths.size(), " scripts")
	quit()

func _collect(dir_path: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f == "." or f == "..":
			f = d.get_next()
			continue
		var full := dir_path.path_join(f)
		if d.current_is_dir():
			if f != "addons" and f != ".godot":
				_collect(full, out)
		elif f.ends_with(".gd"):
			out.append(full)
		f = d.get_next()
	d.list_dir_end()
