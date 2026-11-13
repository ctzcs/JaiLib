//
// clay_memory.jai — Clay v0.14 纯 Jai 移植（第一层：内存）
//
// 移植自 olib: D:\MySpace\Github\olib\thirdparty\clay\clay_memory.odin (2,154 行)
// 上游: nicbarker/clay v0.14 (b25a31c1a152915cd7dd6796e6592273e5a10aac)。
// Copyright (c) 2024 Nic Barker. Altered source; see LICENSE.md and README.md.
//
// 纯 Jai，不链接 C 库，无 import。数组容量策略、arena 分配顺序、
// 分配对齐、诊断计数与 olib 逐行对应——这是布局引擎的地基。
//
// Jai 语法对应（行为等价，逐条列在 docs 里）：
//   `x ? a : b`              -> if/else（Jai 无三元；ifx 只用于编译期）
//   `for i := 0; c; i += 1`  -> while 循环
//   `x ~= y`（XOR）           -> `x ^= y`
//   `&x`                     -> `*x`（取地址）
//   `x^`（解引用）            -> `x.*`
//   `[^]T`                   -> `*T`
//   `cast(i32)(someBool)`    -> 直接用 if（Jai 的 bool 不参与整型运算）
//

//@region 全局状态、默认值与错误处理

// clay.h:107 — Clay__SuppressUnusedLatchDefinitionVariableWarning
CLAY__ELEMENT_DEFINITION_LATCH : u8;

_SuppressUnusedLatchDefinitionVariableWarning :: () {
	_ = CLAY__ELEMENT_DEFINITION_LATCH;
}

CLAY_LAYOUT_DEFAULT : LayoutConfig = .{ sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = 0 } } } } };

_Color_DEFAULT : Color = .[0, 0, 0, 0];

_CornerRadius_DEFAULT : CornerRadius = .{ topLeft = 0 };

_BorderWidth_DEFAULT : BorderWidth = .{ left = 0 };

_currentContext : *Context;

_defaultMaxElementCount : s32 = 8192;

_defaultMaxMeasureTextWordCacheCount : s32 = 16384;

// clay.h:1022 — Clay__ErrorHandlerFunctionDefault
_ErrorHandlerFunctionDefault :: (errorText: ErrorData) {
	_ = errorText;
}

CLAY__SPACECHAR : String = .{ length = 1, chars = " ".data };

CLAY__STRING_DEFAULT : String = .{ length = 0, chars = null };

CLAY__WARNING_DEFAULT : _Warning = .{ baseMessage = .{ isStaticallyAllocated = false } };

_Bool_DEFAULT : bool = false;

// olib 把这两个放在 clay_api.odin，但 clay_memory 全篇依赖 GetCurrentContext()。
// 为了“第一层可独立编译”，这里一并带过来；移植 clay_api 时不要再重复定义。
GetCurrentContext :: () -> *Context {
	return _currentContext;
}

SetCurrentContext :: (ctx: *Context) {
	_currentContext = ctx;
}
//@endregion

//@region 类型化数组（CLAY__ARRAY_DEFINE 展开）
//
// olib 用 CLAY__ARRAY_DEFINE 宏展开出 26 组「类型化数组」，每组 7 个过程。
// 这里逐组手写（等价的机械展开），命名、容量策略、越界回落到 *_DEFAULT
// 的语义与 olib 完全一致。

// clay.h:1063 — Clay__boolArray_Allocate_Arena
_boolArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _boolArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*bool) _Array_Allocate_Arena(capacity, size_of(bool), arena) };
}

// clay.h:1063 — Clay__boolArray_Get
_boolArray_Get :: (array: *_boolArray, index: s32) -> *bool {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *_Bool_DEFAULT;
}

// clay.h:1063 — Clay__boolArray_GetValue
_boolArray_GetValue :: (array: *_boolArray, index: s32) -> bool {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return _Bool_DEFAULT;
}

// clay.h:1063 — Clay__boolArray_Add
_boolArray_Add :: (array: *_boolArray, item: bool) -> *bool {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *_Bool_DEFAULT;
}

// clay.h:1063 — Clay__boolArraySlice_Get
_boolArraySlice_Get :: (slice: *_boolArraySlice, index: s32) -> *bool {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *_Bool_DEFAULT;
}

// clay.h:1063 — Clay__boolArray_RemoveSwapback
_boolArray_RemoveSwapback :: (array: *_boolArray, index: s32) -> bool {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : bool = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return _Bool_DEFAULT;
}

// clay.h:1063 — Clay__boolArray_Set
_boolArray_Set :: (array: *_boolArray, index: s32, value: bool) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

// clay.h:1064 — Clay__int32_tArray_Allocate_Arena
_int32_tArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _int32_tArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*s32) _Array_Allocate_Arena(capacity, size_of(s32), arena) };
}

// clay.h:1064 — Clay__int32_tArray_Get
_int32_tArray_Get :: (array: *_int32_tArray, index: s32) -> *s32 {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *int32_t_DEFAULT;
}

// clay.h:1064 — Clay__int32_tArray_GetValue
_int32_tArray_GetValue :: (array: *_int32_tArray, index: s32) -> s32 {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return int32_t_DEFAULT;
}

// clay.h:1064 — Clay__int32_tArray_Add
_int32_tArray_Add :: (array: *_int32_tArray, item: s32) -> *s32 {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *int32_t_DEFAULT;
}

// clay.h:1064 — Clay__int32_tArraySlice_Get
_int32_tArraySlice_Get :: (slice: *_int32_tArraySlice, index: s32) -> *s32 {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *int32_t_DEFAULT;
}

// clay.h:1064 — Clay__int32_tArray_RemoveSwapback
_int32_tArray_RemoveSwapback :: (array: *_int32_tArray, index: s32) -> s32 {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : s32 = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return int32_t_DEFAULT;
}

// clay.h:1064 — Clay__int32_tArray_Set
_int32_tArray_Set :: (array: *_int32_tArray, index: s32, value: s32) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

int32_t_DEFAULT : s32 = 0;

// clay.h:1065 — Clay__charArray_Allocate_Arena
_charArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _charArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*u8) _Array_Allocate_Arena(capacity, size_of(u8), arena) };
}

// clay.h:1065 — Clay__charArray_Get
_charArray_Get :: (array: *_charArray, index: s32) -> *u8 {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *char_DEFAULT;
}

// clay.h:1065 — Clay__charArray_GetValue
_charArray_GetValue :: (array: *_charArray, index: s32) -> u8 {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return char_DEFAULT;
}

// clay.h:1065 — Clay__charArray_Add
_charArray_Add :: (array: *_charArray, item: u8) -> *u8 {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *char_DEFAULT;
}

// clay.h:1065 — Clay__charArraySlice_Get
_charArraySlice_Get :: (slice: *_charArraySlice, index: s32) -> *u8 {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *char_DEFAULT;
}

// clay.h:1065 — Clay__charArray_RemoveSwapback
_charArray_RemoveSwapback :: (array: *_charArray, index: s32) -> u8 {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : u8 = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return char_DEFAULT;
}

// clay.h:1065 — Clay__charArray_Set
_charArray_Set :: (array: *_charArray, index: s32, value: u8) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

char_DEFAULT : u8 = 0;

// clay.h:1066 — Clay__ElementIdArray_Allocate_Arena
ElementIdArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> ElementIdArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*ElementId) _Array_Allocate_Arena(capacity, size_of(ElementId), arena) };
}

// clay.h:1066 — Clay__ElementIdArray_Get
ElementIdArray_Get :: (array: *ElementIdArray, index: s32) -> *ElementId {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *ElementId_DEFAULT;
}

// clay.h:1066 — Clay__ElementIdArray_GetValue
ElementIdArray_GetValue :: (array: *ElementIdArray, index: s32) -> ElementId {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return ElementId_DEFAULT;
}

// clay.h:1066 — Clay__ElementIdArray_Add
ElementIdArray_Add :: (array: *ElementIdArray, item: ElementId) -> *ElementId {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *ElementId_DEFAULT;
}

// clay.h:1066 — Clay__ElementIdArraySlice_Get
ElementIdArraySlice_Get :: (slice: *ElementIdArraySlice, index: s32) -> *ElementId {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *ElementId_DEFAULT;
}

// clay.h:1066 — Clay__ElementIdArray_RemoveSwapback
ElementIdArray_RemoveSwapback :: (array: *ElementIdArray, index: s32) -> ElementId {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : ElementId = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return ElementId_DEFAULT;
}

// clay.h:1066 — Clay__ElementIdArray_Set
ElementIdArray_Set :: (array: *ElementIdArray, index: s32, value: ElementId) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

ElementId_DEFAULT : ElementId = .{ id = 0 };

// clay.h:1067 — Clay__LayoutConfigArray_Allocate_Arena
_LayoutConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _LayoutConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*LayoutConfig) _Array_Allocate_Arena(capacity, size_of(LayoutConfig), arena) };
}

// clay.h:1067 — Clay__LayoutConfigArray_Get
_LayoutConfigArray_Get :: (array: *_LayoutConfigArray, index: s32) -> *LayoutConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *LayoutConfig_DEFAULT;
}

// clay.h:1067 — Clay__LayoutConfigArray_GetValue
_LayoutConfigArray_GetValue :: (array: *_LayoutConfigArray, index: s32) -> LayoutConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return LayoutConfig_DEFAULT;
}

// clay.h:1067 — Clay__LayoutConfigArray_Add
_LayoutConfigArray_Add :: (array: *_LayoutConfigArray, item: LayoutConfig) -> *LayoutConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *LayoutConfig_DEFAULT;
}

// clay.h:1067 — Clay__LayoutConfigArraySlice_Get
_LayoutConfigArraySlice_Get :: (slice: *_LayoutConfigArraySlice, index: s32) -> *LayoutConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *LayoutConfig_DEFAULT;
}

// clay.h:1067 — Clay__LayoutConfigArray_RemoveSwapback
_LayoutConfigArray_RemoveSwapback :: (array: *_LayoutConfigArray, index: s32) -> LayoutConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : LayoutConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return LayoutConfig_DEFAULT;
}

