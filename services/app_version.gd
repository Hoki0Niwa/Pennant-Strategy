extends RefCounted

# アプリ版数の唯一の読み出し口。版数の正典は project.godot の SETTING 1箇所で、
# ここも含めどのコードも実値 (文字列) を複製しない。
# 参照元: ダッシュボード左下の表示 / セーブメタ (save_meta.json の app_version)。

const SETTING: String = "application/config/version"
# 設定が読めなかったときだけ出るダミー。実版数を複製すると更新漏れが「それらしい古い版数」
# として静かに表示されるため、異常だと分かる値にしてある。
const FALLBACK: String = "0.0.0-dev"


static func current() -> String:
	return str(ProjectSettings.get_setting(SETTING, FALLBACK))


# UI 表示用の "v1.2.3" 表記。version 省略時は現在の版数。
static func label(version: String = "") -> String:
	return "v%s" % (current() if version.is_empty() else version)
