# GdUnit4 への移行後の最初のテスト雛形。
# 旧 run_startup_smoke.gd 相当: 主要スクリプトのロードと autoload 登録を確認する。
# 新しいテストは test/ 配下に *_test.gd を追加するだけで自動検出される(専用 .tscn 不要)。
extends GdUnitTestSuite


func test_core_scripts_load() -> void:
	assert_object(load("res://ui/main.gd")).is_not_null()
	assert_object(load("res://ui/screens/home_screen.gd")).is_not_null()
	assert_object(load("res://ui/screens/offseason_screen.gd")).is_not_null()


func test_autoloads_registered() -> void:
	# autoload はシーン/プロジェクト起動時のみ登録される(=旧運用で .tscn が必要だった理由)。
	# GdUnit はプロジェクト文脈で実行するため singleton として参照できる。
	assert_object(Engine.get_main_loop().root.get_node_or_null("AppState")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("GameDb")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("RecordStore")).is_not_null()
	assert_object(Engine.get_main_loop().root.get_node_or_null("Rng")).is_not_null()