// clay.h:1067 — Clay__LayoutConfigArray_Set
_LayoutConfigArray_Set :: (array: *_LayoutConfigArray, index: s32, value: LayoutConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

LayoutConfig_DEFAULT : LayoutConfig = .{ sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = 0 } } } } };

// clay.h:1068 — Clay__TextElementConfigArray_Allocate_Arena
_TextElementConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _TextElementConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*TextElementConfig) _Array_Allocate_Arena(capacity, size_of(TextElementConfig), arena) };
}

// clay.h:1068 — Clay__TextElementConfigArray_Get
_TextElementConfigArray_Get :: (array: *_TextElementConfigArray, index: s32) -> *TextElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *TextElementConfig_DEFAULT;
}

// clay.h:1068 — Clay__TextElementConfigArray_GetValue
_TextElementConfigArray_GetValue :: (array: *_TextElementConfigArray, index: s32) -> TextElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return TextElementConfig_DEFAULT;
}

// clay.h:1068 — Clay__TextElementConfigArray_Add
_TextElementConfigArray_Add :: (array: *_TextElementConfigArray, item: TextElementConfig) -> *TextElementConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *TextElementConfig_DEFAULT;
}

// clay.h:1068 — Clay__TextElementConfigArraySlice_Get
_TextElementConfigArraySlice_Get :: (slice: *_TextElementConfigArraySlice, index: s32) -> *TextElementConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *TextElementConfig_DEFAULT;
}

// clay.h:1068 — Clay__TextElementConfigArray_RemoveSwapback
_TextElementConfigArray_RemoveSwapback :: (array: *_TextElementConfigArray, index: s32) -> TextElementConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : TextElementConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return TextElementConfig_DEFAULT;
}

// clay.h:1068 — Clay__TextElementConfigArray_Set
_TextElementConfigArray_Set :: (array: *_TextElementConfigArray, index: s32, value: TextElementConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

TextElementConfig_DEFAULT : TextElementConfig = .{ userData = null };

// clay.h:1069 — Clay__AspectRatioElementConfigArray_Allocate_Arena
_AspectRatioElementConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _AspectRatioElementConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*AspectRatioElementConfig) _Array_Allocate_Arena(capacity, size_of(AspectRatioElementConfig), arena) };
}

// clay.h:1069 — Clay__AspectRatioElementConfigArray_Get
_AspectRatioElementConfigArray_Get :: (array: *_AspectRatioElementConfigArray, index: s32) -> *AspectRatioElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *AspectRatioElementConfig_DEFAULT;
}

// clay.h:1069 — Clay__AspectRatioElementConfigArray_GetValue
_AspectRatioElementConfigArray_GetValue :: (array: *_AspectRatioElementConfigArray, index: s32) -> AspectRatioElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return AspectRatioElementConfig_DEFAULT;
}

// clay.h:1069 — Clay__AspectRatioElementConfigArray_Add
_AspectRatioElementConfigArray_Add :: (array: *_AspectRatioElementConfigArray, item: AspectRatioElementConfig) -> *AspectRatioElementConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *AspectRatioElementConfig_DEFAULT;
}

// clay.h:1069 — Clay__AspectRatioElementConfigArraySlice_Get
_AspectRatioElementConfigArraySlice_Get :: (slice: *_AspectRatioElementConfigArraySlice, index: s32) -> *AspectRatioElementConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *AspectRatioElementConfig_DEFAULT;
}

// clay.h:1069 — Clay__AspectRatioElementConfigArray_RemoveSwapback
_AspectRatioElementConfigArray_RemoveSwapback :: (array: *_AspectRatioElementConfigArray, index: s32) -> AspectRatioElementConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : AspectRatioElementConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return AspectRatioElementConfig_DEFAULT;
}

// clay.h:1069 — Clay__AspectRatioElementConfigArray_Set
_AspectRatioElementConfigArray_Set :: (array: *_AspectRatioElementConfigArray, index: s32, value: AspectRatioElementConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

AspectRatioElementConfig_DEFAULT : AspectRatioElementConfig = .{ aspectRatio = 0 };

// clay.h:1070 — Clay__ImageElementConfigArray_Allocate_Arena
_ImageElementConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _ImageElementConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*ImageElementConfig) _Array_Allocate_Arena(capacity, size_of(ImageElementConfig), arena) };
}

// clay.h:1070 — Clay__ImageElementConfigArray_Get
_ImageElementConfigArray_Get :: (array: *_ImageElementConfigArray, index: s32) -> *ImageElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *ImageElementConfig_DEFAULT;
}

// clay.h:1070 — Clay__ImageElementConfigArray_GetValue
_ImageElementConfigArray_GetValue :: (array: *_ImageElementConfigArray, index: s32) -> ImageElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return ImageElementConfig_DEFAULT;
}

// clay.h:1070 — Clay__ImageElementConfigArray_Add
_ImageElementConfigArray_Add :: (array: *_ImageElementConfigArray, item: ImageElementConfig) -> *ImageElementConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *ImageElementConfig_DEFAULT;
}

// clay.h:1070 — Clay__ImageElementConfigArraySlice_Get
_ImageElementConfigArraySlice_Get :: (slice: *_ImageElementConfigArraySlice, index: s32) -> *ImageElementConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *ImageElementConfig_DEFAULT;
}

// clay.h:1070 — Clay__ImageElementConfigArray_RemoveSwapback
_ImageElementConfigArray_RemoveSwapback :: (array: *_ImageElementConfigArray, index: s32) -> ImageElementConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : ImageElementConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return ImageElementConfig_DEFAULT;
}

// clay.h:1070 — Clay__ImageElementConfigArray_Set
_ImageElementConfigArray_Set :: (array: *_ImageElementConfigArray, index: s32, value: ImageElementConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

ImageElementConfig_DEFAULT : ImageElementConfig = .{ imageData = null };

// clay.h:1071 — Clay__FloatingElementConfigArray_Allocate_Arena
_FloatingElementConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _FloatingElementConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*FloatingElementConfig) _Array_Allocate_Arena(capacity, size_of(FloatingElementConfig), arena) };
}

// clay.h:1071 — Clay__FloatingElementConfigArray_Get
_FloatingElementConfigArray_Get :: (array: *_FloatingElementConfigArray, index: s32) -> *FloatingElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *FloatingElementConfig_DEFAULT;
}

// clay.h:1071 — Clay__FloatingElementConfigArray_GetValue
_FloatingElementConfigArray_GetValue :: (array: *_FloatingElementConfigArray, index: s32) -> FloatingElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return FloatingElementConfig_DEFAULT;
}

// clay.h:1071 — Clay__FloatingElementConfigArray_Add
_FloatingElementConfigArray_Add :: (array: *_FloatingElementConfigArray, item: FloatingElementConfig) -> *FloatingElementConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *FloatingElementConfig_DEFAULT;
}

// clay.h:1071 — Clay__FloatingElementConfigArraySlice_Get
_FloatingElementConfigArraySlice_Get :: (slice: *_FloatingElementConfigArraySlice, index: s32) -> *FloatingElementConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *FloatingElementConfig_DEFAULT;
}

// clay.h:1071 — Clay__FloatingElementConfigArray_RemoveSwapback
_FloatingElementConfigArray_RemoveSwapback :: (array: *_FloatingElementConfigArray, index: s32) -> FloatingElementConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : FloatingElementConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return FloatingElementConfig_DEFAULT;
}

// clay.h:1071 — Clay__FloatingElementConfigArray_Set
_FloatingElementConfigArray_Set :: (array: *_FloatingElementConfigArray, index: s32, value: FloatingElementConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

FloatingElementConfig_DEFAULT : FloatingElementConfig = .{ offset = .[0, 0] };

// clay.h:1072 — Clay__CustomElementConfigArray_Allocate_Arena
_CustomElementConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _CustomElementConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*CustomElementConfig) _Array_Allocate_Arena(capacity, size_of(CustomElementConfig), arena) };
}

// clay.h:1072 — Clay__CustomElementConfigArray_Get
_CustomElementConfigArray_Get :: (array: *_CustomElementConfigArray, index: s32) -> *CustomElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *CustomElementConfig_DEFAULT;
}

// clay.h:1072 — Clay__CustomElementConfigArray_GetValue
_CustomElementConfigArray_GetValue :: (array: *_CustomElementConfigArray, index: s32) -> CustomElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return CustomElementConfig_DEFAULT;
}

// clay.h:1072 — Clay__CustomElementConfigArray_Add
_CustomElementConfigArray_Add :: (array: *_CustomElementConfigArray, item: CustomElementConfig) -> *CustomElementConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *CustomElementConfig_DEFAULT;
}

// clay.h:1072 — Clay__CustomElementConfigArraySlice_Get
_CustomElementConfigArraySlice_Get :: (slice: *_CustomElementConfigArraySlice, index: s32) -> *CustomElementConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *CustomElementConfig_DEFAULT;
}

// clay.h:1072 — Clay__CustomElementConfigArray_RemoveSwapback
_CustomElementConfigArray_RemoveSwapback :: (array: *_CustomElementConfigArray, index: s32) -> CustomElementConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : CustomElementConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return CustomElementConfig_DEFAULT;
}

// clay.h:1072 — Clay__CustomElementConfigArray_Set
_CustomElementConfigArray_Set :: (array: *_CustomElementConfigArray, index: s32, value: CustomElementConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

CustomElementConfig_DEFAULT : CustomElementConfig = .{ customData = null };

// clay.h:1073 — Clay__ClipElementConfigArray_Allocate_Arena
_ClipElementConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _ClipElementConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*ClipElementConfig) _Array_Allocate_Arena(capacity, size_of(ClipElementConfig), arena) };
}

// clay.h:1073 — Clay__ClipElementConfigArray_Get
_ClipElementConfigArray_Get :: (array: *_ClipElementConfigArray, index: s32) -> *ClipElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *ClipElementConfig_DEFAULT;
}

