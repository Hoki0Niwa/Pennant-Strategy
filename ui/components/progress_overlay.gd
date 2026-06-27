extends Control
class_name ProgressOverlay

# 長時間処理中に画面全体を塞ぐ進捗オーバーレイ。
# show_progress -> update_progress を繰り返し、キャンセルボタンは cancel_requested だけを emit する。
# 実際に処理を止めるかどうかは呼び出し側の cancel_token が判断する。
signal cancel_requested

var _backdrop: ColorRect
var _panel: PanelContainer
var _title_label: Label
var _progress_bar: ProgressBar
var _detail_label: Label
var _cancel_button: Button
var _cancelled: bool = false


func _ready() -> void:
	_build()
	hide_progress()


# 子ノードをコードで構築する。シーンファイルを持たないため、どの画面からでも preload して使える。
func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	_backdrop = ColorRect.new()
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.05, 0.07, 0.10, 0.55)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(420, 0)
	center.add_child(_panel)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	_panel.add_child(margin)

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	_title_label = Label.new()
	_title_label.text = "処理中..."
	_title_label.add_theme_font_size_override("font_size", 18)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_title_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.value = 0.0
	_progress_bar.custom_minimum_size = Vector2(360, 22)
	box.add_child(_progress_bar)

	_detail_label = Label.new()
	_detail_label.text = ""
	_detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail_label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
	box.add_child(_detail_label)

	var button_row: HBoxContainer = HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(button_row)

	_cancel_button = Button.new()
	_cancel_button.text = "キャンセル"
	_cancel_button.custom_minimum_size = Vector2(140, 34)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	button_row.add_child(_cancel_button)


# 新しい処理開始時の初期化。前回のキャンセル状態と進捗表示をリセットする。
func show_progress(label: String) -> void:
	_cancelled = false
	_title_label.text = label
	_detail_label.text = ""
	_progress_bar.value = 0.0
	_cancel_button.disabled = false
	_cancel_button.text = "キャンセル"
	visible = true


# done/total が有効なら determinate progress、total<=0 なら sub_label だけを表示する。
func update_progress(done: int, total: int, sub_label: String = "") -> void:
	if total > 0:
		_progress_bar.max_value = float(total)
		_progress_bar.value = float(clamp(done, 0, total))
		var percent: float = float(done) / float(total) * 100.0
		_detail_label.text = "%d / %d  (%0.1f%%)%s" % [
			done, total, percent, ("  %s" % sub_label) if not sub_label.is_empty() else ""
		]
	else:
		_progress_bar.value = 0.0
		_detail_label.text = sub_label


# 閉じるときはキャンセル状態も戻し、次回 show_progress で素直に再利用できるようにする。
func hide_progress() -> void:
	visible = false
	_cancelled = false


# 二重押しを防いでから呼び出し側へキャンセル要求を通知する。
func _on_cancel_pressed() -> void:
	if _cancelled:
		return
	_cancelled = true
	_cancel_button.disabled = true
	_cancel_button.text = "キャンセル中..."
	cancel_requested.emit()
