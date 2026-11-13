//
// clay_layout.jai — Clay v0.14 纯 Jai 移植（第二层：布局）
//
// 移植自 olib: D:\MySpace\Github\olib\thirdparty\clay\clay_layout.odin (1,146 行)
// 上游: nicbarker/clay v0.14 (b25a31c1a152915cd7dd6796e6592273e5a10aac)。
// Copyright (c) 2024 Nic Barker. Altered source; see LICENSE.md and README.md.
//
// 纯 Jai，不链接 C 库，无 import。依赖 clay_types.jai + clay_memory.jai（第一层）。
// 每个过程上方标注 olib 的行号（也等于 clay.h 的行号），方便逐行对拍。
//
// 语法映射（与 clay_memory.jai 一致，逐条列在这里）：
//   `for init; cond; incr`   -> `while cond`  + body 末尾手动 incr
//                              ⚠ 关键陷阱：olib 的 `continue` 会执行 incr，
//                              Jai 的 while + continue 不会。凡是 for 体内有
//                              continue 的地方都改写成 if 守卫（见各处理由）。
//   `switch`/`case:`         -> if / else-if 链，或 `if x == { case .A; … }`
//                              ⚠ 关键陷阱：olib 的 switch 里 `break` 只跳出
//                              switch；Jai 的 if-case 里 `break` 会跳出外层
//                              循环。凡是 case 体内有 break 的都改成 if 链。
//   `x ? a : b`              -> `_PickFloat` / `_PickSizingAxis` / if-else
//   `&x` -> `*x`，`x^` -> `x.*`，`[^]T` -> `*T`
//   `cast(i32)(bool)`        -> 直接用 bool（Jai 的 bool 不参与整型运算）
//   `~uint(0)`               -> `0xFFFF_FFFF_FFFF_FFFF`
//   `FLT_MAX` 字面量          -> `cast(float) 3.40282347E+38`（Jai 不允许
//                                f32 装不下的常量隐式截断，必须显式 cast）
//
// 与 olib 的有意差异（全部集中在此，代码内另有就近注释）：
//   1. `MinMemorySize`：olib 放在 clay_api.odin，按本轮要求提前放在这一层
//      （下层移植 clay_api 时不要再定义一遍）。
//   2. 文本换行里 C 的 `text.chars[lineStartOffset + lineLengthChars - 1]`
//      在「行首遇到长度 0 的词」时下标是 -1（越界读，值依赖内存布局）。
//      这里显式判 `> 0`，下标合法时逐字节等价，不合法时取 false。
//   3. `i32 sortedConfigIndexes[20]` 在 olib 里用强制指针写，Jai 用普通数组
//      下标（容量 20 远大于实际配置数 ≤ 9，越界会 panic 而不是踩栈）。
//   4. `_int32_tArray_RemoveSwapback(x, _post_inc(&i, -1))` 改写成
//      `RemoveSwapback(x, i); i -= 1;`（随后 while 末尾照常 ++，净效果一致）。
//

//@region 元素声明

// clay.h:1791 — Clay__CloseElement
_CloseElement :: () {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return;
	}
	openLayoutElement := _GetOpenLayoutElement();
	layoutConfig := openLayoutElement.layoutConfig;
	elementHasScrollHorizontal := false;
	elementHasScrollVertical := false;
	configIndex : s32 = 0;
	while configIndex < openLayoutElement.elementConfigs.length {
		config := _ElementConfigArraySlice_Get(*openLayoutElement.elementConfigs, configIndex);
		if config.type == CLAY__ELEMENT_CONFIG_TYPE_CLIP {
			elementHasScrollHorizontal = config.config.clipElementConfig.horizontal;
			elementHasScrollVertical = config.config.clipElementConfig.vertical;
			ctx.openClipElementStack.length -= 1;
			break;
		} else if config.type == CLAY__ELEMENT_CONFIG_TYPE_FLOATING {
			// 与 olib 一致：FLOATING 配置也各弹一个 openClipElementStack。
			ctx.openClipElementStack.length -= 1;
		}
		configIndex += 1;
	}
	// olib 先把 u16 padding 各自扩成 i32 再相加，这里照做（u16 直接相加会回绕）。
	leftRightPadding := cast(float) (cast(s32) layoutConfig.padding.left + cast(s32) layoutConfig.padding.right);
	topBottomPadding := cast(float) (cast(s32) layoutConfig.padding.top + cast(s32) layoutConfig.padding.bottom);
	// Attach children to the current open element
	openLayoutElement.childrenOrTextContent.children.elements = ctx.layoutElementChildren.internalArray + ctx.layoutElementChildren.length;
	if layoutConfig.layoutDirection == .LEFT_TO_RIGHT {
		openLayoutElement.dimensions.width = leftRightPadding;
		openLayoutElement.minDimensions.width = leftRightPadding;
		i : s32 = 0;
		while i < cast(s32) openLayoutElement.childrenOrTextContent.children.length {
			childIndex := _int32_tArray_GetValue(*ctx.layoutElementChildrenBuffer, (ctx.layoutElementChildrenBuffer.length - cast(s32) openLayoutElement.childrenOrTextContent.children.length) + i);
			child := LayoutElementArray_Get(*ctx.layoutElements, childIndex);
			openLayoutElement.dimensions.width += child.dimensions.width;
			openLayoutElement.dimensions.height = _max(openLayoutElement.dimensions.height, child.dimensions.height + topBottomPadding);
			// Minimum size of child elements doesn't matter to scroll containers as they can shrink and hide their contents
			if !elementHasScrollHorizontal {
				openLayoutElement.minDimensions.width += child.minDimensions.width;
			}
			if !elementHasScrollVertical {
				openLayoutElement.minDimensions.height = _max(openLayoutElement.minDimensions.height, child.minDimensions.height + topBottomPadding);
			}
			_int32_tArray_Add(*ctx.layoutElementChildren, childIndex);
			i += 1;
		}
		childGap := cast(float) (_max(cast(s32) openLayoutElement.childrenOrTextContent.children.length - 1, 0) * cast(s32) layoutConfig.childGap);
		openLayoutElement.dimensions.width += childGap;
		openLayoutElement.minDimensions.width += childGap;
	} else if layoutConfig.layoutDirection == .TOP_TO_BOTTOM {
		openLayoutElement.dimensions.height = topBottomPadding;
		openLayoutElement.minDimensions.height = topBottomPadding;
		i : s32 = 0;
		while i < cast(s32) openLayoutElement.childrenOrTextContent.children.length {
			childIndex := _int32_tArray_GetValue(*ctx.layoutElementChildrenBuffer, (ctx.layoutElementChildrenBuffer.length - cast(s32) openLayoutElement.childrenOrTextContent.children.length) + i);
			child := LayoutElementArray_Get(*ctx.layoutElements, childIndex);
			openLayoutElement.dimensions.height += child.dimensions.height;
			openLayoutElement.dimensions.width = _max(openLayoutElement.dimensions.width, child.dimensions.width + leftRightPadding);
			// Minimum size of child elements doesn't matter to scroll containers as they can shrink and hide their contents
			if !elementHasScrollVertical {
				openLayoutElement.minDimensions.height += child.minDimensions.height;
			}
			if !elementHasScrollHorizontal {
				openLayoutElement.minDimensions.width = _max(openLayoutElement.minDimensions.width, child.minDimensions.width + leftRightPadding);
			}
			_int32_tArray_Add(*ctx.layoutElementChildren, childIndex);
			i += 1;
		}
		childGap := cast(float) (_max(cast(s32) openLayoutElement.childrenOrTextContent.children.length - 1, 0) * cast(s32) layoutConfig.childGap);
		openLayoutElement.dimensions.height += childGap;
		openLayoutElement.minDimensions.height += childGap;
	}
	ctx.layoutElementChildrenBuffer.length -= cast(s32) openLayoutElement.childrenOrTextContent.children.length;
	// Clamp element min and max width to the values configured in the layout
	if layoutConfig.sizing.width.type != .PERCENT {
		if layoutConfig.sizing.width.constraints.sizeMinMax.max <= 0 {
			layoutConfig.sizing.width.constraints.sizeMinMax.max = _CLAY_MAX_FLOAT;
		}
		openLayoutElement.dimensions.width = _min(_max(openLayoutElement.dimensions.width, layoutConfig.sizing.width.constraints.sizeMinMax.min), layoutConfig.sizing.width.constraints.sizeMinMax.max);
		openLayoutElement.minDimensions.width = _min(_max(openLayoutElement.minDimensions.width, layoutConfig.sizing.width.constraints.sizeMinMax.min), layoutConfig.sizing.width.constraints.sizeMinMax.max);
	} else {
		openLayoutElement.dimensions.width = 0;
	}
	// Clamp element min and max height to the values configured in the layout
	if layoutConfig.sizing.height.type != .PERCENT {
		if layoutConfig.sizing.height.constraints.sizeMinMax.max <= 0 {
			layoutConfig.sizing.height.constraints.sizeMinMax.max = _CLAY_MAX_FLOAT;
		}
		openLayoutElement.dimensions.height = _min(_max(openLayoutElement.dimensions.height, layoutConfig.sizing.height.constraints.sizeMinMax.min), layoutConfig.sizing.height.constraints.sizeMinMax.max);
		openLayoutElement.minDimensions.height = _min(_max(openLayoutElement.minDimensions.height, layoutConfig.sizing.height.constraints.sizeMinMax.min), layoutConfig.sizing.height.constraints.sizeMinMax.max);
	} else {
		openLayoutElement.dimensions.height = 0;
	}
	_UpdateAspectRatioBox(openLayoutElement);
	elementIsFloating := _ElementHasConfig(openLayoutElement, CLAY__ELEMENT_CONFIG_TYPE_FLOATING);
	// Close the currently open element
	closingElementIndex := _int32_tArray_RemoveSwapback(*ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 1);
	openLayoutElement = _GetOpenLayoutElement();
	if !elementIsFloating && ctx.openLayoutElementStack.length > 1 {
		openLayoutElement.childrenOrTextContent.children.length += 1;
		_int32_tArray_Add(*ctx.layoutElementChildrenBuffer, closingElementIndex);
	}
}