// clay.h:1073 — Clay__ClipElementConfigArray_GetValue
_ClipElementConfigArray_GetValue :: (array: *_ClipElementConfigArray, index: s32) -> ClipElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return ClipElementConfig_DEFAULT;
}

// clay.h:1073 — Clay__ClipElementConfigArray_Add
_ClipElementConfigArray_Add :: (array: *_ClipElementConfigArray, item: ClipElementConfig) -> *ClipElementConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *ClipElementConfig_DEFAULT;
}

// clay.h:1073 — Clay__ClipElementConfigArraySlice_Get
_ClipElementConfigArraySlice_Get :: (slice: *_ClipElementConfigArraySlice, index: s32) -> *ClipElementConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *ClipElementConfig_DEFAULT;
}

// clay.h:1073 — Clay__ClipElementConfigArray_RemoveSwapback
_ClipElementConfigArray_RemoveSwapback :: (array: *_ClipElementConfigArray, index: s32) -> ClipElementConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : ClipElementConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return ClipElementConfig_DEFAULT;
}

// clay.h:1073 — Clay__ClipElementConfigArray_Set
_ClipElementConfigArray_Set :: (array: *_ClipElementConfigArray, index: s32, value: ClipElementConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

ClipElementConfig_DEFAULT : ClipElementConfig = .{ horizontal = false };

// clay.h:1074 — Clay__BorderElementConfigArray_Allocate_Arena
_BorderElementConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _BorderElementConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*BorderElementConfig) _Array_Allocate_Arena(capacity, size_of(BorderElementConfig), arena) };
}

// clay.h:1074 — Clay__BorderElementConfigArray_Get
_BorderElementConfigArray_Get :: (array: *_BorderElementConfigArray, index: s32) -> *BorderElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *BorderElementConfig_DEFAULT;
}

// clay.h:1074 — Clay__BorderElementConfigArray_GetValue
_BorderElementConfigArray_GetValue :: (array: *_BorderElementConfigArray, index: s32) -> BorderElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return BorderElementConfig_DEFAULT;
}

// clay.h:1074 — Clay__BorderElementConfigArray_Add
_BorderElementConfigArray_Add :: (array: *_BorderElementConfigArray, item: BorderElementConfig) -> *BorderElementConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *BorderElementConfig_DEFAULT;
}

// clay.h:1074 — Clay__BorderElementConfigArraySlice_Get
_BorderElementConfigArraySlice_Get :: (slice: *_BorderElementConfigArraySlice, index: s32) -> *BorderElementConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *BorderElementConfig_DEFAULT;
}

// clay.h:1074 — Clay__BorderElementConfigArray_RemoveSwapback
_BorderElementConfigArray_RemoveSwapback :: (array: *_BorderElementConfigArray, index: s32) -> BorderElementConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : BorderElementConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return BorderElementConfig_DEFAULT;
}

// clay.h:1074 — Clay__BorderElementConfigArray_Set
_BorderElementConfigArray_Set :: (array: *_BorderElementConfigArray, index: s32, value: BorderElementConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

BorderElementConfig_DEFAULT : BorderElementConfig = .{ color = .[0, 0, 0, 0] };

// clay.h:1075 — Clay__StringArray_Allocate_Arena
_StringArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _StringArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*String) _Array_Allocate_Arena(capacity, size_of(String), arena) };
}

// clay.h:1075 — Clay__StringArray_Get
_StringArray_Get :: (array: *_StringArray, index: s32) -> *String {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *String_DEFAULT;
}

// clay.h:1075 — Clay__StringArray_GetValue
_StringArray_GetValue :: (array: *_StringArray, index: s32) -> String {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return String_DEFAULT;
}

// clay.h:1075 — Clay__StringArray_Add
_StringArray_Add :: (array: *_StringArray, item: String) -> *String {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *String_DEFAULT;
}

// clay.h:1075 — Clay__StringArraySlice_Get
_StringArraySlice_Get :: (slice: *_StringArraySlice, index: s32) -> *String {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *String_DEFAULT;
}

// clay.h:1075 — Clay__StringArray_RemoveSwapback
_StringArray_RemoveSwapback :: (array: *_StringArray, index: s32) -> String {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : String = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return String_DEFAULT;
}

// clay.h:1075 — Clay__StringArray_Set
_StringArray_Set :: (array: *_StringArray, index: s32, value: String) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

String_DEFAULT : String = .{ isStaticallyAllocated = false };

// clay.h:1076 — Clay__SharedElementConfigArray_Allocate_Arena
_SharedElementConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _SharedElementConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*SharedElementConfig) _Array_Allocate_Arena(capacity, size_of(SharedElementConfig), arena) };
}

// clay.h:1076 — Clay__SharedElementConfigArray_Get
_SharedElementConfigArray_Get :: (array: *_SharedElementConfigArray, index: s32) -> *SharedElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *SharedElementConfig_DEFAULT;
}

// clay.h:1076 — Clay__SharedElementConfigArray_GetValue
_SharedElementConfigArray_GetValue :: (array: *_SharedElementConfigArray, index: s32) -> SharedElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return SharedElementConfig_DEFAULT;
}

// clay.h:1076 — Clay__SharedElementConfigArray_Add
_SharedElementConfigArray_Add :: (array: *_SharedElementConfigArray, item: SharedElementConfig) -> *SharedElementConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *SharedElementConfig_DEFAULT;
}

// clay.h:1076 — Clay__SharedElementConfigArraySlice_Get
_SharedElementConfigArraySlice_Get :: (slice: *_SharedElementConfigArraySlice, index: s32) -> *SharedElementConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *SharedElementConfig_DEFAULT;
}

// clay.h:1076 — Clay__SharedElementConfigArray_RemoveSwapback
_SharedElementConfigArray_RemoveSwapback :: (array: *_SharedElementConfigArray, index: s32) -> SharedElementConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : SharedElementConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return SharedElementConfig_DEFAULT;
}

// clay.h:1076 — Clay__SharedElementConfigArray_Set
_SharedElementConfigArray_Set :: (array: *_SharedElementConfigArray, index: s32, value: SharedElementConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

SharedElementConfig_DEFAULT : SharedElementConfig = .{ backgroundColor = .[0, 0, 0, 0] };

// clay.h:1077 — Clay__RenderCommandArray_Allocate_Arena
RenderCommandArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> ClayArray(RenderCommand) {
	return .{ capacity = capacity, length = 0, internalArray = cast(*RenderCommand) _Array_Allocate_Arena(capacity, size_of(RenderCommand), arena) };
}

// clay.h:1077 — Clay__RenderCommandArray_Get
RenderCommandArray_Get :: (array: *ClayArray(RenderCommand), index: s32) -> *RenderCommand {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *RenderCommand_DEFAULT;
}

// clay.h:1077 — Clay__RenderCommandArray_GetValue
RenderCommandArray_GetValue :: (array: *ClayArray(RenderCommand), index: s32) -> RenderCommand {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return RenderCommand_DEFAULT;
}

// clay.h:1077 — Clay__RenderCommandArray_Add
RenderCommandArray_Add :: (array: *ClayArray(RenderCommand), item: RenderCommand) -> *RenderCommand {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *RenderCommand_DEFAULT;
}

// clay.h:1077 — Clay__RenderCommandArraySlice_Get
RenderCommandArraySlice_Get :: (slice: *RenderCommandArraySlice, index: s32) -> *RenderCommand {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *RenderCommand_DEFAULT;
}

// clay.h:1077 — Clay__RenderCommandArray_RemoveSwapback
RenderCommandArray_RemoveSwapback :: (array: *ClayArray(RenderCommand), index: s32) -> RenderCommand {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : RenderCommand = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return RenderCommand_DEFAULT;
}

// clay.h:1077 — Clay__RenderCommandArray_Set
RenderCommandArray_Set :: (array: *ClayArray(RenderCommand), index: s32, value: RenderCommand) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

RenderCommand_DEFAULT : RenderCommand = .{ boundingBox = .{ x = 0 } };

// clay.h:1107 — Clay__ElementConfigArray_Allocate_Arena
_ElementConfigArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _ElementConfigArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*ElementConfig) _Array_Allocate_Arena(capacity, size_of(ElementConfig), arena) };
}

// clay.h:1107 — Clay__ElementConfigArray_Get
_ElementConfigArray_Get :: (array: *_ElementConfigArray, index: s32) -> *ElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *ElementConfig_DEFAULT;
}

// clay.h:1107 — Clay__ElementConfigArray_GetValue
_ElementConfigArray_GetValue :: (array: *_ElementConfigArray, index: s32) -> ElementConfig {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return ElementConfig_DEFAULT;
}

// clay.h:1107 — Clay__ElementConfigArray_Add
_ElementConfigArray_Add :: (array: *_ElementConfigArray, item: ElementConfig) -> *ElementConfig {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *ElementConfig_DEFAULT;
}

// clay.h:1107 — Clay__ElementConfigArraySlice_Get
_ElementConfigArraySlice_Get :: (slice: *_ElementConfigArraySlice, index: s32) -> *ElementConfig {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *ElementConfig_DEFAULT;
}

// clay.h:1107 — Clay__ElementConfigArray_RemoveSwapback
_ElementConfigArray_RemoveSwapback :: (array: *_ElementConfigArray, index: s32) -> ElementConfig {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : ElementConfig = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return ElementConfig_DEFAULT;
}

// clay.h:1107 — Clay__ElementConfigArray_Set
_ElementConfigArray_Set :: (array: *_ElementConfigArray, index: s32, value: ElementConfig) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

ElementConfig_DEFAULT : ElementConfig = .{ type = 0 };

// clay.h:1114 — Clay__WrappedTextLineArray_Allocate_Arena
_WrappedTextLineArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _WrappedTextLineArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*_WrappedTextLine) _Array_Allocate_Arena(capacity, size_of(_WrappedTextLine), arena) };
}

// clay.h:1114 — Clay__WrappedTextLineArray_Get
_WrappedTextLineArray_Get :: (array: *_WrappedTextLineArray, index: s32) -> *_WrappedTextLine {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *_WrappedTextLine_DEFAULT;
}

