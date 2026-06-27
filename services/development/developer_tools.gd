extends RefCounted
class_name PSDeveloperTools

# 開発者向け UI の表示スイッチ。
# project.godot の ProjectSettings 値だけを見て、セーブデータには混ぜない。
const SETTING_KEY: String = "pennant_strategy/development/show_tools"


# true のときだけテストモードや調査用画面への導線を表示する。
static func enabled() -> bool:
	return bool(ProjectSettings.get_setting(SETTING_KEY, false))
