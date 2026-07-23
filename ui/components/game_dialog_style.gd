extends RefCounted

# ダッシュボード基底と同じ配色・角丸・余白を、Window 系ダイアログと PopupMenu に適用する。
# Window は Control を継承しないため、各画面の描画ヘルパーではなく静的なテーマ適用として共有する。

const PANEL: Color = Color(0.086, 0.104, 0.127)
const PANEL_2: Color = Color(0.112, 0.137, 0.167)
const PANEL_3: Color = Color(0.150, 0.182, 0.222)
const BORDER: Color = Color(0.205, 0.245, 0.300)
const BORDER_SOFT: Color = Color(0.140, 0.168, 0.205)
const TEXT: Color = Color(0.930, 0.948, 0.965)
const MUTED: Color = Color(0.605, 0.665, 0.725)
const FAINT: Color = Color(0.395, 0.450, 0.510)
const BLUE: Color = Color(0.290, 0.610, 0.965)
const RED: Color = Color(0.910, 0.370, 0.370)


static func style_popup(menu: PopupMenu, font: Font = null, scale_factor: float = 1.0) -> void:
	menu.add_theme_stylebox_override("panel", _box(PANEL_2, BORDER, 8, 6))
	menu.add_theme_stylebox_override(
		"hover",
		_box(Color(BLUE.r, BLUE.g, BLUE.b, 0.18), Color(BLUE.r, BLUE.g, BLUE.b, 0.55), 6, 6)
	)
	menu.add_theme_color_override("font_color", TEXT)
	menu.add_theme_color_override("font_hover_color", TEXT)
	menu.add_theme_color_override("font_disabled_color", FAINT)
	menu.add_theme_color_override("font_separator_color", MUTED)
	menu.add_theme_constant_override("v_separation", max(4, int(round(6.0 * scale_factor))))
	if font != null:
		menu.add_theme_font_override("font", font)
	menu.add_theme_font_size_override("font_size", max(11, int(round(14.0 * scale_factor))))


static func apply_popup_theme(theme: Theme) -> void:
	theme.set_stylebox("panel", "PopupMenu", _box(PANEL_2, BORDER, 8, 6))
	theme.set_stylebox(
		"hover",
		"PopupMenu",
		_box(Color(BLUE.r, BLUE.g, BLUE.b, 0.18), Color(BLUE.r, BLUE.g, BLUE.b, 0.55), 6, 6)
	)
	theme.set_color("font_color", "PopupMenu", TEXT)
	theme.set_color("font_hover_color", "PopupMenu", TEXT)
	theme.set_color("font_disabled_color", "PopupMenu", FAINT)
	theme.set_color("font_separator_color", "PopupMenu", MUTED)
	theme.set_constant("v_separation", "PopupMenu", 6)


static func style_confirmation(
	dialog: ConfirmationDialog,
	font: Font = null,
	scale_factor: float = 1.0
) -> void:
	dialog.dialog_autowrap = true
	dialog.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 8, 20))
	var window_frame: StyleBoxFlat = _box(PANEL_2, BORDER, 8, 0)
	window_frame.expand_margin_top = 34.0
	dialog.add_theme_stylebox_override("embedded_border", window_frame)
	dialog.add_theme_stylebox_override("embedded_unfocused_border", window_frame)
	dialog.add_theme_constant_override("buttons_min_width", max(96, int(round(112.0 * scale_factor))))
	dialog.add_theme_constant_override("buttons_min_height", max(34, int(round(38.0 * scale_factor))))
	dialog.add_theme_constant_override("buttons_separation", max(12, int(round(18.0 * scale_factor))))
	dialog.add_theme_constant_override("title_height", max(30, int(round(34.0 * scale_factor))))
	dialog.add_theme_color_override("title_color", TEXT)
	if font != null:
		dialog.add_theme_font_override("title_font", font)
	dialog.add_theme_font_size_override("title_font_size", max(14, int(round(17.0 * scale_factor))))

	var label: Label = dialog.get_label()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", TEXT)
	label.add_theme_font_size_override("font_size", max(12, int(round(15.0 * scale_factor))))
	if font != null:
		label.add_theme_font_override("font", font)

	style_button(dialog.get_ok_button(), "primary", font, scale_factor)
	style_button(dialog.get_cancel_button(), "action", font, scale_factor)


static func style_modal_panel(panel: PanelContainer) -> void:
	panel.add_theme_stylebox_override("panel", _box(PANEL, BORDER, 8, 22))


static func style_modal_title(label: Label, font: Font = null) -> void:
	label.add_theme_color_override("font_color", TEXT)
	label.add_theme_font_size_override("font_size", 18)
	if font != null:
		label.add_theme_font_override("font", font)


static func style_modal_body(label: Label, font: Font = null) -> void:
	label.add_theme_color_override("font_color", TEXT)
	label.add_theme_font_size_override("font_size", 15)
	if font != null:
		label.add_theme_font_override("font", font)


static func style_button(
	button: Button,
	kind: String = "action",
	font: Font = null,
	scale_factor: float = 1.0
) -> void:
	var bg: Color = PANEL_3
	var border: Color = BORDER
	var hover: Color = Color(0.180, 0.220, 0.270)
	var pressed: Color = PANEL_2
	if kind == "primary":
		bg = BLUE
		border = BLUE
		hover = Color(0.360, 0.660, 1.0)
		pressed = Color(0.180, 0.430, 0.800)
	elif kind == "danger":
		bg = Color(RED.r, RED.g, RED.b, 0.18)
		border = Color(RED.r, RED.g, RED.b, 0.72)
		hover = Color(RED.r, RED.g, RED.b, 0.30)
		pressed = Color(RED.r, RED.g, RED.b, 0.42)

	button.add_theme_stylebox_override("normal", _box(bg, border, 7, 10))
	button.add_theme_stylebox_override("hover", _box(hover, border, 7, 10))
	button.add_theme_stylebox_override("pressed", _box(pressed, BLUE, 7, 10))
	button.add_theme_stylebox_override("focus", _box(bg, BLUE, 7, 10))
	button.add_theme_stylebox_override("disabled", _box(PANEL, BORDER_SOFT, 7, 10))
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_pressed_color", TEXT)
	button.add_theme_color_override("font_focus_color", TEXT)
	button.add_theme_color_override("font_disabled_color", FAINT)
	button.add_theme_font_size_override("font_size", max(11, int(round(14.0 * scale_factor))))
	if font != null:
		button.add_theme_font_override("font", font)


static func _box(
	bg: Color,
	border: Color,
	radius: int,
	horizontal_margin: int
) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(1 if border.a > 0.0 else 0)
	style.set_corner_radius_all(radius)
	style.content_margin_left = horizontal_margin
	style.content_margin_right = horizontal_margin
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style