// clay.h:1114 — Clay__WrappedTextLineArray_GetValue
_WrappedTextLineArray_GetValue :: (array: *_WrappedTextLineArray, index: s32) -> _WrappedTextLine {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return _WrappedTextLine_DEFAULT;
}

// clay.h:1114 — Clay__WrappedTextLineArray_Add
_WrappedTextLineArray_Add :: (array: *_WrappedTextLineArray, item: _WrappedTextLine) -> *_WrappedTextLine {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *_WrappedTextLine_DEFAULT;
}

// clay.h:1114 — Clay__WrappedTextLineArraySlice_Get
_WrappedTextLineArraySlice_Get :: (slice: *_WrappedTextLineArraySlice, index: s32) -> *_WrappedTextLine {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *_WrappedTextLine_DEFAULT;
}

// clay.h:1114 — Clay__WrappedTextLineArray_RemoveSwapback
_WrappedTextLineArray_RemoveSwapback :: (array: *_WrappedTextLineArray, index: s32) -> _WrappedTextLine {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : _WrappedTextLine = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return _WrappedTextLine_DEFAULT;
}

// clay.h:1114 — Clay__WrappedTextLineArray_Set
_WrappedTextLineArray_Set :: (array: *_WrappedTextLineArray, index: s32, value: _WrappedTextLine) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

_WrappedTextLine_DEFAULT : _WrappedTextLine = .{ dimensions = .{ width = 0 } };

// clay.h:1123 — Clay__TextElementDataArray_Allocate_Arena
_TextElementDataArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _TextElementDataArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*_TextElementData) _Array_Allocate_Arena(capacity, size_of(_TextElementData), arena) };
}

// clay.h:1123 — Clay__TextElementDataArray_Get
_TextElementDataArray_Get :: (array: *_TextElementDataArray, index: s32) -> *_TextElementData {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *_TextElementData_DEFAULT;
}

// clay.h:1123 — Clay__TextElementDataArray_GetValue
_TextElementDataArray_GetValue :: (array: *_TextElementDataArray, index: s32) -> _TextElementData {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return _TextElementData_DEFAULT;
}

// clay.h:1123 — Clay__TextElementDataArray_Add
_TextElementDataArray_Add :: (array: *_TextElementDataArray, item: _TextElementData) -> *_TextElementData {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *_TextElementData_DEFAULT;
}

// clay.h:1123 — Clay__TextElementDataArraySlice_Get
_TextElementDataArraySlice_Get :: (slice: *_TextElementDataArraySlice, index: s32) -> *_TextElementData {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *_TextElementData_DEFAULT;
}

// clay.h:1123 — Clay__TextElementDataArray_RemoveSwapback
_TextElementDataArray_RemoveSwapback :: (array: *_TextElementDataArray, index: s32) -> _TextElementData {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : _TextElementData = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return _TextElementData_DEFAULT;
}

// clay.h:1123 — Clay__TextElementDataArray_Set
_TextElementDataArray_Set :: (array: *_TextElementDataArray, index: s32, value: _TextElementData) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

_TextElementData_DEFAULT : _TextElementData = .{ text = .{ isStaticallyAllocated = false } };

// clay.h:1142 — Clay__LayoutElementArray_Allocate_Arena
LayoutElementArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> LayoutElementArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*LayoutElement) _Array_Allocate_Arena(capacity, size_of(LayoutElement), arena) };
}

// clay.h:1142 — Clay__LayoutElementArray_Get
LayoutElementArray_Get :: (array: *LayoutElementArray, index: s32) -> *LayoutElement {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *LayoutElement_DEFAULT;
}

// clay.h:1142 — Clay__LayoutElementArray_GetValue
LayoutElementArray_GetValue :: (array: *LayoutElementArray, index: s32) -> LayoutElement {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return LayoutElement_DEFAULT;
}

// clay.h:1142 — Clay__LayoutElementArray_Add
LayoutElementArray_Add :: (array: *LayoutElementArray, item: LayoutElement) -> *LayoutElement {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *LayoutElement_DEFAULT;
}

// clay.h:1142 — Clay__LayoutElementArraySlice_Get
LayoutElementArraySlice_Get :: (slice: *LayoutElementArraySlice, index: s32) -> *LayoutElement {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *LayoutElement_DEFAULT;
}

// clay.h:1142 — Clay__LayoutElementArray_RemoveSwapback
LayoutElementArray_RemoveSwapback :: (array: *LayoutElementArray, index: s32) -> LayoutElement {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : LayoutElement = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return LayoutElement_DEFAULT;
}

// clay.h:1142 — Clay__LayoutElementArray_Set
LayoutElementArray_Set :: (array: *LayoutElementArray, index: s32, value: LayoutElement) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

LayoutElement_DEFAULT : LayoutElement = .{ childrenOrTextContent = .{ children = .{ elements = null } } };

// clay.h:1159 — Clay__ScrollContainerDataInternalArray_Allocate_Arena
_ScrollContainerDataInternalArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _ScrollContainerDataInternalArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*_ScrollContainerDataInternal) _Array_Allocate_Arena(capacity, size_of(_ScrollContainerDataInternal), arena) };
}

// clay.h:1159 — Clay__ScrollContainerDataInternalArray_Get
_ScrollContainerDataInternalArray_Get :: (array: *_ScrollContainerDataInternalArray, index: s32) -> *_ScrollContainerDataInternal {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *_ScrollContainerDataInternal_DEFAULT;
}

// clay.h:1159 — Clay__ScrollContainerDataInternalArray_GetValue
_ScrollContainerDataInternalArray_GetValue :: (array: *_ScrollContainerDataInternalArray, index: s32) -> _ScrollContainerDataInternal {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return _ScrollContainerDataInternal_DEFAULT;
}

// clay.h:1159 — Clay__ScrollContainerDataInternalArray_Add
_ScrollContainerDataInternalArray_Add :: (array: *_ScrollContainerDataInternalArray, item: _ScrollContainerDataInternal) -> *_ScrollContainerDataInternal {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *_ScrollContainerDataInternal_DEFAULT;
}

// clay.h:1159 — Clay__ScrollContainerDataInternalArraySlice_Get
_ScrollContainerDataInternalArraySlice_Get :: (slice: *_ScrollContainerDataInternalArraySlice, index: s32) -> *_ScrollContainerDataInternal {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *_ScrollContainerDataInternal_DEFAULT;
}

// clay.h:1159 — Clay__ScrollContainerDataInternalArray_RemoveSwapback
_ScrollContainerDataInternalArray_RemoveSwapback :: (array: *_ScrollContainerDataInternalArray, index: s32) -> _ScrollContainerDataInternal {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : _ScrollContainerDataInternal = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return _ScrollContainerDataInternal_DEFAULT;
}

// clay.h:1159 — Clay__ScrollContainerDataInternalArray_Set
_ScrollContainerDataInternalArray_Set :: (array: *_ScrollContainerDataInternalArray, index: s32, value: _ScrollContainerDataInternal) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

_ScrollContainerDataInternal_DEFAULT : _ScrollContainerDataInternal = .{ layoutElement = null };

// clay.h:1166 — Clay__DebugElementDataArray_Allocate_Arena
_DebugElementDataArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _DebugElementDataArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*_DebugElementData) _Array_Allocate_Arena(capacity, size_of(_DebugElementData), arena) };
}

// clay.h:1166 — Clay__DebugElementDataArray_Get
_DebugElementDataArray_Get :: (array: *_DebugElementDataArray, index: s32) -> *_DebugElementData {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *_DebugElementData_DEFAULT;
}

// clay.h:1166 — Clay__DebugElementDataArray_GetValue
_DebugElementDataArray_GetValue :: (array: *_DebugElementDataArray, index: s32) -> _DebugElementData {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return _DebugElementData_DEFAULT;
}

// clay.h:1166 — Clay__DebugElementDataArray_Add
_DebugElementDataArray_Add :: (array: *_DebugElementDataArray, item: _DebugElementData) -> *_DebugElementData {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *_DebugElementData_DEFAULT;
}

// clay.h:1166 — Clay__DebugElementDataArraySlice_Get
_DebugElementDataArraySlice_Get :: (slice: *_DebugElementDataArraySlice, index: s32) -> *_DebugElementData {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *_DebugElementData_DEFAULT;
}

// clay.h:1166 — Clay__DebugElementDataArray_RemoveSwapback
_DebugElementDataArray_RemoveSwapback :: (array: *_DebugElementDataArray, index: s32) -> _DebugElementData {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : _DebugElementData = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return _DebugElementData_DEFAULT;
}

// clay.h:1166 — Clay__DebugElementDataArray_Set
_DebugElementDataArray_Set :: (array: *_DebugElementDataArray, index: s32, value: _DebugElementData) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

_DebugElementData_DEFAULT : _DebugElementData = .{ collision = false };

// clay.h:1180 — Clay__LayoutElementHashMapItemArray_Allocate_Arena
_LayoutElementHashMapItemArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _LayoutElementHashMapItemArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*LayoutElementHashMapItem) _Array_Allocate_Arena(capacity, size_of(LayoutElementHashMapItem), arena) };
}

// clay.h:1180 — Clay__LayoutElementHashMapItemArray_Get
_LayoutElementHashMapItemArray_Get :: (array: *_LayoutElementHashMapItemArray, index: s32) -> *LayoutElementHashMapItem {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *LayoutElementHashMapItem_DEFAULT;
}

// clay.h:1180 — Clay__LayoutElementHashMapItemArray_GetValue
_LayoutElementHashMapItemArray_GetValue :: (array: *_LayoutElementHashMapItemArray, index: s32) -> LayoutElementHashMapItem {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return LayoutElementHashMapItem_DEFAULT;
}

// clay.h:1180 — Clay__LayoutElementHashMapItemArray_Add
_LayoutElementHashMapItemArray_Add :: (array: *_LayoutElementHashMapItemArray, item: LayoutElementHashMapItem) -> *LayoutElementHashMapItem {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *LayoutElementHashMapItem_DEFAULT;
}

// clay.h:1180 — Clay__LayoutElementHashMapItemArraySlice_Get
_LayoutElementHashMapItemArraySlice_Get :: (slice: *_LayoutElementHashMapItemArraySlice, index: s32) -> *LayoutElementHashMapItem {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *LayoutElementHashMapItem_DEFAULT;
}