// clay.h:1953 — Clay__MemCmp
_MemCmp :: (s1: *u8, s2: *u8, length: s32) -> bool {
	i : s32 = 0;
	while i < length {
		if s1[i] != s2[i] {
			return false;
		}
		i += 1;
	}
	return true;
}

// clay.h:1963 — Clay__OpenElement
_OpenElement :: () {
	ctx := GetCurrentContext();
	if ctx.layoutElements.length == ctx.layoutElements.capacity - 1 || ctx.booleanWarnings.maxElementsExceeded {
		ctx.booleanWarnings.maxElementsExceeded = true;
		return;
	}
	layoutElement : LayoutElement = .{ childrenOrTextContent = .{ children = .{ elements = null } } };
	LayoutElementArray_Add(*ctx.layoutElements, layoutElement);
	_int32_tArray_Add(*ctx.openLayoutElementStack, ctx.layoutElements.length - 1);
	if ctx.openClipElementStack.length > 0 {
		_int32_tArray_Set(*ctx.layoutElementClipElementIds, ctx.layoutElements.length - 1, _int32_tArray_GetValue(*ctx.openClipElementStack, ctx.openClipElementStack.length - 1));
	} else {
		_int32_tArray_Set(*ctx.layoutElementClipElementIds, ctx.layoutElements.length - 1, 0);
	}
}

// clay.h:1979 — Clay__OpenTextElement
_OpenTextElement :: (text_arg: String, textConfig: *TextElementConfig) {
	// 过程参数在 Jai 里不可变；olib 会改 text 的副本，这里先落到局部变量。
	text := text_arg;
	ctx := GetCurrentContext();
	if ctx.layoutElements.length == ctx.layoutElements.capacity - 1 || ctx.booleanWarnings.maxElementsExceeded {
		ctx.booleanWarnings.maxElementsExceeded = true;
		return;
	}
	parentElement := _GetOpenLayoutElement();
	layoutElement : LayoutElement = .{ childrenOrTextContent = .{ children = .{ elements = null } } };
	textElement := LayoutElementArray_Add(*ctx.layoutElements, layoutElement);
	if ctx.openClipElementStack.length > 0 {
		_int32_tArray_Set(*ctx.layoutElementClipElementIds, ctx.layoutElements.length - 1, _int32_tArray_GetValue(*ctx.openClipElementStack, ctx.openClipElementStack.length - 1));
	} else {
		_int32_tArray_Set(*ctx.layoutElementClipElementIds, ctx.layoutElements.length - 1, 0);
	}
	_int32_tArray_Add(*ctx.layoutElementChildrenBuffer, ctx.layoutElements.length - 1);
	textMeasured := _MeasureTextCached(*text, textConfig);
	elementId := _HashNumber(cast(u32) parentElement.childrenOrTextContent.children.length, parentElement.id);
	textElement.id = elementId.id;
	_AddHashMapItem(elementId, textElement, 0);
	_StringArray_Add(*ctx.layoutElementIdStrings, elementId.stringId);
	textDimensions : Dimensions = .{ width = textMeasured.unwrappedDimensions.width, height = textMeasured.unwrappedDimensions.height };
	if cast(s32) textConfig.lineHeight > 0 {
		textDimensions.height = cast(float) textConfig.lineHeight;
	}
	textElement.dimensions = textDimensions;
	textElement.minDimensions = .{ width = textMeasured.minWidth, height = textDimensions.height };
	textElement.childrenOrTextContent.textElementData = _TextElementDataArray_Add(*ctx.textElementData, .{
		text = text,
		preferredDimensions = textMeasured.unwrappedDimensions,
		elementIndex = ctx.layoutElements.length - 1,
	});
	textElement.elementConfigs = .{
		length = 1,
		internalArray = _ElementConfigArray_Add(*ctx.elementConfigs, .{ type = CLAY__ELEMENT_CONFIG_TYPE_TEXT, config = .{ textElementConfig = textConfig } }),
	};
	textElement.layoutConfig = *CLAY_LAYOUT_DEFAULT;
	parentElement.childrenOrTextContent.children.length += 1;
}

// clay.h:2013 — Clay__AttachId
_AttachId :: (elementId: ElementId) -> ElementId {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return ElementId_DEFAULT;
	}
	openLayoutElement := _GetOpenLayoutElement();
	idAlias := openLayoutElement.id;
	openLayoutElement.id = elementId.id;
	_AddHashMapItem(elementId, openLayoutElement, idAlias);
	_StringArray_Set(*ctx.layoutElementIdStrings, ctx.layoutElements.length - 1, elementId.stringId);
	return elementId;
}

// clay.h:2026 — Clay__ConfigureOpenElementPtr
_ConfigureOpenElementPtr :: (declaration: *ElementDeclaration) {
	ctx := GetCurrentContext();
	openLayoutElement := _GetOpenLayoutElement();
	openLayoutElement.layoutConfig = _StoreLayoutConfig(declaration.layout);
	if (declaration.layout.sizing.width.type == .PERCENT && declaration.layout.sizing.width.constraints.sizePercent > 1)
	|| (declaration.layout.sizing.height.type == .PERCENT && declaration.layout.sizing.height.constraints.sizePercent > 1) {
		ctx.errorHandler.handler(.{
			errorType = .PERCENTAGE_OVER_1,
			errorText = _static_string("An element was configured with CLAY_SIZING_PERCENT, but the provided percentage value was over 1.0. Clay expects a value between 0 and 1, i.e. 20% is 0.2."),
			userData = ctx.errorHandler.userData,
		});
	}
	openLayoutElementId := declaration.id;
	// olib: cast([^]ElementConfig)(&ctx.elementConfigs.internalArray[ctx.elementConfigs.length])
	openLayoutElement.elementConfigs.internalArray = ctx.elementConfigs.internalArray + ctx.elementConfigs.length;
	sharedConfig : *SharedElementConfig = null;
	if declaration.backgroundColor[3] > 0 {
		sharedConfig = _StoreSharedElementConfig(.{ backgroundColor = declaration.backgroundColor });
		_AttachElementConfig(.{ sharedElementConfig = sharedConfig }, CLAY__ELEMENT_CONFIG_TYPE_SHARED);
	}
	if !_MemCmp(cast(*u8) (*declaration.cornerRadius), cast(*u8) (*_CornerRadius_DEFAULT), cast(s32) size_of(CornerRadius)) {
		if sharedConfig != null {
			sharedConfig.cornerRadius = declaration.cornerRadius;
		} else {
			sharedConfig = _StoreSharedElementConfig(.{ cornerRadius = declaration.cornerRadius });
			_AttachElementConfig(.{ sharedElementConfig = sharedConfig }, CLAY__ELEMENT_CONFIG_TYPE_SHARED);
		}
	}
	if declaration.userData != null {
		if sharedConfig != null {
			sharedConfig.userData = declaration.userData;
		} else {
			sharedConfig = _StoreSharedElementConfig(.{ userData = declaration.userData });
			_AttachElementConfig(.{ sharedElementConfig = sharedConfig }, CLAY__ELEMENT_CONFIG_TYPE_SHARED);
		}
	}
	if declaration.image.imageData != null {
		_AttachElementConfig(.{ imageElementConfig = _StoreImageElementConfig(declaration.image) }, CLAY__ELEMENT_CONFIG_TYPE_IMAGE);
	}
	if declaration.aspectRatio.aspectRatio > 0 {
		_AttachElementConfig(.{ aspectRatioElementConfig = _StoreAspectRatioElementConfig(declaration.aspectRatio) }, CLAY__ELEMENT_CONFIG_TYPE_ASPECT);
		_int32_tArray_Add(*ctx.aspectRatioElementIndexes, ctx.layoutElements.length - 1);
	}
	if declaration.floating.attachTo != .NONE {
		floatingConfig := declaration.floating;
		// This looks dodgy but because of the auto generated root element the depth of the tree will always be at least 2 here
		hierarchicalParent := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 2));
		if hierarchicalParent != null {
			clipElementId : u32 = 0;
			if declaration.floating.attachTo == .PARENT {
				// Attach to the element's direct hierarchical parent
				floatingConfig.parentId = hierarchicalParent.id;
				if ctx.openClipElementStack.length > 0 {
					clipElementId = _s32_to_u32(_int32_tArray_GetValue(*ctx.openClipElementStack, ctx.openClipElementStack.length - 1));
				}
			} else if declaration.floating.attachTo == .ELEMENT_WITH_ID {
				parentItem := _GetHashMapItem(floatingConfig.parentId);
				if parentItem == *LayoutElementHashMapItem_DEFAULT {
					ctx.errorHandler.handler(.{
						errorType = .FLOATING_CONTAINER_PARENT_NOT_FOUND,
						errorText = _static_string("A floating element was declared with a parentId, but no element with that ID was found."),
						userData = ctx.errorHandler.userData,
					});
				} else {
					// olib: (i64)((uintptr)parentItem.layoutElement - (uintptr)ctx.layoutElements.internalArray) / size_of(LayoutElement)
					elementIndex := cast(s32) ((cast(u64) parentItem.layoutElement - cast(u64) ctx.layoutElements.internalArray) / cast(u64) size_of(LayoutElement));
					clipElementId = _s32_to_u32(_int32_tArray_GetValue(*ctx.layoutElementClipElementIds, elementIndex));
				}
			} else if declaration.floating.attachTo == .ROOT {
				floatingConfig.parentId = _HashString(_static_string("Clay__RootContainer"), 0, 0).id;
			}
			if openLayoutElementId.id == 0 {
				openLayoutElementId = _HashString(_static_string("Clay__FloatingContainer"), cast(u32) ctx.layoutElementTreeRoots.length, 0);
			}
			if declaration.floating.clipTo == .NONE {
				clipElementId = 0;
			}
			currentElementIndex := _int32_tArray_GetValue(*ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 1);
			_int32_tArray_Set(*ctx.layoutElementClipElementIds, currentElementIndex, _u32_to_s32(clipElementId));
			_int32_tArray_Add(*ctx.openClipElementStack, _u32_to_s32(clipElementId));
			_LayoutElementTreeRootArray_Add(*ctx.layoutElementTreeRoots, .{
				layoutElementIndex = _int32_tArray_GetValue(*ctx.openLayoutElementStack, ctx.openLayoutElementStack.length - 1),
				parentId = floatingConfig.parentId,
				clipElementId = clipElementId,
				zIndex = floatingConfig.zIndex,
			});
			_AttachElementConfig(.{ floatingElementConfig = _StoreFloatingElementConfig(floatingConfig) }, CLAY__ELEMENT_CONFIG_TYPE_FLOATING);
		}
	}
	if declaration.custom.customData != null {
		_AttachElementConfig(.{ customElementConfig = _StoreCustomElementConfig(declaration.custom) }, CLAY__ELEMENT_CONFIG_TYPE_CUSTOM);
	}
	if openLayoutElementId.id != 0 {
		_AttachId(openLayoutElementId);
	} else if openLayoutElement.id == 0 {
		openLayoutElementId = _GenerateIdForAnonymousElement(openLayoutElement);
	}
	if declaration.clip.horizontal || declaration.clip.vertical {
		_AttachElementConfig(.{ clipElementConfig = _StoreClipElementConfig(declaration.clip) }, CLAY__ELEMENT_CONFIG_TYPE_CLIP);
		_int32_tArray_Add(*ctx.openClipElementStack, _u32_to_s32(openLayoutElement.id));
		// Retrieve or create cached data to track scroll position across frames
		scrollOffset : *_ScrollContainerDataInternal = null;
		i : s32 = 0;
		while i < ctx.scrollContainerDatas.length {
			mapping := _ScrollContainerDataInternalArray_Get(*ctx.scrollContainerDatas, i);
			if openLayoutElement.id == mapping.elementId {
				scrollOffset = mapping;
				scrollOffset.layoutElement = openLayoutElement;
				scrollOffset.openThisFrame = true;
			}
			i += 1;
		}
		if scrollOffset == null {
			scrollOffset = _ScrollContainerDataInternalArray_Add(*ctx.scrollContainerDatas, .{
				layoutElement = openLayoutElement,
				scrollOrigin = .[-1, -1],
				elementId = openLayoutElement.id,
				openThisFrame = true,
			});
		}
		if ctx.externalScrollHandlingEnabled {
			scrollOffset.scrollPosition = _QueryScrollOffset(scrollOffset.elementId, ctx.queryScrollOffsetUserData);
		}
	}
	if !_MemCmp(cast(*u8) (*declaration.border.width), cast(*u8) (*_BorderWidth_DEFAULT), cast(s32) size_of(BorderWidth)) {
		_AttachElementConfig(.{ borderElementConfig = _StoreBorderElementConfig(declaration.border) }, CLAY__ELEMENT_CONFIG_TYPE_BORDER);
	}
}

