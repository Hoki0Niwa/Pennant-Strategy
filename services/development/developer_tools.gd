extends RefCounted
class_name PSDeveloperTools

# 開発者向け UI の表示スイッチ。
# デバッグ実行かつ ProjectSettings が有効な場合だけ表示し、セーブデータには混ぜない。
const SETTING_KEY: String = "pennant_strategy/development/show_tools"


# true のときだけテストモードや調査用画面への導線を表示する。
static func enabled() -> bool:
	return OS.is_debug_build() and bool(ProjectSettings.get_setting(SETTING_KEY, false))