// clay.h:1180 — Clay__LayoutElementHashMapItemArray_RemoveSwapback
_LayoutElementHashMapItemArray_RemoveSwapback :: (array: *_LayoutElementHashMapItemArray, index: s32) -> LayoutElementHashMapItem {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : LayoutElementHashMapItem = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return LayoutElementHashMapItem_DEFAULT;
}

// clay.h:1180 — Clay__LayoutElementHashMapItemArray_Set
_LayoutElementHashMapItemArray_Set :: (array: *_LayoutElementHashMapItemArray, index: s32, value: LayoutElementHashMapItem) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

LayoutElementHashMapItem_DEFAULT : LayoutElementHashMapItem = .{ boundingBox = .{ x = 0 } };

// clay.h:1189 — Clay__MeasuredWordArray_Allocate_Arena
_MeasuredWordArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _MeasuredWordArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*_MeasuredWord) _Array_Allocate_Arena(capacity, size_of(_MeasuredWord), arena) };
}

// clay.h:1189 — Clay__MeasuredWordArray_Get
_MeasuredWordArray_Get :: (array: *_MeasuredWordArray, index: s32) -> *_MeasuredWord {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *_MeasuredWord_DEFAULT;
}

// clay.h:1189 — Clay__MeasuredWordArray_GetValue
_MeasuredWordArray_GetValue :: (array: *_MeasuredWordArray, index: s32) -> _MeasuredWord {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return _MeasuredWord_DEFAULT;
}

// clay.h:1189 — Clay__MeasuredWordArray_Add
_MeasuredWordArray_Add :: (array: *_MeasuredWordArray, item: _MeasuredWord) -> *_MeasuredWord {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *_MeasuredWord_DEFAULT;
}

// clay.h:1189 — Clay__MeasuredWordArraySlice_Get
_MeasuredWordArraySlice_Get :: (slice: *_MeasuredWordArraySlice, index: s32) -> *_MeasuredWord {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *_MeasuredWord_DEFAULT;
}

// clay.h:1189 — Clay__MeasuredWordArray_RemoveSwapback
_MeasuredWordArray_RemoveSwapback :: (array: *_MeasuredWordArray, index: s32) -> _MeasuredWord {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : _MeasuredWord = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return _MeasuredWord_DEFAULT;
}

// clay.h:1189 — Clay__MeasuredWordArray_Set
_MeasuredWordArray_Set :: (array: *_MeasuredWordArray, index: s32, value: _MeasuredWord) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

_MeasuredWord_DEFAULT : _MeasuredWord = .{ startOffset = 0 };

// clay.h:1202 — Clay__MeasureTextCacheItemArray_Allocate_Arena
_MeasureTextCacheItemArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _MeasureTextCacheItemArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*_MeasureTextCacheItem) _Array_Allocate_Arena(capacity, size_of(_MeasureTextCacheItem), arena) };
}

// clay.h:1202 — Clay__MeasureTextCacheItemArray_Get
_MeasureTextCacheItemArray_Get :: (array: *_MeasureTextCacheItemArray, index: s32) -> *_MeasureTextCacheItem {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *_MeasureTextCacheItem_DEFAULT;
}

// clay.h:1202 — Clay__MeasureTextCacheItemArray_GetValue
_MeasureTextCacheItemArray_GetValue :: (array: *_MeasureTextCacheItemArray, index: s32) -> _MeasureTextCacheItem {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return _MeasureTextCacheItem_DEFAULT;
}

// clay.h:1202 — Clay__MeasureTextCacheItemArray_Add
_MeasureTextCacheItemArray_Add :: (array: *_MeasureTextCacheItemArray, item: _MeasureTextCacheItem) -> *_MeasureTextCacheItem {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *_MeasureTextCacheItem_DEFAULT;
}

// clay.h:1202 — Clay__MeasureTextCacheItemArraySlice_Get
_MeasureTextCacheItemArraySlice_Get :: (slice: *_MeasureTextCacheItemArraySlice, index: s32) -> *_MeasureTextCacheItem {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *_MeasureTextCacheItem_DEFAULT;
}

// clay.h:1202 — Clay__MeasureTextCacheItemArray_RemoveSwapback
_MeasureTextCacheItemArray_RemoveSwapback :: (array: *_MeasureTextCacheItemArray, index: s32) -> _MeasureTextCacheItem {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : _MeasureTextCacheItem = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return _MeasureTextCacheItem_DEFAULT;
}

// clay.h:1202 — Clay__MeasureTextCacheItemArray_Set
_MeasureTextCacheItemArray_Set :: (array: *_MeasureTextCacheItemArray, index: s32, value: _MeasureTextCacheItem) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

_MeasureTextCacheItem_DEFAULT : _MeasureTextCacheItem = .{ unwrappedDimensions = .{ width = 0 } };

// clay.h:1210 — Clay__LayoutElementTreeNodeArray_Allocate_Arena
_LayoutElementTreeNodeArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _LayoutElementTreeNodeArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*_LayoutElementTreeNode) _Array_Allocate_Arena(capacity, size_of(_LayoutElementTreeNode), arena) };
}

// clay.h:1210 — Clay__LayoutElementTreeNodeArray_Get
_LayoutElementTreeNodeArray_Get :: (array: *_LayoutElementTreeNodeArray, index: s32) -> *_LayoutElementTreeNode {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *_LayoutElementTreeNode_DEFAULT;
}

// clay.h:1210 — Clay__LayoutElementTreeNodeArray_GetValue
_LayoutElementTreeNodeArray_GetValue :: (array: *_LayoutElementTreeNodeArray, index: s32) -> _LayoutElementTreeNode {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return _LayoutElementTreeNode_DEFAULT;
}

// clay.h:1210 — Clay__LayoutElementTreeNodeArray_Add
_LayoutElementTreeNodeArray_Add :: (array: *_LayoutElementTreeNodeArray, item: _LayoutElementTreeNode) -> *_LayoutElementTreeNode {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *_LayoutElementTreeNode_DEFAULT;
}

// clay.h:1210 — Clay__LayoutElementTreeNodeArraySlice_Get
_LayoutElementTreeNodeArraySlice_Get :: (slice: *_LayoutElementTreeNodeArraySlice, index: s32) -> *_LayoutElementTreeNode {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *_LayoutElementTreeNode_DEFAULT;
}

// clay.h:1210 — Clay__LayoutElementTreeNodeArray_RemoveSwapback
_LayoutElementTreeNodeArray_RemoveSwapback :: (array: *_LayoutElementTreeNodeArray, index: s32) -> _LayoutElementTreeNode {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : _LayoutElementTreeNode = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return _LayoutElementTreeNode_DEFAULT;
}

// clay.h:1210 — Clay__LayoutElementTreeNodeArray_Set
_LayoutElementTreeNodeArray_Set :: (array: *_LayoutElementTreeNodeArray, index: s32, value: _LayoutElementTreeNode) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

_LayoutElementTreeNode_DEFAULT : _LayoutElementTreeNode = .{ layoutElement = null };

// clay.h:1220 — Clay__LayoutElementTreeRootArray_Allocate_Arena
_LayoutElementTreeRootArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _LayoutElementTreeRootArray {
	return .{ capacity = capacity, length = 0, internalArray = cast(*_LayoutElementTreeRoot) _Array_Allocate_Arena(capacity, size_of(_LayoutElementTreeRoot), arena) };
}

// clay.h:1220 — Clay__LayoutElementTreeRootArray_Get
_LayoutElementTreeRootArray_Get :: (array: *_LayoutElementTreeRootArray, index: s32) -> *_LayoutElementTreeRoot {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray + index;
	}
	return *_LayoutElementTreeRoot_DEFAULT;
}

// clay.h:1220 — Clay__LayoutElementTreeRootArray_GetValue
_LayoutElementTreeRootArray_GetValue :: (array: *_LayoutElementTreeRootArray, index: s32) -> _LayoutElementTreeRoot {
	if _Array_RangeCheck(index, array.length) {
		return array.internalArray[index];
	}
	return _LayoutElementTreeRoot_DEFAULT;
}

// clay.h:1220 — Clay__LayoutElementTreeRootArray_Add
_LayoutElementTreeRootArray_Add :: (array: *_LayoutElementTreeRootArray, item: _LayoutElementTreeRoot) -> *_LayoutElementTreeRoot {
	if _Array_AddCapacityCheck(array.length, array.capacity) {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *_LayoutElementTreeRoot_DEFAULT;
}

// clay.h:1220 — Clay__LayoutElementTreeRootArraySlice_Get
_LayoutElementTreeRootArraySlice_Get :: (slice: *_LayoutElementTreeRootArraySlice, index: s32) -> *_LayoutElementTreeRoot {
	if _Array_RangeCheck(index, slice.length) {
		return slice.internalArray + index;
	}
	return *_LayoutElementTreeRoot_DEFAULT;
}

// clay.h:1220 — Clay__LayoutElementTreeRootArray_RemoveSwapback
_LayoutElementTreeRootArray_RemoveSwapback :: (array: *_LayoutElementTreeRootArray, index: s32) -> _LayoutElementTreeRoot {
	if _Array_RangeCheck(index, array.length) {
		array.length -= 1;
		removed : _LayoutElementTreeRoot = array.internalArray[index];
		array.internalArray[index] = array.internalArray[array.length];
		return removed;
	}
	return _LayoutElementTreeRoot_DEFAULT;
}

// clay.h:1220 — Clay__LayoutElementTreeRootArray_Set
_LayoutElementTreeRootArray_Set :: (array: *_LayoutElementTreeRootArray, index: s32, value: _LayoutElementTreeRoot) {
	if _Array_RangeCheck(index, array.capacity) {
		array.internalArray[index] = value;
		// olib: array.length = ((index < array.length) ? array.length : (index + 1));
		if index + 1 > array.length { array.length = index + 1; }
	}
}

_LayoutElementTreeRoot_DEFAULT : _LayoutElementTreeRoot = .{ layoutElementIndex = 0 };
//@endregion
//@region Context 分配、元素与配置访问

// clay.h:1289 — Clay__Context_Allocate_Arena
_Context_Allocate_Arena :: (arena: *Arena) -> *Context {
	totalSizeBytes : u64 = size_of(Context);
	memoryAddress : u64 = cast(u64) arena.memory;
	// Make sure the memory address passed in for clay to use is cache line aligned
	nextAllocOffset : u64 = memoryAddress % 64;
	if nextAllocOffset + totalSizeBytes > arena.capacity {
		return null;
	}
	arena.nextAllocation = nextAllocOffset + totalSizeBytes;
	return cast(*Context) (memoryAddress + nextAllocOffset);
}

// clay.h:1297 — Clay__WriteStringToCharBuffer
_WriteStringToCharBuffer :: (buffer: *_charArray, str: String) -> String {
	i : s32 = 0;
	while i < str.length {
		buffer.internalArray[buffer.length + i] = str.chars[i];
		i += 1;
	}
	buffer.length += str.length;
	return .{ length = str.length, chars = buffer.internalArray + (buffer.length - str.length) };
}

_MeasureText : (StringSlice, *TextElementConfig, *void) -> Dimensions;

_QueryScrollOffset : (u32, *void) -> Vector2;

// clay.h:1313 — Clay__GetOpenLayoutElement
_GetOpenLayoutElement :: () -> *LayoutElement {
	ctx := GetCurrentContext();
	return LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 1));
}