// clay.h:2146 — Clay__ConfigureOpenElement
_ConfigureOpenElement :: (declaration_arg: ElementDeclaration) {
	declaration := declaration_arg;
	_ConfigureOpenElementPtr(*declaration);
}
//@endregion

//@region 内存初始化

// clay.h:2150 — Clay__InitializeEphemeralMemory
// 每帧重置的临时内存。分配顺序必须与 olib 完全一致（arena 是顺序分配的）。
_InitializeEphemeralMemory :: (ctx: *Context) {
	maxElementCount := ctx.maxElementCount;
	// Ephemeral Memory - reset every frame
	arena := *ctx.internalArena;
	arena.nextAllocation = ctx.arenaResetOffset;
	ctx.layoutElementChildrenBuffer = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.layoutElements = LayoutElementArray_Allocate_Arena(maxElementCount, arena);
	ctx.warnings = _WarningArray_Allocate_Arena(100, arena);
	ctx.layoutConfigs = _LayoutConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.elementConfigs = _ElementConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.textElementConfigs = _TextElementConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.aspectRatioElementConfigs = _AspectRatioElementConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.imageElementConfigs = _ImageElementConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.floatingElementConfigs = _FloatingElementConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.clipElementConfigs = _ClipElementConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.customElementConfigs = _CustomElementConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.borderElementConfigs = _BorderElementConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.sharedElementConfigs = _SharedElementConfigArray_Allocate_Arena(maxElementCount, arena);
	ctx.layoutElementIdStrings = _StringArray_Allocate_Arena(maxElementCount, arena);
	ctx.wrappedTextLines = _WrappedTextLineArray_Allocate_Arena(maxElementCount, arena);
	ctx.layoutElementTreeNodeArray1 = _LayoutElementTreeNodeArray_Allocate_Arena(maxElementCount, arena);
	ctx.layoutElementTreeRoots = _LayoutElementTreeRootArray_Allocate_Arena(maxElementCount, arena);
	ctx.layoutElementChildren = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.openLayoutElementStack = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.textElementData = _TextElementDataArray_Allocate_Arena(maxElementCount, arena);
	ctx.aspectRatioElementIndexes = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.renderCommands = RenderCommandArray_Allocate_Arena(maxElementCount, arena);
	ctx.treeNodeVisited = _boolArray_Allocate_Arena(maxElementCount, arena);
	ctx.treeNodeVisited.length = ctx.treeNodeVisited.capacity;
	ctx.openClipElementStack = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.reusableElementIndexBuffer = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.layoutElementClipElementIds = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.dynamicStringData = _charArray_Allocate_Arena(maxElementCount, arena);
}

// clay.h:2188 — Clay__InitializePersistentMemory
// 只初始化一次（不清零：调用方传进来的 arena 内存必须是干净的）。
_InitializePersistentMemory :: (ctx: *Context) {
	// Persistent memory - initialized once and not reset
	maxElementCount := ctx.maxElementCount;
	maxMeasureTextCacheWordCount := ctx.maxMeasureTextCacheWordCount;
	arena := *ctx.internalArena;
	ctx.scrollContainerDatas = _ScrollContainerDataInternalArray_Allocate_Arena(10, arena);
	ctx.layoutElementsHashMapInternal = _LayoutElementHashMapItemArray_Allocate_Arena(maxElementCount, arena);
	ctx.layoutElementsHashMap = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.measureTextHashMapInternal = _MeasureTextCacheItemArray_Allocate_Arena(maxElementCount, arena);
	ctx.measureTextHashMapInternalFreeList = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.measuredWordsFreeList = _int32_tArray_Allocate_Arena(maxMeasureTextCacheWordCount, arena);
	ctx.measureTextHashMap = _int32_tArray_Allocate_Arena(maxElementCount, arena);
	ctx.measuredWords = _MeasuredWordArray_Allocate_Arena(maxMeasureTextCacheWordCount, arena);
	ctx.pointerOverIds = ElementIdArray_Allocate_Arena(maxElementCount, arena);
	ctx.debugElementData = _DebugElementDataArray_Allocate_Arena(maxElementCount, arena);
	ctx.arenaResetOffset = arena.nextAllocation;
}

// clay.h:3864 — Clay_MinMemorySize
// olib 把它放在 clay_api.odin（不在 clay_layout.odin）；本层先落地，
// 移植 clay_api 时不要再定义。用于算出 Clay_Initialize 需要多大的 arena。
MinMemorySize :: () -> u32 {
	fakeContext : Context = .{
		maxElementCount = _defaultMaxElementCount,
		maxMeasureTextCacheWordCount = _defaultMaxMeasureTextWordCacheCount,
		internalArena = .{ capacity = 0xFFFF_FFFF_FFFF_FFFF, memory = null },
	};
	currentContext := GetCurrentContext();
	if currentContext != null {
		fakeContext.maxElementCount = currentContext.maxElementCount;
		fakeContext.maxMeasureTextCacheWordCount = currentContext.maxMeasureTextCacheWordCount;
	}
	// Reserve space in the arena for the context, important for calculating min memory size correctly
	_Context_Allocate_Arena(*fakeContext.internalArena);
	_InitializePersistentMemory(*fakeContext);
	_InitializeEphemeralMemory(*fakeContext);
	return cast(u32) (fakeContext.internalArena.nextAllocation + 128);
}
//@endregion

//@region 尺寸约束

// clay.h:2209 — Clay__FloatEqual
_FloatEqual :: (left: float, right: float) -> bool {
	subtracted := left - right;
	return subtracted < CLAY__EPSILON && subtracted > -CLAY__EPSILON;
}

