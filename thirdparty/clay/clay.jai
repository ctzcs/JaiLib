//
// clay.jai — Clay v0.14 纯 Jai 移植（第六层：声明辅助 / 语法糖）
//
// 移植自 olib: D:\MySpace\Github\olib\thirdparty\clay\clay.odin (455 行) 的
// 最后一段 “@region Odin 声明辅助”（前 330 行的基础类型与配置结构体早已在
// clay_types.jai 里，不要在这里重复定义）。
// 上游: nicbarker/clay v0.14 (b25a31c1a152915cd7dd6796e6592273e5a10aac)。
// Copyright (c) 2024 Nic Barker. Altered source; see LICENSE.md and README.md。
//
// 这一层全是「写 UI 时手疼」的薄包装：Padding / CornerRadius / Sizing 构造、
// 字符串→String、字符串→ElementId 哈希、以及 Odin 的 `UI()` + `deferred_none`
// 语法糖在 Jai 里的等价物。
//
// 与 olib 的有意差异（只有两处，都在下面就近标注）：
//   1. `UI`：Odin 用 `@(deferred_none = _CloseElement)` 拿到「作用域结束自动关闭」；
//      Jai 没有这个属性，改用**宏**把 body 包在 open / defer close 之间：
//          clay.UI(.{ ... }, #code {
//              clay.Text("hi", cfg);
//          });
//      语义等价（body 里 return 也会先触发 defer 的 _CloseElement）。
//      如果想去掉宏、手写显式配对，用 `UI_Begin(decl)` / `UI_End()`。
//   2. `ID` / `ID_LOCAL`：Odin 的 `index: u32 = 0` 默认参数，Jai 改成
//      `index: .. u32` 可变参数（Jai 的 0 个或多个同类型实参），
//      所以 `ID("x")` 与 `ID("x", 3)` 两种写法都能照抄。
//
// `[^]u8` -> `*u8`、`raw_data(label)` -> `label.data`、`len(label)` -> `label.count`。
//

//@region 结构体构造辅助

PaddingAll :: (allPadding: u16) -> Padding {
	return .{ left = allPadding, right = allPadding, top = allPadding, bottom = allPadding };
}

BorderOutside :: (width: u16) -> BorderWidth {
	// olib: return {width, width, width, width, 0}
	return .{ left = width, right = width, top = width, bottom = width, betweenChildren = 0 };
}

BorderAll :: (width: u16) -> BorderWidth {
	// olib: return {width, width, width, width, width}
	return .{ left = width, right = width, top = width, bottom = width, betweenChildren = width };
}

CornerRadiusAll :: (radius: float) -> CornerRadius {
	return .{ topLeft = radius, topRight = radius, bottomLeft = radius, bottomRight = radius };
}

// Jai 侧给了默认值：olib 的调用点都传 `{}`，这样 0.12 风格的无参调用也能过。
SizingFit :: (sizeMinMax := SizingConstraintsMinMax.{}) -> SizingAxis {
	return .{ type = .FIT, constraints = .{ sizeMinMax = sizeMinMax } };
}

SizingGrow :: (sizeMinMax := SizingConstraintsMinMax.{}) -> SizingAxis {
	return .{ type = .GROW, constraints = .{ sizeMinMax = sizeMinMax } };
}

SizingFixed :: (size: float) -> SizingAxis {
	return .{ type = .FIXED, constraints = .{ sizeMinMax = .{ min = size, max = size } } };
}

SizingPercent :: (sizePercent: float) -> SizingAxis {
	return .{ type = .PERCENT, constraints = .{ sizePercent = sizePercent } };
}
//@endregion

//@region 字符串与 ID

MakeString :: (label: string) -> String {
	return .{ chars = label.data, length = cast(s32) label.count };
}

// olib: ID :: proc(label: string, index: u32 = 0) -> ElementId
// Jai 没有默认参数 —— 用 `.. u32` 可变参数等价替代（见文件头说明 2）。
ID :: (label: string, index: .. u32) -> ElementId {
	i : u32 = 0;
	if index.count > 0 {
		i = index[0];
	}
	return _HashString(MakeString(label), i, 0);
}

// olib: ID_LOCAL :: proc(label: string, index: u32 = 0) -> ElementId
ID_LOCAL :: (label: string, index: .. u32) -> ElementId {
	i : u32 = 0;
	if index.count > 0 {
		i = index[0];
	}
	return _HashString(MakeString(label), i, _GetParentElementId());
}
//@endregion

//@region 元素声明语法糖

// olib: ConfigureOpenElement
ConfigureOpenElement :: (config: ElementDeclaration) -> bool {
	_ConfigureOpenElement(config);
	return true;
}

// olib: UI —— `@(deferred_none = _CloseElement)` 的 Jai 等价物（#expand 宏）
//
//   clay.UI(.{ layout = .{ ... } }, #code {
//       clay.Text("hello", cfg);
//       clay.UI(.{ ... }, #code { ... });
//   });
//
// 展开结果（`#expand` 把整段内联进调用点，外层 `{ }` 造出一个独立作用域）：
//   { _OpenElement(); defer _CloseElement(); _ConfigureOpenElement(decl); <body>; }
// 与 olib 的 `{ clay.UI()(decl); … }` 完全同构：**每个** UI() 都在它自己的块结束时
// _CloseElement()，嵌套调用结束时按 LIFO 逐个关闭。
//
// ⚠ 两个 Jai 陷阱（都在这里踩过）：
//   1. 宏里光写 `body;` **不会**把 Code 参数插进来 —— 必须 `#insert body;`
//      （否则 body 整段被静默丢弃，只留下 open/close）。
//   2. 必须写成 `#expand` + 显式 `{ }` 块；否则 defer 会绑到调用者作用域末尾，
//      嵌套的 open/close 顺序就全乱了（debug 面板那种上百层嵌套会直接崩）。
UI :: (decl: ElementDeclaration, $body := #code null) #expand {
	{
		_OpenElement();
		defer _CloseElement();
		_ConfigureOpenElement(decl);
		#insert body;
	}
}

// Jai 专属：不用宏、手写配对时用这两个。与 `_OpenElement` + `_ConfigureOpenElement` /
// `_CloseElement` 一一对应，只是去掉了下划线前缀，方便 kit 层调用。
UI_Begin :: (decl: ElementDeclaration) {
	_OpenElement();
	_ConfigureOpenElement(decl);
}

UI_End :: () {
	_CloseElement();
}

// olib: Text
// ⚠ olib 的 `$text: string` 是编译期常量参数；Jai 里就是普通 string 参数，
// 行为一致（内容只在本帧内被读取）。
Text :: (text: string, config: *TextElementConfig) {
	wrapped := MakeString(text);
	wrapped.isStaticallyAllocated = true;
	_OpenTextElement(wrapped, config);
}

// olib: TextDynamic
TextDynamic :: (text: string, config: *TextElementConfig) {
	_OpenTextElement(MakeString(text), config);
}

// olib: TextConfig
TextConfig :: (config: TextElementConfig) -> *TextElementConfig {
	return _StoreTextElementConfig(config);
}
//@endregion