// clay.h:1318 — Clay__GetParentElementId
_GetParentElementId :: () -> u32 {
	ctx := GetCurrentContext();
	return LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 2)).id;
}

// clay.h:1323 — Clay__StoreLayoutConfig
_StoreLayoutConfig :: (config: LayoutConfig) -> *LayoutConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return *CLAY_LAYOUT_DEFAULT;
	}
	return _LayoutConfigArray_Add(*ctx.layoutConfigs, config);
}

// clay.h:1324 — Clay__StoreTextElementConfig
_StoreTextElementConfig :: (config: TextElementConfig) -> *TextElementConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return *TextElementConfig_DEFAULT;
	}
	return _TextElementConfigArray_Add(*ctx.textElementConfigs, config);
}

// clay.h:1325 — Clay__StoreAspectRatioElementConfig
_StoreAspectRatioElementConfig :: (config: AspectRatioElementConfig) -> *AspectRatioElementConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return *AspectRatioElementConfig_DEFAULT;
	}
	return _AspectRatioElementConfigArray_Add(*ctx.aspectRatioElementConfigs, config);
}

// clay.h:1326 — Clay__StoreImageElementConfig
_StoreImageElementConfig :: (config: ImageElementConfig) -> *ImageElementConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return *ImageElementConfig_DEFAULT;
	}
	return _ImageElementConfigArray_Add(*ctx.imageElementConfigs, config);
}

// clay.h:1327 — Clay__StoreFloatingElementConfig
_StoreFloatingElementConfig :: (config: FloatingElementConfig) -> *FloatingElementConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return *FloatingElementConfig_DEFAULT;
	}
	return _FloatingElementConfigArray_Add(*ctx.floatingElementConfigs, config);
}

// clay.h:1328 — Clay__StoreCustomElementConfig
_StoreCustomElementConfig :: (config: CustomElementConfig) -> *CustomElementConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return *CustomElementConfig_DEFAULT;
	}
	return _CustomElementConfigArray_Add(*ctx.customElementConfigs, config);
}

// clay.h:1329 — Clay__StoreClipElementConfig
_StoreClipElementConfig :: (config: ClipElementConfig) -> *ClipElementConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return *ClipElementConfig_DEFAULT;
	}
	return _ClipElementConfigArray_Add(*ctx.clipElementConfigs, config);
}

// clay.h:1330 — Clay__StoreBorderElementConfig
_StoreBorderElementConfig :: (config: BorderElementConfig) -> *BorderElementConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return *BorderElementConfig_DEFAULT;
	}
	return _BorderElementConfigArray_Add(*ctx.borderElementConfigs, config);
}

// clay.h:1331 — Clay__StoreSharedElementConfig
_StoreSharedElementConfig :: (config: SharedElementConfig) -> *SharedElementConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return *SharedElementConfig_DEFAULT;
	}
	return _SharedElementConfigArray_Add(*ctx.sharedElementConfigs, config);
}

// clay.h:1333 — Clay__AttachElementConfig
_AttachElementConfig :: (config: ElementConfigUnion, kind: _ElementConfigType) -> ElementConfig {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return .{ type = 0 };
	}
	openLayoutElement := _GetOpenLayoutElement();
	openLayoutElement.elementConfigs.length += 1;
	new_config := _ElementConfigArray_Add(*ctx.elementConfigs, .{ type = kind, config = config });
	return new_config.*;
}

// clay.h:1343 — Clay__FindElementConfigWithType
_FindElementConfigWithType :: (element: *LayoutElement, kind: _ElementConfigType) -> ElementConfigUnion {
	i : s32 = 0;
	while i < element.elementConfigs.length {
		config := _ElementConfigArraySlice_Get(*element.elementConfigs, i);
		if config.type == kind {
			return config.config;
		}
		i += 1;
	}
	return .{ textElementConfig = null };
}
//@endregion

//@region 哈希

// clay.h:1353 — Clay__HashNumber
_HashNumber :: (offset: u32, seed: u32) -> ElementId {
	hash : u32 = seed;
	hash += offset + 48;
	hash += hash << 10;
	hash ^= hash >> 6;
	hash += hash << 3;
	hash ^= hash >> 11;
	hash += hash << 15;
	return .{ id = hash + 1, offset = offset, baseId = seed, stringId = CLAY__STRING_DEFAULT };
}

// clay.h:1365 — Clay__HashString
_HashString :: (key: String, offset: u32, seed: u32) -> ElementId {
	hash : u32 = 0;
	base : u32 = seed;
	i : s32 = 0;
	while i < key.length {
		// olib: base += u32(i8(key.chars[i])) —— 按字节符号扩展。
		// Jai 的 cast 会在运行期检查数值是否装得下（cast(s8) / cast(u32) 负数都会 panic），
		// 所以这里换成等价的算术写法：先按无符号加，再用 u32 回绕减 256 完成符号扩展。
		b : u8 = key.chars[i];
		base += cast(u32) b;
		if b >= 128 { base -= 256; }
		base += base << 10;
		base ^= base >> 6;
		i += 1;
	}
	hash = base;
	hash += offset;
	hash += hash << 10;
	hash ^= hash >> 6;
	hash += hash << 3;
	base += base << 3;
	hash ^= hash >> 11;
	base ^= base >> 11;
	hash += hash << 15;
	base += base << 15;
	return .{ id = hash + 1, offset = offset, baseId = base + 1, stringId = key };
}

// clay.h:1496 — Clay__HashData
_HashData :: (data: *u8, length: u64) -> u64 {
	hash : u64 = 0;
	i : u64 = 0;
	while i < length {
		hash += cast(u64) data[i];
		hash += hash << 10;
		hash ^= hash >> 6;
		i += 1;
	}
	return hash;
}

// clay.h:1508 — Clay__HashStringContentsWithConfig
_HashStringContentsWithConfig :: (text: *String, config: *TextElementConfig) -> u32 {
	hash : u32 = 0;
	if text.isStaticallyAllocated {
		// olib: cast(u32)(uintptr(text.chars)) —— 指针截到 32 位。
		// Jai 的 cast 会检查溢出，所以显式取低 32 位。
		hash += cast(u32) (cast(u64) text.chars & 0xFFFF_FFFF);
		hash += hash << 10;
		hash ^= hash >> 6;
		hash += cast(u32) text.length;
		hash += hash << 10;
		hash ^= hash >> 6;
	} else {
		hash = cast(u32) (_HashData(text.chars, cast(u64) text.length) % 4294967295);
	}
	hash += cast(u32) config.fontId;
	hash += hash << 10;
	hash ^= hash >> 6;
	hash += cast(u32) config.fontSize;
	hash += hash << 10;
	hash ^= hash >> 6;
	hash += cast(u32) config.letterSpacing;
	hash += hash << 10;
	hash ^= hash >> 6;
	hash += hash << 3;
	hash ^= hash >> 11;
	hash += hash << 15;
	return hash + 1;
}
//@endregion

//@region 文字测量缓存

// clay.h:1539 — Clay__AddMeasuredWord
_AddMeasuredWord :: (word: _MeasuredWord, previousWord: *_MeasuredWord) -> *_MeasuredWord {
	ctx := GetCurrentContext();
	if ctx.measuredWordsFreeList.length > 0 {
		newItemIndex : u32 = cast(u32) _int32_tArray_GetValue(*ctx.measuredWordsFreeList, ctx.measuredWordsFreeList.length - 1);
		ctx.measuredWordsFreeList.length -= 1;
		_MeasuredWordArray_Set(*ctx.measuredWords, cast(s32) newItemIndex, word);
		previousWord.next = cast(s32) newItemIndex;
		return _MeasuredWordArray_Get(*ctx.measuredWords, cast(s32) newItemIndex);
	} else {
		previousWord.next = ctx.measuredWords.length;
		return _MeasuredWordArray_Add(*ctx.measuredWords, word);
	}
}