// clay.h:2214 — Clay__SizeContainersAlongAxis
//
// 移植注记（本函数是 while 化最需要小心的地方）：
//   * olib 的 `continue`（父元素在该轴上是裁剪容器时跳过压缩）出现在
//     `for (i < bfsBuffer.length; i += 1)` 里。Jai 的 while + continue 不会
//     执行 i += 1，直接照抄会死循环 —— 这里改成 skipParent 守卫。
//   * 内层 `continue`（_FloatEqual 提前跳过）同样改写成 if 守卫。
//   * `RemoveSwapback(buf, _post_inc(&i, -1))` 改写成
//     `RemoveSwapback(buf, i); i -= 1;`，净效果与 “原地重看被换过来的元素” 一致。
_SizeContainersAlongAxis :: (xAxis: bool) {
	ctx := GetCurrentContext();
	bfsBuffer := ctx.layoutElementChildrenBuffer;
	resizableContainerBuffer := ctx.openLayoutElementStack;
	rootIndex : s32 = 0;
	while rootIndex < ctx.layoutElementTreeRoots.length {
		bfsBuffer.length = 0;
		root := _LayoutElementTreeRootArray_Get(*ctx.layoutElementTreeRoots, rootIndex);
		rootElement := LayoutElementArray_Get(*ctx.layoutElements, root.layoutElementIndex);
		_int32_tArray_Add(*bfsBuffer, root.layoutElementIndex);
		// Size floating containers to their parents
		if _ElementHasConfig(rootElement, CLAY__ELEMENT_CONFIG_TYPE_FLOATING) {
			floatingElementConfig := _FindElementConfigWithType(rootElement, CLAY__ELEMENT_CONFIG_TYPE_FLOATING).floatingElementConfig;
			parentItem := _GetHashMapItem(floatingElementConfig.parentId);
			if parentItem != null && parentItem != *LayoutElementHashMapItem_DEFAULT {
				parentLayoutElement := parentItem.layoutElement;
				if rootElement.layoutConfig.sizing.width.type == .GROW {
					rootElement.dimensions.width = parentLayoutElement.dimensions.width;
				}
				if rootElement.layoutConfig.sizing.height.type == .GROW {
					rootElement.dimensions.height = parentLayoutElement.dimensions.height;
				}
			}
		}
		rootElement.dimensions.width = _min(_max(rootElement.dimensions.width, rootElement.layoutConfig.sizing.width.constraints.sizeMinMax.min), rootElement.layoutConfig.sizing.width.constraints.sizeMinMax.max);
		rootElement.dimensions.height = _min(_max(rootElement.dimensions.height, rootElement.layoutConfig.sizing.height.constraints.sizeMinMax.min), rootElement.layoutConfig.sizing.height.constraints.sizeMinMax.max);
		bfsIndex : s32 = 0;
		while bfsIndex < bfsBuffer.length {
			parentIndex := _int32_tArray_GetValue(*bfsBuffer, bfsIndex);
			parent := LayoutElementArray_Get(*ctx.layoutElements, parentIndex);
			parentStyleConfig := parent.layoutConfig;
			growContainerCount := 0;
			parentSize := _PickFloat(xAxis, parent.dimensions.width, parent.dimensions.height);
			parentPadding := _PickFloat(
				xAxis,
				cast(float) (cast(s32) parent.layoutConfig.padding.left + cast(s32) parent.layoutConfig.padding.right),
				cast(float) (cast(s32) parent.layoutConfig.padding.top + cast(s32) parent.layoutConfig.padding.bottom));
			innerContentSize : float = 0;
			totalPaddingAndChildGaps := parentPadding;
			sizingAlongAxis := (xAxis && parentStyleConfig.layoutDirection == .LEFT_TO_RIGHT) || (!xAxis && parentStyleConfig.layoutDirection == .TOP_TO_BOTTOM);
			resizableContainerBuffer.length = 0;
			parentChildGap := cast(float) parentStyleConfig.childGap;
			childOffset : s32 = 0;
			while childOffset < cast(s32) parent.childrenOrTextContent.children.length {
				childElementIndex := parent.childrenOrTextContent.children.elements[childOffset];
				childElement := LayoutElementArray_Get(*ctx.layoutElements, childElementIndex);
				childSizing := _PickSizingAxis(xAxis, childElement.layoutConfig.sizing.width, childElement.layoutConfig.sizing.height);
				childSize := _PickFloat(xAxis, childElement.dimensions.width, childElement.dimensions.height);
				if !_ElementHasConfig(childElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT) && childElement.childrenOrTextContent.children.length > 0 {
					_int32_tArray_Add(*bfsBuffer, childElementIndex);
				}
				if childSizing.type != .PERCENT && childSizing.type != .FIXED
				&& (!_ElementHasConfig(childElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT) || _FindElementConfigWithType(childElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT).textElementConfig.wrapMode == .WORDS) {
					_int32_tArray_Add(*resizableContainerBuffer, childElementIndex);
				}
				if sizingAlongAxis {
					if childSizing.type != .PERCENT {
						innerContentSize += childSize;
					}
					if childSizing.type == .GROW {
						growContainerCount += 1;
					}
					if childOffset > 0 {
						innerContentSize += parentChildGap;
						totalPaddingAndChildGaps += parentChildGap;
					}
				} else {
					innerContentSize = _max(childSize, innerContentSize);
				}
				childOffset += 1;
			}
			// Expand percentage containers to size
			childOffset = 0;
			while childOffset < cast(s32) parent.childrenOrTextContent.children.length {
				childElementIndex := parent.childrenOrTextContent.children.elements[childOffset];
				childElement := LayoutElementArray_Get(*ctx.layoutElements, childElementIndex);
				childSizing := _PickSizingAxis(xAxis, childElement.layoutConfig.sizing.width, childElement.layoutConfig.sizing.height);
				childSizePtr := _PickFloatPtr(xAxis, *childElement.dimensions.width, *childElement.dimensions.height);
				if childSizing.type == .PERCENT {
					childSizePtr.* = (parentSize - totalPaddingAndChildGaps) * childSizing.constraints.sizePercent;
					if sizingAlongAxis {
						innerContentSize += childSizePtr.*;
					}
					_UpdateAspectRatioBox(childElement);
				}
				childOffset += 1;
			}
			if sizingAlongAxis {
				sizeToDistribute := (parentSize - parentPadding) - innerContentSize;
				// The content is too large, compress the children as much as possible
				if sizeToDistribute < 0 {
					// If the parent clips content in this axis direction, don't compress children, just leave them alone
					// olib 这里直接 `continue` 跳过整个 bfs 迭代（后面没有别的语句）。
					clipElementConfig : *ClipElementConfig = null;
					if _ElementHasConfig(parent, CLAY__ELEMENT_CONFIG_TYPE_CLIP) {
						clipElementConfig = _FindElementConfigWithType(parent, CLAY__ELEMENT_CONFIG_TYPE_CLIP).clipElementConfig;
					}
					skipParent := false;
					if clipElementConfig != null {
						if (xAxis && clipElementConfig.horizontal) || (!xAxis && clipElementConfig.vertical) {
							skipParent = true;
						}
					}
					// Scrolling containers preferentially compress before others
					while !skipParent && sizeToDistribute < -CLAY__EPSILON && resizableContainerBuffer.length > 0 {
						largest : float = 0;
						secondLargest : float = 0;
						widthToAdd := sizeToDistribute;
						childIndex : s32 = 0;
						while childIndex < resizableContainerBuffer.length {
							child := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*resizableContainerBuffer, childIndex));
							childSize := _PickFloat(xAxis, child.dimensions.width, child.dimensions.height);
							if !_FloatEqual(childSize, largest) {
								if childSize > largest {
									secondLargest = largest;
									largest = childSize;
								}
								if childSize < largest {
									secondLargest = _max(secondLargest, childSize);
									widthToAdd = secondLargest - largest;
								}
							}
							childIndex += 1;
						}
						widthToAdd = _max(widthToAdd, sizeToDistribute / cast(float) resizableContainerBuffer.length);
						childIndex = 0;
						while childIndex < resizableContainerBuffer.length {
							child := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*resizableContainerBuffer, childIndex));
							childSizePtr := _PickFloatPtr(xAxis, *child.dimensions.width, *child.dimensions.height);
							minSize := _PickFloat(xAxis, child.minDimensions.width, child.minDimensions.height);
							previousWidth := childSizePtr.*;
							if _FloatEqual(childSizePtr.*, largest) {
								childSizePtr.* += widthToAdd;
								if childSizePtr.* <= minSize {
									childSizePtr.* = minSize;
									_int32_tArray_RemoveSwapback(*resizableContainerBuffer, childIndex);
									// olib: _post_inc(&childIndex, -1) —— 重看被换过来的元素
									childIndex -= 1;
								}
								sizeToDistribute -= (childSizePtr.* - previousWidth);
							}
							childIndex += 1;
						}
					}
				} else if sizeToDistribute > 0 && growContainerCount > 0 {
					childIndex : s32 = 0;
					while childIndex < resizableContainerBuffer.length {
						child := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*resizableContainerBuffer, childIndex));
						childSizing := _PickSizingType(xAxis, child.layoutConfig.sizing.width.type, child.layoutConfig.sizing.height.type);
						if childSizing != .GROW {
							_int32_tArray_RemoveSwapback(*resizableContainerBuffer, childIndex);
							childIndex -= 1;
						}
						childIndex += 1;
					}
					while sizeToDistribute > CLAY__EPSILON && resizableContainerBuffer.length > 0 {
						smallest := _CLAY_MAX_FLOAT;
						secondSmallest := _CLAY_MAX_FLOAT;
						widthToAdd := sizeToDistribute;
						childIndex : s32 = 0;
						while childIndex < resizableContainerBuffer.length {
							child := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*resizableContainerBuffer, childIndex));
							childSize := _PickFloat(xAxis, child.dimensions.width, child.dimensions.height);
							if !_FloatEqual(childSize, smallest) {
								if childSize < smallest {
									secondSmallest = smallest;
									smallest = childSize;
								}
								if childSize > smallest {
									secondSmallest = _min(secondSmallest, childSize);
									widthToAdd = secondSmallest - smallest;
								}
							}
							childIndex += 1;
						}
						widthToAdd = _min(widthToAdd, sizeToDistribute / cast(float) resizableContainerBuffer.length);
						childIndex = 0;
						while childIndex < resizableContainerBuffer.length {
							child := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*resizableContainerBuffer, childIndex));
							childSizePtr := _PickFloatPtr(xAxis, *child.dimensions.width, *child.dimensions.height);
							maxSize := _PickFloat(xAxis, child.layoutConfig.sizing.width.constraints.sizeMinMax.max, child.layoutConfig.sizing.height.constraints.sizeMinMax.max);
							previousWidth := childSizePtr.*;
							if _FloatEqual(childSizePtr.*, smallest) {
								childSizePtr.* += widthToAdd;
								if childSizePtr.* >= maxSize {
									childSizePtr.* = maxSize;
									_int32_tArray_RemoveSwapback(*resizableContainerBuffer, childIndex);
									childIndex -= 1;
								}
								sizeToDistribute -= (childSizePtr.* - previousWidth);
							}
							childIndex += 1;
						}
					}
				}
			} else {
				childOffset = 0;
				while childOffset < resizableContainerBuffer.length {
					childElement := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*resizableContainerBuffer, childOffset));
					childSizing := _PickSizingAxis(xAxis, childElement.layoutConfig.sizing.width, childElement.layoutConfig.sizing.height);
					minSize := _PickFloat(xAxis, childElement.minDimensions.width, childElement.minDimensions.height);
					childSizePtr := _PickFloatPtr(xAxis, *childElement.dimensions.width, *childElement.dimensions.height);
					maxSize := parentSize - parentPadding;
					// If we're laying out the children of a scroll panel, grow containers expand to the size of the inner content, not the outer container
					if _ElementHasConfig(parent, CLAY__ELEMENT_CONFIG_TYPE_CLIP) {
						clipElementConfig := _FindElementConfigWithType(parent, CLAY__ELEMENT_CONFIG_TYPE_CLIP).clipElementConfig;
						if (xAxis && clipElementConfig.horizontal) || (!xAxis && clipElementConfig.vertical) {
							maxSize = _max(maxSize, innerContentSize);
						}
					}
					if childSizing.type == .GROW {
						childSizePtr.* = _min(maxSize, childSizing.constraints.sizeMinMax.max);
					}
					childSizePtr.* = _max(minSize, _min(childSizePtr.*, maxSize));
					childOffset += 1;
				}
			}
			bfsIndex += 1;
		}
		rootIndex += 1;
	}
}
//@endregion

