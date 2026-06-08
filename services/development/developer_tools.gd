extends RefCounted
class_name PSDeveloperTools

const SETTING_KEY: String = "pennant_strategy/development/show_tools"


static func enabled() -> bool:
	return bool(ProjectSettings.get_setting(SETTING_KEY, false))