// clay.h:1553 — Clay__MeasureTextCached
_MeasureTextCached :: (text: *String, config: *TextElementConfig) -> *_MeasureTextCacheItem {
	ctx := GetCurrentContext();
	if _MeasureText == null {
		if !ctx.booleanWarnings.textMeasurementFunctionNotSet {
			ctx.booleanWarnings.textMeasurementFunctionNotSet = true;
			ctx.errorHandler.handler(.{
				errorType = .TEXT_MEASUREMENT_FUNCTION_NOT_PROVIDED,
				errorText = _static_string("Clay's internal MeasureText function is null. You may have forgotten to call Clay_SetMeasureTextFunction(), or passed a NULL function pointer by mistake."),
				userData = ctx.errorHandler.userData,
			});
		}
		return *_MeasureTextCacheItem_DEFAULT;
	}
	id : u32 = _HashStringContentsWithConfig(text, config);
	hashBucket : u32 = id % cast(u32) (ctx.maxMeasureTextCacheWordCount / 32);
	elementIndexPrevious : s32 = 0;
	elementIndex : s32 = ctx.measureTextHashMap.internalArray[cast(s32) hashBucket];
	while elementIndex != 0 {
		hashEntry := _MeasureTextCacheItemArray_Get(*ctx.measureTextHashMapInternal, elementIndex);
		if hashEntry.id == id {
			hashEntry.generation = ctx.generation;
			return hashEntry;
		}
		// This element hasn't been seen in a few frames, delete the hash map item
		if (ctx.generation - hashEntry.generation) > 2 {
			// Add all the measured words that were included in this measurement to the freelist
			nextWordIndex : s32 = hashEntry.measuredWordsStartIndex;
			while nextWordIndex != -1 {
				measuredWord := _MeasuredWordArray_Get(*ctx.measuredWords, nextWordIndex);
				_int32_tArray_Add(*ctx.measuredWordsFreeList, nextWordIndex);
				nextWordIndex = measuredWord.next;
			}
			nextIndex : s32 = hashEntry.nextIndex;
			_MeasureTextCacheItemArray_Set(*ctx.measureTextHashMapInternal, elementIndex, .{ measuredWordsStartIndex = -1 });
			_int32_tArray_Add(*ctx.measureTextHashMapInternalFreeList, elementIndex);
			if elementIndexPrevious == 0 {
				ctx.measureTextHashMap.internalArray[cast(s32) hashBucket] = nextIndex;
			} else {
				previousHashEntry := _MeasureTextCacheItemArray_Get(*ctx.measureTextHashMapInternal, elementIndexPrevious);
				previousHashEntry.nextIndex = nextIndex;
			}
			elementIndex = nextIndex;
		} else {
			elementIndexPrevious = elementIndex;
			elementIndex = hashEntry.nextIndex;
		}
	}
	newItemIndex : s32 = 0;
	newCacheItem : _MeasureTextCacheItem = .{ measuredWordsStartIndex = -1, id = id, generation = ctx.generation };
	measured : *_MeasureTextCacheItem = null;
	if ctx.measureTextHashMapInternalFreeList.length > 0 {
		newItemIndex = _int32_tArray_GetValue(*ctx.measureTextHashMapInternalFreeList, ctx.measureTextHashMapInternalFreeList.length - 1);
		ctx.measureTextHashMapInternalFreeList.length -= 1;
		_MeasureTextCacheItemArray_Set(*ctx.measureTextHashMapInternal, newItemIndex, newCacheItem);
		measured = _MeasureTextCacheItemArray_Get(*ctx.measureTextHashMapInternal, newItemIndex);
	} else {
		if ctx.measureTextHashMapInternal.length == ctx.measureTextHashMapInternal.capacity - 1 {
			if !ctx.booleanWarnings.maxTextMeasureCacheExceeded {
				ctx.errorHandler.handler(.{
					errorType = .ELEMENTS_CAPACITY_EXCEEDED,
					errorText = _static_string("Clay ran out of capacity while attempting to measure text elements. Try using Clay_SetMaxElementCount() with a higher value."),
					userData = ctx.errorHandler.userData,
				});
				ctx.booleanWarnings.maxTextMeasureCacheExceeded = true;
			}
			return *_MeasureTextCacheItem_DEFAULT;
		}
		measured = _MeasureTextCacheItemArray_Add(*ctx.measureTextHashMapInternal, newCacheItem);
		newItemIndex = ctx.measureTextHashMapInternal.length - 1;
	}
	start : s32 = 0;
	end : s32 = 0;
	lineWidth : float = 0;
	measuredWidth : float = 0;
	measuredHeight : float = 0;
	spaceSlice : StringSlice = .{ length = 1, chars = CLAY__SPACECHAR.chars, baseChars = CLAY__SPACECHAR.chars };
	spaceWidth : float = _MeasureText(spaceSlice, config, ctx.measureTextUserData).width;
	tempWord : _MeasuredWord = .{ next = -1 };
	previousWord : *_MeasuredWord = *tempWord;
	while end < text.length {
		if ctx.measuredWords.length == ctx.measuredWords.capacity - 1 {
			if !ctx.booleanWarnings.maxTextMeasureCacheExceeded {
				ctx.errorHandler.handler(.{
					errorType = .TEXT_MEASUREMENT_CAPACITY_EXCEEDED,
					errorText = _static_string("Clay has run out of space in it's internal text measurement cache. Try using Clay_SetMaxMeasureTextCacheWordCount() (default 16384, with 1 unit storing 1 measured word)."),
					userData = ctx.errorHandler.userData,
				});
				ctx.booleanWarnings.maxTextMeasureCacheExceeded = true;
			}
			return *_MeasureTextCacheItem_DEFAULT;
		}
		current : u8 = text.chars[end];
		if cast(s32) current == 32 || cast(s32) current == 10 {
			length : s32 = end - start;
			slice : StringSlice = .{ length = length, chars = text.chars + start, baseChars = text.chars };
			dimensions : Dimensions = _MeasureText(slice, config, ctx.measureTextUserData);
			measured.minWidth = _max(dimensions.width, measured.minWidth);
			measuredHeight = _max(measuredHeight, dimensions.height);
			if cast(s32) current == 32 {
				dimensions.width += spaceWidth;
				previousWord = _AddMeasuredWord(.{ startOffset = start, length = length + 1, width = dimensions.width, next = -1 }, previousWord);
				lineWidth += dimensions.width;
			}
			if cast(s32) current == 10 {
				if length > 0 {
					previousWord = _AddMeasuredWord(.{ startOffset = start, length = length, width = dimensions.width, next = -1 }, previousWord);
				}
				previousWord = _AddMeasuredWord(.{ startOffset = end + 1, length = 0, width = 0, next = -1 }, previousWord);
				lineWidth += dimensions.width;
				measuredWidth = _max(lineWidth, measuredWidth);
				measured.containsNewlines = true;
				lineWidth = 0;
			}
			start = end + 1;
		}
		end += 1;
	}
	if end - start > 0 {
		slice : StringSlice = .{ length = end - start, chars = text.chars + start, baseChars = text.chars };
		dimensions : Dimensions = _MeasureText(slice, config, ctx.measureTextUserData);
		_AddMeasuredWord(.{ startOffset = start, length = end - start, width = dimensions.width, next = -1 }, previousWord);
		lineWidth += dimensions.width;
		measuredHeight = _max(measuredHeight, dimensions.height);
		measured.minWidth = _max(dimensions.width, measured.minWidth);
	}
	measuredWidth = _max(lineWidth, measuredWidth) - cast(float) (cast(s32) config.letterSpacing);
	measured.measuredWordsStartIndex = tempWord.next;
	measured.unwrappedDimensions.width = measuredWidth;
	measured.unwrappedDimensions.height = measuredHeight;
	if elementIndexPrevious != 0 {
		previous := _MeasureTextCacheItemArray_Get(*ctx.measureTextHashMapInternal, elementIndexPrevious);
		previous.nextIndex = newItemIndex;
	} else {
		ctx.measureTextHashMap.internalArray[cast(s32) hashBucket] = newItemIndex;
	}
	return measured;
}
//@endregion

//@region 哈希表与元素查询

// clay.h:1691 — Clay__PointIsInsideRect
_PointIsInsideRect :: (point: Vector2, rect: BoundingBox) -> bool {
	return point[0] >= rect.x && point[0] <= rect.x + rect.width && point[1] >= rect.y && point[1] <= rect.y + rect.height;
}

// clay.h:1695 — Clay__AddHashMapItem
_AddHashMapItem :: (elementId: ElementId, layoutElement: *LayoutElement, idAlias: u32) -> *LayoutElementHashMapItem {
	ctx := GetCurrentContext();
	if ctx.layoutElementsHashMapInternal.length == ctx.layoutElementsHashMapInternal.capacity - 1 {
		return null;
	}
	item : LayoutElementHashMapItem = .{ elementId = elementId, layoutElement = layoutElement, nextIndex = -1, generation = ctx.generation + 1, idAlias = idAlias };
	hashBucket : u32 = elementId.id % cast(u32) ctx.layoutElementsHashMap.capacity;
	hashItemPrevious : s32 = -1;
	hashItemIndex : s32 = ctx.layoutElementsHashMap.internalArray[cast(s32) hashBucket];
	while hashItemIndex != -1 {
		hashItem := _LayoutElementHashMapItemArray_Get(*ctx.layoutElementsHashMapInternal, hashItemIndex);
		if hashItem.elementId.id == elementId.id {
			item.nextIndex = hashItem.nextIndex;
			if hashItem.generation <= ctx.generation {
				hashItem.elementId = elementId;
				hashItem.idAlias = idAlias;
				hashItem.generation = ctx.generation + 1;
				hashItem.layoutElement = layoutElement;
				hashItem.debugData.collision = false;
				hashItem.onHoverFunction = null;
				hashItem.hoverFunctionUserData = null;
			} else {
				ctx.errorHandler.handler(.{
					errorType = .DUPLICATE_ID,
					errorText = _static_string("An element with this ID was already previously declared during this layout."),
					userData = ctx.errorHandler.userData,
				});
				if ctx.debugModeEnabled {
					hashItem.debugData.collision = true;
				}
			}
			return hashItem;
		}
		hashItemPrevious = hashItemIndex;
		hashItemIndex = hashItem.nextIndex;
	}
	hashItem := _LayoutElementHashMapItemArray_Add(*ctx.layoutElementsHashMapInternal, item);
	hashItem.debugData = _DebugElementDataArray_Add(*ctx.debugElementData, .{ collision = false });
	if hashItemPrevious != -1 {
		previous := _LayoutElementHashMapItemArray_Get(*ctx.layoutElementsHashMapInternal, hashItemPrevious);
		previous.nextIndex = ctx.layoutElementsHashMapInternal.length - 1;
	} else {
		ctx.layoutElementsHashMap.internalArray[cast(s32) hashBucket] = ctx.layoutElementsHashMapInternal.length - 1;
	}
	return hashItem;
}