//@region 渲染命令生成

// clay.h:2419 — Clay__IntToString
_IntToString :: (integer_arg: s32) -> String {
	integer := integer_arg;
	if integer == 0 {
		return .{ length = 1, chars = "0".data };
	}
	ctx := GetCurrentContext();
	chars := ctx.dynamicStringData.internalArray + ctx.dynamicStringData.length;
	length : s32 = 0;
	sign := integer;
	if integer < 0 {
		integer = -integer;
	}
	while integer > 0 {
		chars[_post_inc(*length, 1)] = cast(u8) ((integer % 10) + 48);
		integer /= 10;
	}
	if sign < 0 {
		chars[_post_inc(*length, 1)] = 45;
	}
	// Reverse the string to get the correct order
	{
		j : s32 = 0;
		k := length - 1;
		while j < k {
			temp := chars[j];
			chars[j] = chars[k];
			chars[k] = temp;
			j += 1;
			k -= 1;
		}
	}
	ctx.dynamicStringData.length += length;
	return .{ length = length, chars = chars };
}

// clay.h:2450 — Clay__AddRenderCommand
_AddRenderCommand :: (renderCommand: RenderCommand) {
	ctx := GetCurrentContext();
	if ctx.renderCommands.length < ctx.renderCommands.capacity - 1 {
		RenderCommandArray_Add(*ctx.renderCommands, renderCommand);
	} else if !ctx.booleanWarnings.maxRenderCommandsExceeded {
		ctx.booleanWarnings.maxRenderCommandsExceeded = true;
		ctx.errorHandler.handler(.{
			errorType = .ELEMENTS_CAPACITY_EXCEEDED,
			errorText = _static_string("Clay ran out of capacity while attempting to create render commands. This is usually caused by a large amount of wrapping text elements while close to the max element capacity. Try using Clay_SetMaxElementCount() with a higher value."),
			userData = ctx.errorHandler.userData,
		});
	}
}

// clay.h:2465 — Clay__ElementIsOffscreen
_ElementIsOffscreen :: (boundingBox: *BoundingBox) -> bool {
	ctx := GetCurrentContext();
	if ctx.disableCulling {
		return false;
	}
	return boundingBox.x > ctx.layoutDimensions.width
		|| boundingBox.y > ctx.layoutDimensions.height
		|| (boundingBox.x + boundingBox.width) < 0
		|| (boundingBox.y + boundingBox.height) < 0;
}

// clay.h:2477 — Clay__CalculateFinalLayout
//
// 移植注记：
//   * 文本换行外层 for 的 `continue`（单行直接命中）改成 else 分支 —— 否则
//     while + continue 会跳过 textElementIndex += 1 死循环。
//   * 渲染命令的 switch 改成 if/else-if 链（case 里的 break 只跳出 switch，
//     而 if-case 的 break 会跳出当前 while 循环）。
_CalculateFinalLayout :: () {
	ctx := GetCurrentContext();
	// Calculate sizing along the X axis
	_SizeContainersAlongAxis(true);

	// Wrap text
	textElementIndex : s32 = 0;
	while textElementIndex < ctx.textElementData.length {
		textElementData := _TextElementDataArray_Get(*ctx.textElementData, textElementIndex);
		textElementData.wrappedLines = .{ length = 0, internalArray = ctx.wrappedTextLines.internalArray + ctx.wrappedTextLines.length };
		containerElement := LayoutElementArray_Get(*ctx.layoutElements, textElementData.elementIndex);
		textConfig := _FindElementConfigWithType(containerElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT).textElementConfig;
		measureTextCacheItem := _MeasureTextCached(*textElementData.text, textConfig);
		lineWidth : float = 0;
		lineHeight := textElementData.preferredDimensions.height;
		if cast(s32) textConfig.lineHeight > 0 {
			lineHeight = cast(float) textConfig.lineHeight;
		}
		lineLengthChars : s32 = 0;
		lineStartOffset : s32 = 0;
		if !measureTextCacheItem.containsNewlines && textElementData.preferredDimensions.width <= containerElement.dimensions.width {
			// 单行，直接落一整行（olib 这里是 continue 掉整个循环体剩下的部分，
			// 注意它同时跳过了最后的 dimensions.height 赋值）。
			_WrappedTextLineArray_Add(*ctx.wrappedTextLines, .{ dimensions = containerElement.dimensions, line = textElementData.text });
			textElementData.wrappedLines.length += 1;
		} else {
			spaceWidth := _MeasureText(.{ length = 1, chars = CLAY__SPACECHAR.chars, baseChars = CLAY__SPACECHAR.chars }, textConfig, ctx.measureTextUserData).width;
			wordIndex := measureTextCacheItem.measuredWordsStartIndex;
			while wordIndex != -1 {
				if ctx.wrappedTextLines.length > ctx.wrappedTextLines.capacity - 1 {
					break;
				}
				measuredWord := _MeasuredWordArray_Get(*ctx.measuredWords, wordIndex);
				// Only word on the line is too large, just render it anyway
				if lineLengthChars == 0 && (lineWidth + measuredWord.width) > containerElement.dimensions.width {
					_WrappedTextLineArray_Add(*ctx.wrappedTextLines, .{
						dimensions = .{ width = measuredWord.width, height = lineHeight },
						line = .{ length = measuredWord.length, chars = textElementData.text.chars + measuredWord.startOffset },
					});
					textElementData.wrappedLines.length += 1;
					wordIndex = measuredWord.next;
					lineStartOffset = measuredWord.startOffset + measuredWord.length;
				} else if measuredWord.length == 0 || (lineWidth + measuredWord.width) > containerElement.dimensions.width {
					// 差异点 2：C 在这里会读 text.chars[lineStartOffset + lineLengthChars - 1]，
					// 当 lineLengthChars == 0（行首就是长度 0 换行词）时下标为 -1，是越界读。
					// 显式判 > 0；下标合法时与 olib 逐字节等价，越界时取 false（确定性）。
					finalCharIsSpace := false;
					if (lineStartOffset + lineLengthChars) > 0 {
						finalCharIsSpace = cast(s32) textElementData.text.chars[(lineStartOffset + lineLengthChars) - 1] == 32;
					}
					wrappedWidth := lineWidth;
					wrappedLength := lineLengthChars;
					if finalCharIsSpace {
						wrappedWidth -= spaceWidth;
						wrappedLength -= 1;
					}
					_WrappedTextLineArray_Add(*ctx.wrappedTextLines, .{
						dimensions = .{ width = wrappedWidth, height = lineHeight },
						line = .{ length = wrappedLength, chars = textElementData.text.chars + lineStartOffset },
					});
					textElementData.wrappedLines.length += 1;
					if lineLengthChars == 0 || measuredWord.length == 0 {
						wordIndex = measuredWord.next;
					}
					lineWidth = 0;
					lineLengthChars = 0;
					lineStartOffset = measuredWord.startOffset;
				} else {
					lineWidth += measuredWord.width + cast(float) (cast(s32) textConfig.letterSpacing);
					lineLengthChars += measuredWord.length;
					wordIndex = measuredWord.next;
				}
			}
			if lineLengthChars > 0 {
				_WrappedTextLineArray_Add(*ctx.wrappedTextLines, .{
					dimensions = .{ width = lineWidth - cast(float) (cast(s32) textConfig.letterSpacing), height = lineHeight },
					line = .{ length = lineLengthChars, chars = textElementData.text.chars + lineStartOffset },
				});
				textElementData.wrappedLines.length += 1;
			}
			containerElement.dimensions.height = lineHeight * cast(float) textElementData.wrappedLines.length;
		}
		textElementIndex += 1;
	}

	// Scale vertical heights according to aspect ratio
	aspectIndex : s32 = 0;
	while aspectIndex < ctx.aspectRatioElementIndexes.length {
		aspectElement := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*ctx.aspectRatioElementIndexes, aspectIndex));
		config := _FindElementConfigWithType(aspectElement, CLAY__ELEMENT_CONFIG_TYPE_ASPECT).aspectRatioElementConfig;
		aspectElement.dimensions.height = (cast(float) 1 / config.aspectRatio) * aspectElement.dimensions.width;
		aspectElement.layoutConfig.sizing.height.constraints.sizeMinMax.max = aspectElement.dimensions.height;
		aspectIndex += 1;
	}

	// Propagate effect of text wrapping, aspect scaling etc. on height of parents
	dfsBuffer := ctx.layoutElementTreeNodeArray1;
	dfsBuffer.length = 0;
	i : s32 = 0;
	while i < ctx.layoutElementTreeRoots.length {
		root := _LayoutElementTreeRootArray_Get(*ctx.layoutElementTreeRoots, i);
		ctx.treeNodeVisited.internalArray[dfsBuffer.length] = false;
		_LayoutElementTreeNodeArray_Add(*dfsBuffer, .{ layoutElement = LayoutElementArray_Get(*ctx.layoutElements, root.layoutElementIndex) });
		i += 1;
	}
	while dfsBuffer.length > 0 {
		currentElementTreeNode := _LayoutElementTreeNodeArray_Get(*dfsBuffer, dfsBuffer.length - 1);
		currentElement := currentElementTreeNode.layoutElement;
		if !ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] {
			ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = true;
			// If the element has no children or is the container for a text element, don't bother inspecting it
			if _ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT) || currentElement.childrenOrTextContent.children.length == 0 {
				dfsBuffer.length -= 1;
				continue;
			}
			// Add the children to the DFS buffer (needs to be pushed in reverse so that stack traversal is in correct layout order)
			i = 0;
			while i < cast(s32) currentElement.childrenOrTextContent.children.length {
				ctx.treeNodeVisited.internalArray[dfsBuffer.length] = false;
				_LayoutElementTreeNodeArray_Add(*dfsBuffer, .{ layoutElement = LayoutElementArray_Get(*ctx.layoutElements, currentElement.childrenOrTextContent.children.elements[i]) });
				i += 1;
			}
			continue;
		}
		dfsBuffer.length -= 1;
		// DFS node has been visited, this is on the way back up to the root
		layoutConfig := currentElement.layoutConfig;
		if layoutConfig.layoutDirection == .LEFT_TO_RIGHT {
			// Resize any parent containers that have grown in height along their non layout axis
			j : s32 = 0;
			while j < cast(s32) currentElement.childrenOrTextContent.children.length {
				childElement := LayoutElementArray_Get(*ctx.layoutElements, currentElement.childrenOrTextContent.children.elements[j]);
				childHeightWithPadding := _max(
					(childElement.dimensions.height + cast(float) (cast(s32) layoutConfig.padding.top)) + cast(float) (cast(s32) layoutConfig.padding.bottom),
					currentElement.dimensions.height);
				currentElement.dimensions.height = _min(_max(childHeightWithPadding, layoutConfig.sizing.height.constraints.sizeMinMax.min), layoutConfig.sizing.height.constraints.sizeMinMax.max);
				j += 1;
			}
		} else if layoutConfig.layoutDirection == .TOP_TO_BOTTOM {
			// Resizing along the layout axis
			contentHeight := cast(float) (cast(s32) layoutConfig.padding.top + cast(s32) layoutConfig.padding.bottom);
			j : s32 = 0;
			while j < cast(s32) currentElement.childrenOrTextContent.children.length {
				childElement := LayoutElementArray_Get(*ctx.layoutElements, currentElement.childrenOrTextContent.children.elements[j]);
				contentHeight += childElement.dimensions.height;
				j += 1;
			}
			contentHeight += cast(float) (_max(cast(s32) currentElement.childrenOrTextContent.children.length - 1, 0) * cast(s32) layoutConfig.childGap);
			currentElement.dimensions.height = _min(_max(contentHeight, layoutConfig.sizing.height.constraints.sizeMinMax.min), layoutConfig.sizing.height.constraints.sizeMinMax.max);
		}
	}

	// Calculate sizing along the Y axis
	_SizeContainersAlongAxis(false);

	// Scale horizontal widths according to aspect ratio
	aspectIndex = 0;
	while aspectIndex < ctx.aspectRatioElementIndexes.length {
		aspectElement := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*ctx.aspectRatioElementIndexes, aspectIndex));
		config := _FindElementConfigWithType(aspectElement, CLAY__ELEMENT_CONFIG_TYPE_ASPECT).aspectRatioElementConfig;
		aspectElement.dimensions.width = config.aspectRatio * aspectElement.dimensions.height;
		aspectIndex += 1;
	}

	// Sort tree roots by z-index
	sortMax := ctx.layoutElementTreeRoots.length - 1;
	while sortMax > 0 {
		i = 0;
		while i < sortMax {
			current := _LayoutElementTreeRootArray_Get(*ctx.layoutElementTreeRoots, i).*;
			next := _LayoutElementTreeRootArray_Get(*ctx.layoutElementTreeRoots, i + 1).*;
			if next.zIndex < current.zIndex {
				_LayoutElementTreeRootArray_Set(*ctx.layoutElementTreeRoots, i, next);
				_LayoutElementTreeRootArray_Set(*ctx.layoutElementTreeRoots, i + 1, current);
			}
			i += 1;
		}
		sortMax -= 1;
	}

	// Calculate final positions and generate render commands
	ctx.renderCommands.length = 0;
	dfsBuffer.length = 0;
	rootIndex : s32 = 0;
	while rootIndex < ctx.layoutElementTreeRoots.length {
		dfsBuffer.length = 0;
		root := _LayoutElementTreeRootArray_Get(*ctx.layoutElementTreeRoots, rootIndex);
		rootElement := LayoutElementArray_Get(*ctx.layoutElements, root.layoutElementIndex);
		rootPosition : Vector2 = .[0, 0];
		parentHashMapItem := _GetHashMapItem(root.parentId);
		// Position root floating containers
		if _ElementHasConfig(rootElement, CLAY__ELEMENT_CONFIG_TYPE_FLOATING) && parentHashMapItem != null {
			config := _FindElementConfigWithType(rootElement, CLAY__ELEMENT_CONFIG_TYPE_FLOATING).floatingElementConfig;
			rootDimensions := rootElement.dimensions;
			parentBoundingBox := parentHashMapItem.boundingBox;
			// Set X position
			targetAttachPosition : Vector2 = .[0, 0];
			// ⚠ Jai 的 `if x == { case …; }` **不支持**逗号分隔的多个值
			//   （`case .A, .B;` 会得到 "'%' expected"），只能一个 case 一个值。
			//   这里展开成等价的 if / else-if 链；未命中时 targetAttachPosition 保持 0，
			//   与原 if-case（无默认 case）行为一致。
			if config.attachment.parent == .LEFT_TOP || config.attachment.parent == .LEFT_CENTER || config.attachment.parent == .LEFT_BOTTOM {
				targetAttachPosition[0] = parentBoundingBox.x;
			} else if config.attachment.parent == .CENTER_TOP || config.attachment.parent == .CENTER_CENTER || config.attachment.parent == .CENTER_BOTTOM {
				targetAttachPosition[0] = parentBoundingBox.x + (parentBoundingBox.width / 2);
			} else if config.attachment.parent == .RIGHT_TOP || config.attachment.parent == .RIGHT_CENTER || config.attachment.parent == .RIGHT_BOTTOM {
				targetAttachPosition[0] = parentBoundingBox.x + parentBoundingBox.width;
			}
			if config.attachment.element == .LEFT_TOP || config.attachment.element == .LEFT_CENTER || config.attachment.element == .LEFT_BOTTOM {
				// 左边缘对齐，无偏移
			} else if config.attachment.element == .CENTER_TOP || config.attachment.element == .CENTER_CENTER || config.attachment.element == .CENTER_BOTTOM {
				targetAttachPosition[0] -= (rootDimensions.width / 2);
			} else if config.attachment.element == .RIGHT_TOP || config.attachment.element == .RIGHT_CENTER || config.attachment.element == .RIGHT_BOTTOM {
				targetAttachPosition[0] -= rootDimensions.width;
			}
			if config.attachment.parent == .LEFT_TOP || config.attachment.parent == .RIGHT_TOP || config.attachment.parent == .CENTER_TOP {
				targetAttachPosition[1] = parentBoundingBox.y;
			} else if config.attachment.parent == .LEFT_CENTER || config.attachment.parent == .CENTER_CENTER || config.attachment.parent == .RIGHT_CENTER {
				targetAttachPosition[1] = parentBoundingBox.y + (parentBoundingBox.height / 2);
			} else if config.attachment.parent == .LEFT_BOTTOM || config.attachment.parent == .CENTER_BOTTOM || config.attachment.parent == .RIGHT_BOTTOM {
				targetAttachPosition[1] = parentBoundingBox.y + parentBoundingBox.height;
			}
			if config.attachment.element == .LEFT_TOP || config.attachment.element == .RIGHT_TOP || config.attachment.element == .CENTER_TOP {
				// 上边缘对齐，无偏移
			} else if config.attachment.element == .LEFT_CENTER || config.attachment.element == .CENTER_CENTER || config.attachment.element == .RIGHT_CENTER {
				targetAttachPosition[1] -= (rootDimensions.height / 2);
			} else if config.attachment.element == .LEFT_BOTTOM || config.attachment.element == .CENTER_BOTTOM || config.attachment.element == .RIGHT_BOTTOM {
				targetAttachPosition[1] -= rootDimensions.height;
			}
			targetAttachPosition[0] += config.offset[0];
			targetAttachPosition[1] += config.offset[1];
			rootPosition = targetAttachPosition;
		}
		if root.clipElementId != 0 {
			clipHashMapItem := _GetHashMapItem(root.clipElementId);
			if clipHashMapItem != null {
				// Floating elements that are attached to scrolling contents won't be correctly positioned if external scroll handling is enabled, fix here
				if ctx.externalScrollHandlingEnabled {
					clipConfig := _FindElementConfigWithType(clipHashMapItem.layoutElement, CLAY__ELEMENT_CONFIG_TYPE_CLIP).clipElementConfig;
					if clipConfig.horizontal {
						rootPosition[0] += clipConfig.childOffset[0];
					}
					if clipConfig.vertical {
						rootPosition[1] += clipConfig.childOffset[1];
					}
					// 与 olib/C 逐字一致：这里的 break 跳出的是外层 root 循环（上游即如此），
					// 不是只退出这个 if —— 只有开了 externalScrollHandling 才会走到。
					break;
				}
				_AddRenderCommand(.{
					elementId = root.clipElementId,
					boundingBox = clipHashMapItem.boundingBox,
					userData = null,
					id = _HashNumber(rootElement.id, cast(u32) (cast(s32) rootElement.childrenOrTextContent.children.length + 10)).id,
					zIndex = root.zIndex,
					commandType = .SCISSOR_START,
				});
			}
		}
		_LayoutElementTreeNodeArray_Add(*dfsBuffer, .{
			layoutElement = rootElement,
			position = rootPosition,
			nextChildOffset = .[cast(float) rootElement.layoutConfig.padding.left, cast(float) rootElement.layoutConfig.padding.top],
		});
		ctx.treeNodeVisited.internalArray[0] = false;
		while dfsBuffer.length > 0 {
			currentElementTreeNode := _LayoutElementTreeNodeArray_Get(*dfsBuffer, dfsBuffer.length - 1);
			currentElement := currentElementTreeNode.layoutElement;
			layoutConfig := currentElement.layoutConfig;
			scrollOffset : Vector2 = .[0, 0];
			// This will only be run a single time for each element in downwards DFS order
			if !ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] {
				ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = true;
				currentElementBoundingBox : BoundingBox = .{
					x = currentElementTreeNode.position[0],
					y = currentElementTreeNode.position[1],
					width = currentElement.dimensions.width,
					height = currentElement.dimensions.height,
				};
				if _ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_FLOATING) {
					floatingElementConfig := _FindElementConfigWithType(currentElement, CLAY__ELEMENT_CONFIG_TYPE_FLOATING).floatingElementConfig;
					expand := floatingElementConfig.expand;
					currentElementBoundingBox.x -= expand.width;
					currentElementBoundingBox.width += (expand.width * 2);
					currentElementBoundingBox.y -= expand.height;
					currentElementBoundingBox.height += (expand.height * 2);
				}
				scrollContainerData : *_ScrollContainerDataInternal = null;
				// Apply scroll offsets to container
				if _ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_CLIP) {
					clipConfig := _FindElementConfigWithType(currentElement, CLAY__ELEMENT_CONFIG_TYPE_CLIP).clipElementConfig;
					// This linear scan could theoretically be slow under very strange conditions, but I can't imagine a real UI with more than a few 10's of scroll containers
					scrollIndex : s32 = 0;
					while scrollIndex < ctx.scrollContainerDatas.length {
						mapping := _ScrollContainerDataInternalArray_Get(*ctx.scrollContainerDatas, scrollIndex);
						if mapping.layoutElement == currentElement {
							scrollContainerData = mapping;
							mapping.boundingBox = currentElementBoundingBox;
							scrollOffset = clipConfig.childOffset;
							if ctx.externalScrollHandlingEnabled {
								scrollOffset = .[0, 0];
							}
							break;
						}
						scrollIndex += 1;
					}
				}
				hashMapItem := _GetHashMapItem(currentElement.id);
				if hashMapItem != null {
					hashMapItem.boundingBox = currentElementBoundingBox;
					if hashMapItem.idAlias != 0 {
						hashMapItemAlias := _GetHashMapItem(hashMapItem.idAlias);
						if hashMapItemAlias != null {
							hashMapItemAlias.boundingBox = currentElementBoundingBox;
						}
					}
				}
				// 差异点 3：olib 用 `[20]i32` + 强制指针写（越界会踩栈），这里用普通数组下标。
				sortedConfigIndexes : [20] s32;
				elementConfigIndex : s32 = 0;
				while elementConfigIndex < currentElement.elementConfigs.length {
					sortedConfigIndexes[elementConfigIndex] = elementConfigIndex;
					elementConfigIndex += 1;
				}
				sortMax = currentElement.elementConfigs.length - 1;
				while sortMax > 0 {
					i = 0;
					while i < sortMax {
						currentConfigIndex := sortedConfigIndexes[i];
						nextConfigIndex := sortedConfigIndexes[i + 1];
						currentType := _ElementConfigArraySlice_Get(*currentElement.elementConfigs, currentConfigIndex).type;
						nextType := _ElementConfigArraySlice_Get(*currentElement.elementConfigs, nextConfigIndex).type;
						if nextType == CLAY__ELEMENT_CONFIG_TYPE_CLIP || currentType == CLAY__ELEMENT_CONFIG_TYPE_BORDER {
							sortedConfigIndexes[i] = nextConfigIndex;
							sortedConfigIndexes[i + 1] = currentConfigIndex;
						}
						i += 1;
					}
					sortMax -= 1;
				}
				emitRectangle := false;
				// Create the render commands for this element
				sharedConfig : *SharedElementConfig = _FindElementConfigWithType(currentElement, CLAY__ELEMENT_CONFIG_TYPE_SHARED).sharedElementConfig;
				if sharedConfig != null && sharedConfig.backgroundColor[3] > 0 {
					emitRectangle = true;
				} else if sharedConfig == null {
					emitRectangle = false;
					sharedConfig = *SharedElementConfig_DEFAULT;
				}
				elementConfigIndex = 0;
				while elementConfigIndex < currentElement.elementConfigs.length {
					elementConfig := _ElementConfigArraySlice_Get(*currentElement.elementConfigs, sortedConfigIndexes[elementConfigIndex]);
					renderCommand : RenderCommand = .{
						elementId = currentElement.id,
						boundingBox = currentElementBoundingBox,
						userData = sharedConfig.userData,
						id = currentElement.id,
					};
					offscreen := _ElementIsOffscreen(*currentElementBoundingBox);
					shouldRender := !offscreen;
					// olib: switch (elementConfig.type) —— case 里的 break 只跳出 switch，
					// 所以这里必须用 if 链 + 嵌套守卫，不能照抄成 if-case + break。
					if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_ASPECT
					|| elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_FLOATING
					|| elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_SHARED
					|| elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_BORDER {
						shouldRender = false;
					} else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_CLIP {
						renderCommand.commandType = .SCISSOR_START;
						renderCommand.renderData = .{ clip = .{
							horizontal = elementConfig.config.clipElementConfig.horizontal,
							vertical = elementConfig.config.clipElementConfig.vertical,
						} };
					} else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_IMAGE {
						renderCommand.commandType = .IMAGE;
						renderCommand.renderData = .{ image = .{
							backgroundColor = sharedConfig.backgroundColor,
							cornerRadius = sharedConfig.cornerRadius,
							imageData = elementConfig.config.imageElementConfig.imageData,
						} };
						emitRectangle = false;
					} else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_TEXT {
						if shouldRender {
							shouldRender = false;
							configUnion := elementConfig.config;
							textElementConfig := configUnion.textElementConfig;
							naturalLineHeight := currentElement.childrenOrTextContent.textElementData.preferredDimensions.height;
							finalLineHeight := naturalLineHeight;
							if cast(s32) textElementConfig.lineHeight > 0 {
								finalLineHeight = cast(float) textElementConfig.lineHeight;
							}
							lineHeightOffset := (finalLineHeight - naturalLineHeight) / 2;
							yPosition := lineHeightOffset;
							lineIndex : s32 = 0;
							while lineIndex < currentElement.childrenOrTextContent.textElementData.wrappedLines.length {
								wrappedLine := _WrappedTextLineArraySlice_Get(*currentElement.childrenOrTextContent.textElementData.wrappedLines, lineIndex);
								if wrappedLine.line.length == 0 {
									yPosition += finalLineHeight;
								} else {
									offset := currentElementBoundingBox.width - wrappedLine.dimensions.width;
									if textElementConfig.textAlignment == .LEFT {
										offset = 0;
									}
									if textElementConfig.textAlignment == .CENTER {
										offset /= 2;
									}
									_AddRenderCommand(.{
										elementId = currentElement.id,
										boundingBox = .{
											x = currentElementBoundingBox.x + offset,
											y = currentElementBoundingBox.y + yPosition,
											width = wrappedLine.dimensions.width,
											height = wrappedLine.dimensions.height,
										},
										renderData = .{ text = .{
											stringContents = .{
												length = wrappedLine.line.length,
												chars = wrappedLine.line.chars,
												baseChars = currentElement.childrenOrTextContent.textElementData.text.chars,
											},
											textColor = textElementConfig.textColor,
											fontId = textElementConfig.fontId,
											fontSize = textElementConfig.fontSize,
											letterSpacing = textElementConfig.letterSpacing,
											lineHeight = textElementConfig.lineHeight,
										} },
										userData = textElementConfig.userData,
										id = _HashNumber(cast(u32) lineIndex, currentElement.id).id,
										zIndex = root.zIndex,
										commandType = .TEXT,
									});
									yPosition += finalLineHeight;
									if !ctx.disableCulling && (currentElementBoundingBox.y + yPosition) > ctx.layoutDimensions.height {
										break;
									}
								}
								lineIndex += 1;
							}
						}
					} else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_CUSTOM {
						renderCommand.commandType = .CUSTOM;
						renderCommand.renderData = .{ custom = .{
							backgroundColor = sharedConfig.backgroundColor,
							cornerRadius = sharedConfig.cornerRadius,
							customData = elementConfig.config.customElementConfig.customData,
						} };
						emitRectangle = false;
					}
					if shouldRender {
						_AddRenderCommand(renderCommand);
					}
					elementConfigIndex += 1;
				}
				if emitRectangle {
					_AddRenderCommand(.{
						elementId = currentElement.id,
						boundingBox = currentElementBoundingBox,
						renderData = .{ rectangle = .{
							backgroundColor = sharedConfig.backgroundColor,
							cornerRadius = sharedConfig.cornerRadius,
						} },
						userData = sharedConfig.userData,
						id = currentElement.id,
						zIndex = root.zIndex,
						commandType = .RECTANGLE,
					});
				}
				// Setup initial on-axis alignment
				if !_ElementHasConfig(currentElementTreeNode.layoutElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT) {
					contentSize : Dimensions = .{ width = 0, height = 0 };
					if layoutConfig.layoutDirection == .LEFT_TO_RIGHT {
						childIndex : s32 = 0;
						while childIndex < cast(s32) currentElement.childrenOrTextContent.children.length {
							childElement := LayoutElementArray_Get(*ctx.layoutElements, currentElement.childrenOrTextContent.children.elements[childIndex]);
							contentSize.width += childElement.dimensions.width;
							contentSize.height = _max(contentSize.height, childElement.dimensions.height);
							childIndex += 1;
						}
						contentSize.width += cast(float) (_max(cast(s32) currentElement.childrenOrTextContent.children.length - 1, 0) * cast(s32) layoutConfig.childGap);
						extraSpace := (currentElement.dimensions.width - cast(float) (cast(s32) layoutConfig.padding.left + cast(s32) layoutConfig.padding.right)) - contentSize.width;
						if layoutConfig.childAlignment.x == .LEFT {
							extraSpace = 0;
						} else if layoutConfig.childAlignment.x == .CENTER {
							extraSpace /= 2;
						}
						currentElementTreeNode.nextChildOffset[0] += extraSpace;
					} else {
						childIndex : s32 = 0;
						while childIndex < cast(s32) currentElement.childrenOrTextContent.children.length {
							childElement := LayoutElementArray_Get(*ctx.layoutElements, currentElement.childrenOrTextContent.children.elements[childIndex]);
							contentSize.width = _max(contentSize.width, childElement.dimensions.width);
							contentSize.height += childElement.dimensions.height;
							childIndex += 1;
						}
						contentSize.height += cast(float) (_max(cast(s32) currentElement.childrenOrTextContent.children.length - 1, 0) * cast(s32) layoutConfig.childGap);
						extraSpace := (currentElement.dimensions.height - cast(float) (cast(s32) layoutConfig.padding.top + cast(s32) layoutConfig.padding.bottom)) - contentSize.height;
						if layoutConfig.childAlignment.y == .TOP {
							extraSpace = 0;
						} else if layoutConfig.childAlignment.y == .CENTER {
							extraSpace /= 2;
						}
						currentElementTreeNode.nextChildOffset[1] += extraSpace;
					}
					if scrollContainerData != null {
						scrollContainerData.contentSize = .{
							width = contentSize.width + cast(float) (cast(s32) layoutConfig.padding.left + cast(s32) layoutConfig.padding.right),
							height = contentSize.height + cast(float) (cast(s32) layoutConfig.padding.top + cast(s32) layoutConfig.padding.bottom),
						};
					}
				}
			} else {
				closeClipElement := false;
				clipConfig := _FindElementConfigWithType(currentElement, CLAY__ELEMENT_CONFIG_TYPE_CLIP).clipElementConfig;
				if clipConfig != null {
					closeClipElement = true;
					scrollIndex : s32 = 0;
					while scrollIndex < ctx.scrollContainerDatas.length {
						mapping := _ScrollContainerDataInternalArray_Get(*ctx.scrollContainerDatas, scrollIndex);
						if mapping.layoutElement == currentElement {
							scrollOffset = clipConfig.childOffset;
							if ctx.externalScrollHandlingEnabled {
								scrollOffset = .[0, 0];
							}
							break;
						}
						scrollIndex += 1;
					}
				}
				if _ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_BORDER) {
					currentElementData := _GetHashMapItem(currentElement.id);
					currentElementBoundingBox := currentElementData.boundingBox;
					// Culling - Don't bother to generate render commands for rectangles entirely outside the screen - this won't stop their children from being rendered if they overflow
					if !_ElementIsOffscreen(*currentElementBoundingBox) {
						borderSharedConfig : *SharedElementConfig = null;
						if _ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_SHARED) {
							borderSharedConfig = _FindElementConfigWithType(currentElement, CLAY__ELEMENT_CONFIG_TYPE_SHARED).sharedElementConfig;
						} else {
							borderSharedConfig = *SharedElementConfig_DEFAULT;
						}
						borderConfig := _FindElementConfigWithType(currentElement, CLAY__ELEMENT_CONFIG_TYPE_BORDER).borderElementConfig;
						_AddRenderCommand(.{
							elementId = currentElement.id,
							boundingBox = currentElementBoundingBox,
							renderData = .{ border = .{
								color = borderConfig.color,
								cornerRadius = borderSharedConfig.cornerRadius,
								width = borderConfig.width,
							} },
							userData = borderSharedConfig.userData,
							id = _HashNumber(currentElement.id, cast(u32) currentElement.childrenOrTextContent.children.length).id,
							commandType = .BORDER,
						});
						if borderConfig.width.betweenChildren > 0 && borderConfig.color[3] > 0 {
							halfGap := cast(float) (cast(s32) layoutConfig.childGap / 2);
							borderOffset : Vector2 = .[cast(float) layoutConfig.padding.left - halfGap, cast(float) layoutConfig.padding.top - halfGap];
							if layoutConfig.layoutDirection == .LEFT_TO_RIGHT {
								i = 0;
								while i < cast(s32) currentElement.childrenOrTextContent.children.length {
									childElement := LayoutElementArray_Get(*ctx.layoutElements, currentElement.childrenOrTextContent.children.elements[i]);
									if i > 0 {
										_AddRenderCommand(.{
											elementId = currentElement.id,
											boundingBox = .{
												x = (currentElementBoundingBox.x + borderOffset[0]) + scrollOffset[0],
												y = currentElementBoundingBox.y + scrollOffset[1],
												width = cast(float) borderConfig.width.betweenChildren,
												height = currentElement.dimensions.height,
											},
											renderData = .{ rectangle = .{ backgroundColor = borderConfig.color } },
											userData = borderSharedConfig.userData,
											id = _HashNumber(currentElement.id, cast(u32) ((cast(s32) currentElement.childrenOrTextContent.children.length + 1) + i)).id,
											commandType = .RECTANGLE,
										});
									}
									borderOffset[0] += childElement.dimensions.width + cast(float) layoutConfig.childGap;
									i += 1;
								}
							} else {
								i = 0;
								while i < cast(s32) currentElement.childrenOrTextContent.children.length {
									childElement := LayoutElementArray_Get(*ctx.layoutElements, currentElement.childrenOrTextContent.children.elements[i]);
									if i > 0 {
										_AddRenderCommand(.{
											elementId = currentElement.id,
											boundingBox = .{
												x = currentElementBoundingBox.x + scrollOffset[0],
												y = (currentElementBoundingBox.y + borderOffset[1]) + scrollOffset[1],
												width = currentElement.dimensions.width,
												height = cast(float) borderConfig.width.betweenChildren,
											},
											renderData = .{ rectangle = .{ backgroundColor = borderConfig.color } },
											userData = borderSharedConfig.userData,
											id = _HashNumber(currentElement.id, cast(u32) ((cast(s32) currentElement.childrenOrTextContent.children.length + 1) + i)).id,
											commandType = .RECTANGLE,
										});
									}
									borderOffset[1] += childElement.dimensions.height + cast(float) layoutConfig.childGap;
									i += 1;
								}
							}
						}
					}
				}
				// This exists because the scissor needs to end _after_ borders between elements
				if closeClipElement {
					// olib extension: the scissor end also names its clip element (backends place focus rings after it).
					_AddRenderCommand(.{
						elementId = currentElement.id,
						id = _HashNumber(currentElement.id, cast(u32) (cast(s32) rootElement.childrenOrTextContent.children.length + 11)).id,
						commandType = .SCISSOR_END,
					});
				}
				dfsBuffer.length -= 1;
				continue;
			}
			// Add children to the DFS buffer
			if !_ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT) {
				dfsBuffer.length += cast(s32) currentElement.childrenOrTextContent.children.length;
				i = 0;
				while i < cast(s32) currentElement.childrenOrTextContent.children.length {
					childElement := LayoutElementArray_Get(*ctx.layoutElements, currentElement.childrenOrTextContent.children.elements[i]);
					// Alignment along non layout axis
					if layoutConfig.layoutDirection == .LEFT_TO_RIGHT {
						currentElementTreeNode.nextChildOffset[1] = cast(float) currentElement.layoutConfig.padding.top;
						whiteSpaceAroundChild := (currentElement.dimensions.height - cast(float) (cast(s32) layoutConfig.padding.top + cast(s32) layoutConfig.padding.bottom)) - childElement.dimensions.height;
						if layoutConfig.childAlignment.y == .CENTER {
							currentElementTreeNode.nextChildOffset[1] += (whiteSpaceAroundChild / 2);
						} else if layoutConfig.childAlignment.y == .BOTTOM {
							currentElementTreeNode.nextChildOffset[1] += whiteSpaceAroundChild;
						}
					} else {
						currentElementTreeNode.nextChildOffset[0] = cast(float) currentElement.layoutConfig.padding.left;
						whiteSpaceAroundChild := (currentElement.dimensions.width - cast(float) (cast(s32) layoutConfig.padding.left + cast(s32) layoutConfig.padding.right)) - childElement.dimensions.width;
						if layoutConfig.childAlignment.x == .CENTER {
							currentElementTreeNode.nextChildOffset[0] += (whiteSpaceAroundChild / 2);
						} else if layoutConfig.childAlignment.x == .RIGHT {
							currentElementTreeNode.nextChildOffset[0] += whiteSpaceAroundChild;
						}
					}
					childPosition : Vector2 = .[
						(currentElementTreeNode.position[0] + currentElementTreeNode.nextChildOffset[0]) + scrollOffset[0],
						(currentElementTreeNode.position[1] + currentElementTreeNode.nextChildOffset[1]) + scrollOffset[1],
					];
					// DFS buffer elements need to be added in reverse because stack traversal happens backwards
					newNodeIndex := (dfsBuffer.length - 1) - i;
					dfsBuffer.internalArray[newNodeIndex] = .{
						layoutElement = childElement,
						position = .[childPosition[0], childPosition[1]],
						nextChildOffset = .[cast(float) childElement.layoutConfig.padding.left, cast(float) childElement.layoutConfig.padding.top],
					};
					ctx.treeNodeVisited.internalArray[newNodeIndex] = false;
					// Update parent offsets
					if layoutConfig.layoutDirection == .LEFT_TO_RIGHT {
						currentElementTreeNode.nextChildOffset[0] += childElement.dimensions.width + cast(float) layoutConfig.childGap;
					} else {
						currentElementTreeNode.nextChildOffset[1] += childElement.dimensions.height + cast(float) layoutConfig.childGap;
					}
					i += 1;
				}
			}
		}
		if root.clipElementId != 0 {
			_AddRenderCommand(.{
				id = _HashNumber(rootElement.id, cast(u32) (cast(s32) rootElement.childrenOrTextContent.children.length + 11)).id,
				commandType = .SCISSOR_END,
			});
		}
		rootIndex += 1;
	}
}
//@endregion