// clay.h:1740 — Clay__GetHashMapItem
_GetHashMapItem :: (id: u32) -> *LayoutElementHashMapItem {
	ctx := GetCurrentContext();
	hashBucket : u32 = id % cast(u32) ctx.layoutElementsHashMap.capacity;
	elementIndex : s32 = ctx.layoutElementsHashMap.internalArray[cast(s32) hashBucket];
	while elementIndex != -1 {
		hashEntry := _LayoutElementHashMapItemArray_Get(*ctx.layoutElementsHashMapInternal, elementIndex);
		if hashEntry.elementId.id == id {
			return hashEntry;
		}
		elementIndex = hashEntry.nextIndex;
	}
	return *LayoutElementHashMapItem_DEFAULT;
}

// clay.h:1754 — Clay__GenerateIdForAnonymousElement
_GenerateIdForAnonymousElement :: (openLayoutElement: *LayoutElement) -> ElementId {
	ctx := GetCurrentContext();
	parentElement := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 2));
	elementId : ElementId = _HashNumber(cast(u32) parentElement.childrenOrTextContent.children.length, parentElement.id);
	openLayoutElement.id = elementId.id;
	_AddHashMapItem(elementId, openLayoutElement, 0);
	_StringArray_Add(*ctx.layoutElementIdStrings, elementId.stringId);
	return elementId;
}

// clay.h:1764 — Clay__ElementHasConfig
_ElementHasConfig :: (layoutElement: *LayoutElement, kind: _ElementConfigType) -> bool {
	i : s32 = 0;
	while i < layoutElement.elementConfigs.length {
		if _ElementConfigArraySlice_Get(*layoutElement.elementConfigs, i).type == kind {
			return true;
		}
		i += 1;
	}
	return false;
}
//@endregion

//@region 宽高比

// clay.h:1773 — Clay__UpdateAspectRatioBox
_UpdateAspectRatioBox :: (layoutElement: *LayoutElement) {
	j : s32 = 0;
	while j < layoutElement.elementConfigs.length {
		config := _ElementConfigArraySlice_Get(*layoutElement.elementConfigs, j);
		if config.type == CLAY__ELEMENT_CONFIG_TYPE_ASPECT {
			aspectConfig := config.config.aspectRatioElementConfig;
			if aspectConfig.aspectRatio == 0 {
				break;
			}
			if layoutElement.dimensions.width == 0 && layoutElement.dimensions.height != 0 {
				layoutElement.dimensions.width = layoutElement.dimensions.height * aspectConfig.aspectRatio;
			} else {
				if layoutElement.dimensions.width != 0 && layoutElement.dimensions.height == 0 {
					layoutElement.dimensions.height = layoutElement.dimensions.width * (cast(float) 1 / aspectConfig.aspectRatio);
				}
			}
			break;
		}
		j += 1;
	}
}
//@endregion

//@region 数值常量与调试视图配置

CLAY__EPSILON : float = 0.01;

CLAY__DEBUGVIEW_COLOR_1 : Color = .[58, 56, 52, 255];

CLAY__DEBUGVIEW_COLOR_2 : Color = .[62, 60, 58, 255];

CLAY__DEBUGVIEW_COLOR_3 : Color = .[141, 133, 135, 255];

CLAY__DEBUGVIEW_COLOR_4 : Color = .[238, 226, 231, 255];

CLAY__DEBUGVIEW_COLOR_SELECTED_ROW : Color = .[102, 80, 78, 255];

CLAY__DEBUGVIEW_ROW_HEIGHT : s32 = 30;

CLAY__DEBUGVIEW_OUTER_PADDING : s32 = 10;

CLAY__DEBUGVIEW_INDENT_WIDTH : s32 = 16;

_DebugView_TextNameConfig : TextElementConfig = .{ textColor = .[238, 226, 231, 255], fontSize = 16, wrapMode = .NONE };

_DebugView_ScrollViewItemLayoutConfig : LayoutConfig = .{ sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = 0 } } } } };

_debugViewWidth : u32 = 400;

_debugViewHighlightColor : Color = .[168, 66, 28, 100];
//@endregion

//@region 警告数组与数组检查
//
// 注意：这两个分配器与上面的类型化数组不同——它们做 64 字节向上对齐，
// 首次分配会跳过开头的 64 字节（olib/clay 的既有行为，照抄不改）。

// clay.h:3792 — Clay__WarningArray_Allocate_Arena
_WarningArray_Allocate_Arena :: (capacity: s32, arena: *Arena) -> _WarningArray {
	totalSizeBytes : u64 = cast(u64) capacity * size_of(String);
	array : _WarningArray = .{ capacity = capacity, length = 0 };
	nextAllocOffset : u64 = arena.nextAllocation + (64 - (arena.nextAllocation % 64));
	if nextAllocOffset + totalSizeBytes <= arena.capacity {
		array.internalArray = cast(*_Warning) (cast(u64) arena.memory + nextAllocOffset);
		arena.nextAllocation = nextAllocOffset + totalSizeBytes;
	} else {
		_currentContext.errorHandler.handler(.{
			errorType = .ARENA_CAPACITY_EXCEEDED,
			errorText = _static_string("Clay attempted to allocate memory in its arena, but ran out of capacity. Try increasing the capacity of the arena passed to Clay_Initialize()"),
			userData = _currentContext.errorHandler.userData,
		});
	}
	return array;
}

// clay.h:3809 — Clay__WarningArray_Add
_WarningArray_Add :: (array: *_WarningArray, item: _Warning) -> *_Warning {
	if array.length < array.capacity {
		array.internalArray[_post_inc(*array.length, 1)] = item;
		return array.internalArray + (array.length - 1);
	}
	return *CLAY__WARNING_DEFAULT;
}

// clay.h:3818 — Clay__Array_Allocate_Arena
_Array_Allocate_Arena :: (capacity: s32, itemSize: u32, arena: *Arena) -> *void {
	totalSizeBytes : u64 = cast(u64) (cast(u32) capacity * itemSize);
	nextAllocOffset : u64 = arena.nextAllocation + (64 - (arena.nextAllocation % 64));
	if nextAllocOffset + totalSizeBytes <= arena.capacity {
		arena.nextAllocation = nextAllocOffset + totalSizeBytes;
		return cast(*void) (cast(u64) arena.memory + nextAllocOffset);
	} else {
		_currentContext.errorHandler.handler(.{
			errorType = .ARENA_CAPACITY_EXCEEDED,
			errorText = _static_string("Clay attempted to allocate memory in its arena, but ran out of capacity. Try increasing the capacity of the arena passed to Clay_Initialize()"),
			userData = _currentContext.errorHandler.userData,
		});
	}
	return null;
}

// clay.h:3835 — Clay__Array_RangeCheck
_Array_RangeCheck :: (index: s32, length: s32) -> bool {
	if index < length && index >= 0 {
		return true;
	}
	ctx := GetCurrentContext();
	ctx.errorHandler.handler(.{
		errorType = .INTERNAL_ERROR,
		errorText = _static_string("Clay attempted to make an out of bounds array access. This is an internal error and is likely a bug."),
		userData = ctx.errorHandler.userData,
	});
	return false;
}

// clay.h:3848 — Clay__Array_AddCapacityCheck
_Array_AddCapacityCheck :: (length: s32, capacity: s32) -> bool {
	if length < capacity {
		return true;
	}
	ctx := GetCurrentContext();
	ctx.errorHandler.handler(.{
		errorType = .INTERNAL_ERROR,
		errorText = _static_string("Clay attempted to make an out of bounds array access. This is an internal error and is likely a bug."),
		userData = ctx.errorHandler.userData,
	});
	return false;
}
//@endregion

//@region Jai 辅助（静态字符串、C 比较与自增语义、指针偏移）

_static_string :: (text: string) -> String {
	return .{ isStaticallyAllocated = true, length = cast(s32) text.count, chars = text.data };
}

// Keep the C comparison semantics (including the second operand on equality).
_min :: (a: $T, b: T) -> T {
	if a < b {
		return a;
	}
	return b;
}

_max :: (a: $T, b: T) -> T {
	if a > b {
		return a;
	}
	return b;
}

_post_inc :: (value: *$T, delta: s64) -> T {
	old := value.*;
	value.* += cast(T) delta;
	return old;
}

_pre_inc :: (value: *$T, delta: s64) -> T {
	value.* += cast(T) delta;
	return value.*;
}

// olib 的 _offset 是 proc 重载集（^T / [^]T）。Jai 没有过程重载，而 odin 的 [^]T
// 在本移植里一律写成 *T，所以只有指针这一支需要保留。
_offset :: (value: *$T, offset: s64) -> *T {
	return value + offset;
}

// ---- 位保持的 u32 <-> s32（Jai 的 cast 有运行期溢出检查）----
//
// Clay 把 ElementId.id（u32 哈希）存进 `_int32_tArray`（s32）的
// openClipElementStack / layoutElementClipElementIds，读的时候再转回 u32。
// Odin/C 里这是**静默二补码截断**，`cast(i32)(u32)` 对任何值都成立；
// Jai 的 cast 做的是「值检查」而不是「位检查」：
//   cast(s32) 2670274195u  -> 运行期 panic "cast of 2670274195 to `s32` overflows"
//   cast(u32) (-1)         -> 运行期 panic
// 一旦某个元素同时带 clip 和「哈希 > 2^31」的 id（debug 面板的滚动面板就是），
// 原样照抄的 cast 会直接崩。
// 这两支用算术还原二补码语义，结果与 Odin 逐位一致，且所有中间值都落在目标类型的
// 合法区间内（不会触发 cast 检查）。
//
// ⚠ 只用在这类「id 借 s32 数组过一手」的地方；普通下标/长度不需要。
_s32_to_u32 :: (v: s32) -> u32 {
	if v >= 0 {
		return cast(u32) v;
	}
	return cast(u32) (0x1_0000_0000 + cast(s64) v);
}

_u32_to_s32 :: (v: u32) -> s32 {
	if v <= 0x7FFF_FFFF {
		return cast(s32) v;
	}
	return cast(s32) (cast(s64) v - 0x1_0000_0000);
}
//@endregion