//@region 指针查询

// clay.h:3095 — Clay_GetPointerOverIds
GetPointerOverIds :: () -> ElementIdArray {
	return GetCurrentContext().pointerOverIds;
}
//@endregion

//@region Jai 辅助（三元表达式与 FLT_MAX）
//
// olib 的 `cond ? a : b` 在 Jai 里没有对应语法（if 不是表达式），
// `_SizeContainersAlongAxis` 里这种 xAxis 二选一出现得太多，抽成小过程，
// 好处是每个调用点的行文与 olib 保持一行对一行。

// olib: ((cast(i32)(xAxis) != 0) ? a : b)
_PickFloat :: (xAxis: bool, a: float, b: float) -> float {
	if xAxis {
		return a;
	}
	return b;
}

_PickFloatPtr :: (xAxis: bool, a: *float, b: *float) -> *float {
	if xAxis {
		return a;
	}
	return b;
}

_PickSizingAxis :: (xAxis: bool, a: SizingAxis, b: SizingAxis) -> SizingAxis {
	if xAxis {
		return a;
	}
	return b;
}

_PickSizingType :: (xAxis: bool, a: SizingType, b: SizingType) -> SizingType {
	if xAxis {
		return a;
	}
	return b;
}

// olib 各处直接写 FLT_MAX 字面量 3.40282347E+38；Jai 不接受装不进 f32 的
// 常量隐式截断，所以显式 cast（结果正是 FLT_MAX）。
_CLAY_MAX_FLOAT : float = cast(float) 3.40282347E+38;
//@endregion
