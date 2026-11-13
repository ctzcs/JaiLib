//
// clay_api.jai — Clay v0.14 纯 Jai 移植（第四层：公开 API）
//
// 移植自 olib: D:\MySpace\Github\olib\thirdparty\clay\clay_api.odin (495 行)
// 上游: nicbarker/clay v0.14 (b25a31c1a152915cd7dd6796e6592273e5a10aac)。
// Copyright (c) 2024 Nic Barker. Altered source; see LICENSE.md and README.md.
//
// 纯 Jai，不链接 C 库，无 import。依赖 clay_types / clay_memory / clay_layout
// （_AddRenderCommand、_CalculateFinalLayout、_Initialize*Memory、_OpenElement 都在 layout 层）。
// 每个过程上方标注 olib 的行号（也等于 clay.h 的行号），方便逐行对拍。
//
// 本文件**不再重复定义**的东西（已在前几层，见理由）：
//   - `MinMemorySize`           → clay_layout.jai 顶部（第二轮提前上移，勿再定义）
//   - `GetCurrentContext` /
//     `SetCurrentContext`       → clay_memory.jai（Context 与它同层，第三轮前就定了）
//   - `_MeasureText` /
//     `_QueryScrollOffset`      → clay_memory.jai（测量/滚动回调全局量）
//   - `_BackendPointInside`     → clay_backend.jai（olib 把后端扩展单独放一个文件）
//   - `_RenderDebugView`        → clay_debug.jai
//
// 语法映射（与前几层一致）：
//   `for init; cond; incr` -> `while cond` + body 末尾手动 incr
//     ⚠ 关键陷阱：olib 的 `continue` **会**执行 incr，Jai 的 while + continue 不会。
//     凡是 for 体内既有 continue 又有 incr 的地方，都在 continue 前补一次 incr
//     （见 SetPointerState / UpdateScrollContainers 的就近注释）。
//     只有条件表达式（无 incr）的 `for cond { }` 则与 while 完全等价，continue 可照抄。
//   `x ? a : b`   -> if / else（或局部变量 + if）
//   `cast(i32)(bool)` -> 直接用 bool
//   `@(private)`  -> `// (文件内可见性由 Jai 的模块机制决定，保留下划线前缀即可)`
//

//@region 内存与回调

// clay.h:3886 — Clay_CreateArenaWithCapacityAndMemory
CreateArenaWithCapacityAndMemory :: (capacity: u64, offset: *u8) -> Arena {
	return .{ capacity = capacity, memory = offset };
}

// clay.h:3895 — Clay_SetMeasureTextFunction
SetMeasureTextFunction :: (measureTextFunction: (StringSlice, *TextElementConfig, *void) -> Dimensions, userData: *void) {
	ctx := GetCurrentContext();
	_MeasureText = measureTextFunction;
	ctx.measureTextUserData = userData;
}

// clay.h:3900 — Clay_SetQueryScrollOffsetFunction
SetQueryScrollOffsetFunction :: (queryScrollOffsetFunction: (u32, *void) -> Vector2, userData: *void) {
	ctx := GetCurrentContext();
	_QueryScrollOffset = queryScrollOffsetFunction;
	ctx.queryScrollOffsetUserData = userData;
}

// clay.h:3908 — Clay_SetLayoutDimensions
SetLayoutDimensions :: (dimensions: Dimensions) {
	GetCurrentContext().layoutDimensions = dimensions;
}
//@endregion

//@region 指针输入

// clay.h:3913 — Clay_SetPointerState
//
// 移植注记：两层循环
//   * 外层 `for rootIndex: i32 = ...; rootIndex >= 0; rootIndex -= 1` 体内有 `break`
//     （命中 capture 的浮动根即停），没有 continue → while + 末尾 `rootIndex -= 1`
//     与 olib 完全等价。
//   * 内层 `for (dfsBuffer.length > 0)` 只有条件、没有 incr → 直接写成 while，
//     里面的两处 `continue` 可以照抄。
SetPointerState :: (position: Vector2, pointerDown: bool) {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return;
	}
	ctx.pointerInfo.position = position;
	ctx.pointerOverIds.length = 0;
	dfsBuffer : _int32_tArray = ctx.layoutElementChildrenBuffer;
	rootIndex := ctx.layoutElementTreeRoots.length - 1;
	while rootIndex >= 0 {
		dfsBuffer.length = 0;
		root := _LayoutElementTreeRootArray_Get(*ctx.layoutElementTreeRoots, rootIndex);
		_int32_tArray_Add(*dfsBuffer, root.layoutElementIndex);
		ctx.treeNodeVisited.internalArray[0] = false;
		found := false;
		while dfsBuffer.length > 0 {
			if ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] {
				dfsBuffer.length -= 1;
				continue;
			}
			ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = true;
			currentElement := LayoutElementArray_Get(*ctx.layoutElements, _int32_tArray_GetValue(*dfsBuffer, dfsBuffer.length - 1));
			mapItem := _GetHashMapItem(currentElement.id);
			// olib: (i64)((uintptr)currentElement - (uintptr)ctx.layoutElements.internalArray) / size_of(LayoutElement)
			clipElementId := _int32_tArray_GetValue(*ctx.layoutElementClipElementIds, cast(s32) ((cast(u64) currentElement - cast(u64) ctx.layoutElements.internalArray) / cast(u64) size_of(LayoutElement)));
			clipItem := _GetHashMapItem(_s32_to_u32(clipElementId));
			if mapItem != null {
				elementBox := mapItem.boundingBox;
				elementBox.x -= root.pointerOffset[0];
				elementBox.y -= root.pointerOffset[1];
				if _BackendPointInside(currentElement.id, position, elementBox, false)
				&& (clipElementId == 0 || _BackendPointInside(_s32_to_u32(clipElementId), position, clipItem.boundingBox, true)) {
					if mapItem.onHoverFunction != null {
						mapItem.onHoverFunction(mapItem.elementId, ctx.pointerInfo, mapItem.hoverFunctionUserData);
					}
					ElementIdArray_Add(*ctx.pointerOverIds, mapItem.elementId);
					found = true;
					if mapItem.idAlias != 0 {
						ElementIdArray_Add(*ctx.pointerOverIds, .{ id = mapItem.idAlias });
					}
				}
				if _ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT) {
					dfsBuffer.length -= 1;
					continue;
				}
				i := cast(s32) currentElement.childrenOrTextContent.children.length - 1;
				while i >= 0 {
					_int32_tArray_Add(*dfsBuffer, currentElement.childrenOrTextContent.children.elements[i]);
					ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = false;
					i -= 1;
				}
			} else {
				dfsBuffer.length -= 1;
			}
		}
		rootElement := LayoutElementArray_Get(*ctx.layoutElements, root.layoutElementIndex);
		if found
		&& _ElementHasConfig(rootElement, CLAY__ELEMENT_CONFIG_TYPE_FLOATING)
		&& _FindElementConfigWithType(rootElement, CLAY__ELEMENT_CONFIG_TYPE_FLOATING).floatingElementConfig.pointerCaptureMode == .CAPTURE {
			break;
		}
		rootIndex -= 1;
	}
	if pointerDown {
		if ctx.pointerInfo.state == .PRESSED_THIS_FRAME {
			ctx.pointerInfo.state = .PRESSED;
		} else if ctx.pointerInfo.state != .PRESSED {
			ctx.pointerInfo.state = .PRESSED_THIS_FRAME;
		}
	} else {
		if ctx.pointerInfo.state == .RELEASED_THIS_FRAME {
			ctx.pointerInfo.state = .RELEASED;
		} else if ctx.pointerInfo.state != .RELEASED {
			ctx.pointerInfo.state = .RELEASED_THIS_FRAME;
		}
	}
}
//@endregion

//@region 初始化

// clay.h:3988 — Clay_Initialize
//
// ⚠ 两个哈希桶的播种是**必须**的：
//   layoutElementsHashMap 全部写 -1（_GetHashMapItem 用 -1 当链表终止符，
//     _AddHashMapItem 找不到 -1 会在 nextIndex 上死循环）
//   measureTextHashMap 全部写 0
//   然后 measureTextHashMapInternal.length = 1（第 0 项当哨兵）
// 这三步一个都不能少。
Initialize :: (arena_arg: Arena, layoutDimensions: Dimensions, errorHandler: ErrorHandler) -> *Context {
	// 过程参数在 Jai 里不可变；olib 传的是 arena 的副本，这里同样拷一份。
	arena := arena_arg;
	ctx := _Context_Allocate_Arena(*arena);
	if ctx == null {
		return null;
	}
	// DEFAULTS（olib 的三元表达式改成局部变量 + if）
	oldContext := GetCurrentContext();
	maxElementCount := _defaultMaxElementCount;
	maxMeasureTextCacheWordCount := _defaultMaxMeasureTextWordCacheCount;
	if oldContext != null {
		maxElementCount = oldContext.maxElementCount;
		maxMeasureTextCacheWordCount = oldContext.maxMeasureTextCacheWordCount;
	}
	handler := errorHandler;
	if handler.handler == null {
		handler = .{ handler = _ErrorHandlerFunctionDefault, userData = null };
	}
	ctx.* = .{
		maxElementCount = maxElementCount,
		maxMeasureTextCacheWordCount = maxMeasureTextCacheWordCount,
		errorHandler = handler,
		layoutDimensions = layoutDimensions,
		internalArena = arena,
	};
	SetCurrentContext(ctx);
	_InitializePersistentMemory(ctx);
	_InitializeEphemeralMemory(ctx);
	i : s32 = 0;
	while i < ctx.layoutElementsHashMap.capacity {
		ctx.layoutElementsHashMap.internalArray[i] = -1;
		i += 1;
	}
	i = 0;
	while i < ctx.measureTextHashMap.capacity {
		ctx.measureTextHashMap.internalArray[i] = 0;
		i += 1;
	}
	ctx.measureTextHashMapInternal.length = 1;
	ctx.layoutDimensions = layoutDimensions;
	return ctx;
}
//@endregion

//@region 滚动

// clay.h:4025 — Clay_GetScrollOffset
GetScrollOffset :: () -> Vector2 {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return .[0, 0];
	}
	openLayoutElement := _GetOpenLayoutElement();
	// If the element has no id attached at this point, we need to generate one
	if openLayoutElement.id == 0 {
		_GenerateIdForAnonymousElement(openLayoutElement);
	}
	i : s32 = 0;
	while i < ctx.scrollContainerDatas.length {
		mapping := _ScrollContainerDataInternalArray_Get(*ctx.scrollContainerDatas, i);
		if mapping.layoutElement == openLayoutElement {
			return mapping.scrollPosition;
		}
		i += 1;
	}
	return .[0, 0];
}

// clay.h:4045 — Clay_UpdateScrollContainers
//
// 移植注记：olib 的 for 循环体里有两处 `continue`（RemoveSwapback 之后），
// Odin 的 continue 会执行 `i += 1`，Jai 的 while + continue 不会。
// 所以两处 continue 前各补一次 `i += 1`；循环体末尾的 `i += 1` 照常。
// 其余（动量、clamp、拖拽滚动、滚轮）逐行对应。
UpdateScrollContainers :: (enableDragScrolling: bool, scrollDelta: Vector2, deltaTime: float) {
	ctx := GetCurrentContext();
	isPointerActive := enableDragScrolling
		&& (ctx.pointerInfo.state == .PRESSED || ctx.pointerInfo.state == .PRESSED_THIS_FRAME);
	// Don't apply scroll events to ancestors of the inner element
	highestPriorityElementIndex : s32 = -1;
	highestPriorityScrollData : *_ScrollContainerDataInternal = null;
	i : s32 = 0;
	while i < ctx.scrollContainerDatas.length {
		scrollData := _ScrollContainerDataInternalArray_Get(*ctx.scrollContainerDatas, i);
		if !scrollData.openThisFrame {
			_ScrollContainerDataInternalArray_RemoveSwapback(*ctx.scrollContainerDatas, i);
			i += 1; // olib: continue 会走 for 的 post 语句
			continue;
		}
		scrollData.openThisFrame = false;
		hashMapItem := _GetHashMapItem(scrollData.elementId);
		// Element isn't rendered this frame but scroll offset has been retained
		if hashMapItem == null {
			_ScrollContainerDataInternalArray_RemoveSwapback(*ctx.scrollContainerDatas, i);
			i += 1; // olib: continue 会走 for 的 post 语句
			continue;
		}
		// Touch / click is released
		if !isPointerActive && scrollData.pointerScrollActive {
			xDiff := scrollData.scrollPosition[0] - scrollData.scrollOrigin[0];
			if xDiff < cast(float) -10 || xDiff > cast(float) 10 {
				scrollData.scrollMomentum[0] = (scrollData.scrollPosition[0] - scrollData.scrollOrigin[0]) / (scrollData.momentumTime * cast(float) 25);
			}
			yDiff := scrollData.scrollPosition[1] - scrollData.scrollOrigin[1];
			if yDiff < cast(float) -10 || yDiff > cast(float) 10 {
				scrollData.scrollMomentum[1] = (scrollData.scrollPosition[1] - scrollData.scrollOrigin[1]) / (scrollData.momentumTime * cast(float) 25);
			}
			scrollData.pointerScrollActive = false;
			scrollData.pointerOrigin = .[0, 0];
			scrollData.scrollOrigin = .[0, 0];
			scrollData.momentumTime = cast(float) 0;
		}
		// Apply existing momentum
		scrollData.scrollPosition[0] += scrollData.scrollMomentum[0];
		scrollData.scrollMomentum[0] *= cast(float) 0.949999988;
		scrollOccurred := scrollDelta[0] != cast(float) 0 || scrollDelta[1] != cast(float) 0;
		if (scrollData.scrollMomentum[0] > cast(float) -0.100000001 && scrollData.scrollMomentum[0] < cast(float) 0.100000001)
		|| scrollOccurred {
			scrollData.scrollMomentum[0] = cast(float) 0;
		}
		scrollData.scrollPosition[0] = _min(
			_max(scrollData.scrollPosition[0], -_max(scrollData.contentSize.width - scrollData.layoutElement.dimensions.width, cast(float) 0)),
			cast(float) 0);
		scrollData.scrollPosition[1] += scrollData.scrollMomentum[1];
		scrollData.scrollMomentum[1] *= cast(float) 0.949999988;
		if (scrollData.scrollMomentum[1] > cast(float) -0.100000001 && scrollData.scrollMomentum[1] < cast(float) 0.100000001)
		|| scrollOccurred {
			scrollData.scrollMomentum[1] = cast(float) 0;
		}
		scrollData.scrollPosition[1] = _min(
			_max(scrollData.scrollPosition[1], -_max(scrollData.contentSize.height - scrollData.layoutElement.dimensions.height, cast(float) 0)),
			cast(float) 0);
		j : s32 = 0;
		while j < ctx.pointerOverIds.length {
			if scrollData.layoutElement.id == ElementIdArray_Get(*ctx.pointerOverIds, j).id {
				highestPriorityElementIndex = j;
				highestPriorityScrollData = scrollData;
			}
			j += 1;
		}
		i += 1;
	}
	if highestPriorityElementIndex > -1 && highestPriorityScrollData != null {
		scrollElement := highestPriorityScrollData.layoutElement;
		clipConfig := _FindElementConfigWithType(scrollElement, CLAY__ELEMENT_CONFIG_TYPE_CLIP).clipElementConfig;
		canScrollVertically := clipConfig.vertical && highestPriorityScrollData.contentSize.height > scrollElement.dimensions.height;
		canScrollHorizontally := clipConfig.horizontal && highestPriorityScrollData.contentSize.width > scrollElement.dimensions.width;
		// Handle wheel scroll
		if canScrollVertically {
			highestPriorityScrollData.scrollPosition[1] = highestPriorityScrollData.scrollPosition[1] + (scrollDelta[1] * cast(float) 10);
		}
		if canScrollHorizontally {
			highestPriorityScrollData.scrollPosition[0] = highestPriorityScrollData.scrollPosition[0] + (scrollDelta[0] * cast(float) 10);
		}
		// Handle click / touch scroll
		if isPointerActive {
			highestPriorityScrollData.scrollMomentum = .[0, 0];
			if !highestPriorityScrollData.pointerScrollActive {
				highestPriorityScrollData.pointerOrigin = ctx.pointerInfo.position;
				highestPriorityScrollData.scrollOrigin = highestPriorityScrollData.scrollPosition;
				highestPriorityScrollData.pointerScrollActive = true;
			} else {
				scrollDeltaX := cast(float) 0;
				scrollDeltaY := cast(float) 0;
				if canScrollHorizontally {
					oldXScrollPosition := highestPriorityScrollData.scrollPosition[0];
					highestPriorityScrollData.scrollPosition[0] = highestPriorityScrollData.scrollOrigin[0] + (ctx.pointerInfo.position[0] - highestPriorityScrollData.pointerOrigin[0]);
					highestPriorityScrollData.scrollPosition[0] = _max(
						_min(highestPriorityScrollData.scrollPosition[0], cast(float) 0),
						-(highestPriorityScrollData.contentSize.width - highestPriorityScrollData.boundingBox.width));
					scrollDeltaX = highestPriorityScrollData.scrollPosition[0] - oldXScrollPosition;
				}
				if canScrollVertically {
					oldYScrollPosition := highestPriorityScrollData.scrollPosition[1];
					highestPriorityScrollData.scrollPosition[1] = highestPriorityScrollData.scrollOrigin[1] + (ctx.pointerInfo.position[1] - highestPriorityScrollData.pointerOrigin[1]);
					highestPriorityScrollData.scrollPosition[1] = _max(
						_min(highestPriorityScrollData.scrollPosition[1], cast(float) 0),
						-(highestPriorityScrollData.contentSize.height - highestPriorityScrollData.boundingBox.height));
					scrollDeltaY = highestPriorityScrollData.scrollPosition[1] - oldYScrollPosition;
				}
				if scrollDeltaX > cast(float) -0.100000001 && scrollDeltaX < cast(float) 0.100000001
				&& scrollDeltaY > cast(float) -0.100000001 && scrollDeltaY < cast(float) 0.100000001
				&& highestPriorityScrollData.momentumTime > cast(float) 0.150000006 {
					highestPriorityScrollData.momentumTime = cast(float) 0;
					highestPriorityScrollData.pointerOrigin = ctx.pointerInfo.position;
					highestPriorityScrollData.scrollOrigin = highestPriorityScrollData.scrollPosition;
				} else {
					highestPriorityScrollData.momentumTime += deltaTime;
				}
			}
		}
		// Clamp any changes to scroll position to the maximum size of the contents
		if canScrollVertically {
			highestPriorityScrollData.scrollPosition[1] = _max(
				_min(highestPriorityScrollData.scrollPosition[1], cast(float) 0),
				-(highestPriorityScrollData.contentSize.height - scrollElement.dimensions.height));
		}
		if canScrollHorizontally {
			highestPriorityScrollData.scrollPosition[0] = _max(
				_min(highestPriorityScrollData.scrollPosition[0], cast(float) 0),
				-(highestPriorityScrollData.contentSize.width - scrollElement.dimensions.width));
		}
	}
}
//@endregion

//@region 帧布局

// clay.h:4159 — Clay_BeginLayout
BeginLayout :: () {
	ctx := GetCurrentContext();
	_InitializeEphemeralMemory(ctx);
	ctx.generation += 1;
	ctx.dynamicElementIndex = 0;
	// Set up the root container that covers the entire window
	rootDimensions : Dimensions = .{ width = ctx.layoutDimensions.width, height = ctx.layoutDimensions.height };
	if ctx.debugModeEnabled {
		rootDimensions.width -= cast(float) _debugViewWidth;
	}
	ctx.booleanWarnings = .{ maxElementsExceeded = false };
	_OpenElement();
	_ConfigureOpenElement(.{
		id = _HashString(_static_string("Clay__RootContainer"), 0, 0),
		layout = .{ sizing = .{
			width = .{ constraints = .{ sizeMinMax = .{ min = rootDimensions.width, max = rootDimensions.width } }, type = .FIXED },
			height = .{ constraints = .{ sizeMinMax = .{ min = rootDimensions.height, max = rootDimensions.height } }, type = .FIXED },
		} },
	});
	_int32_tArray_Add(*ctx.openLayoutElementStack, 0);
	_LayoutElementTreeRootArray_Add(*ctx.layoutElementTreeRoots, .{ layoutElementIndex = 0 });
}

// clay.h:4180 — Clay_EndLayout
EndLayout :: () -> ClayArray(RenderCommand) {
	ctx := GetCurrentContext();
	_CloseElement();
	elementsExceededBeforeDebugView := ctx.booleanWarnings.maxElementsExceeded;
	if ctx.debugModeEnabled && !elementsExceededBeforeDebugView {
		ctx.warningsEnabled = false;
		_RenderDebugView();
		ctx.warningsEnabled = true;
	}
	if ctx.booleanWarnings.maxElementsExceeded {
		message : String;
		if !elementsExceededBeforeDebugView {
			message = _static_string("Clay Error: Layout elements exceeded Clay__maxElementCount after adding the debug-view to the layout.");
		} else {
			message = _static_string("Clay Error: Layout elements exceeded Clay__maxElementCount");
		}
		_AddRenderCommand(.{
			boundingBox = .{
				x = (ctx.layoutDimensions.width / cast(float) 2) - cast(float) (59 * 4),
				y = ctx.layoutDimensions.height / cast(float) 2,
				width = cast(float) 0,
				height = cast(float) 0,
			},
			renderData = .{ text = .{
				stringContents = .{ length = message.length, chars = message.chars, baseChars = message.chars },
				textColor = .[255, 0, 0, 255],
				fontSize = 16,
			} },
			commandType = .TEXT,
		});
	} else {
		_CalculateFinalLayout();
	}
	return ctx.renderCommands;
}
//@endregion

//@region 元素查询

// clay.h:4208 — Clay_GetElementId
GetElementId :: (id: String) -> ElementId {
	return _HashString(id, 0, 0);
}

// clay.h:4213 — Clay_GetElementIdWithIndex
GetElementIdWithIndex :: (id: String, index: u32) -> ElementId {
	return _HashString(id, index, 0);
}

// clay.h:4217 — Clay_Hovered
Hovered :: () -> bool {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return false;
	}
	openLayoutElement := _GetOpenLayoutElement();
	// If the element has no id attached at this point, we need to generate one
	if openLayoutElement.id == 0 {
		_GenerateIdForAnonymousElement(openLayoutElement);
	}
	i : s32 = 0;
	while i < ctx.pointerOverIds.length {
		if ElementIdArray_Get(*ctx.pointerOverIds, i).id == openLayoutElement.id {
			return true;
		}
		i += 1;
	}
	return false;
}

// clay.h:4235 — Clay_OnHover
OnHover :: (onHoverFunction: (ElementId, PointerData, *void) -> (), userData: *void) {
	ctx := GetCurrentContext();
	if ctx.booleanWarnings.maxElementsExceeded {
		return;
	}
	openLayoutElement := _GetOpenLayoutElement();
	if openLayoutElement.id == 0 {
		_GenerateIdForAnonymousElement(openLayoutElement);
	}
	hashMapItem := _GetHashMapItem(openLayoutElement.id);
	hashMapItem.onHoverFunction = onHoverFunction;
	hashMapItem.hoverFunctionUserData = userData;
}

// clay.h:4250 — Clay_PointerOver
PointerOver :: (id: ElementId) -> bool {
	ctx := GetCurrentContext();
	i : s32 = 0;
	while i < ctx.pointerOverIds.length {
		if ElementIdArray_Get(*ctx.pointerOverIds, i).id == id.id {
			return true;
		}
		i += 1;
	}
	return false;
}

// clay.h:4261 — Clay_GetScrollContainerData
GetScrollContainerData :: (id: ElementId) -> ScrollContainerData {
	ctx := GetCurrentContext();
	i : s32 = 0;
	while i < ctx.scrollContainerDatas.length {
		scrollContainerData := _ScrollContainerDataInternalArray_Get(*ctx.scrollContainerDatas, i);
		if scrollContainerData.elementId == id.id {
			clipElementConfig := _FindElementConfigWithType(scrollContainerData.layoutElement, CLAY__ELEMENT_CONFIG_TYPE_CLIP).clipElementConfig;
			if clipElementConfig == null {
				return .{ scrollPosition = null };
			}
			return .{
				scrollPosition = *scrollContainerData.scrollPosition,
				scrollContainerDimensions = .{
					width = scrollContainerData.boundingBox.width,
					height = scrollContainerData.boundingBox.height,
				},
				contentDimensions = scrollContainerData.contentSize,
				config = clipElementConfig.*,
				found = true,
			};
		}
		i += 1;
	}
	return .{ scrollPosition = null };
}

// clay.h:4283 — Clay_GetElementData
GetElementData :: (id: ElementId) -> ElementData {
	item := _GetHashMapItem(id.id);
	if item == *LayoutElementHashMapItem_DEFAULT {
		return .{ boundingBox = .{ x = cast(float) 0 } };
	}
	return .{ boundingBox = item.boundingBox, found = true };
}
//@endregion

//@region 运行设置

// clay.h:4296 — Clay_SetDebugModeEnabled
SetDebugModeEnabled :: (enabled: bool) {
	ctx := GetCurrentContext();
	ctx.debugModeEnabled = enabled;
}

// clay.h:4302 — Clay_IsDebugModeEnabled
IsDebugModeEnabled :: () -> bool {
	ctx := GetCurrentContext();
	return ctx.debugModeEnabled;
}

// clay.h:4308 — Clay_SetCullingEnabled
SetCullingEnabled :: (enabled: bool) {
	ctx := GetCurrentContext();
	ctx.disableCulling = !enabled;
}

// clay.h:4314 — Clay_SetExternalScrollHandlingEnabled
SetExternalScrollHandlingEnabled :: (enabled: bool) {
	ctx := GetCurrentContext();
	ctx.externalScrollHandlingEnabled = enabled;
}

// clay.h:4320 — Clay_GetMaxElementCount
GetMaxElementCount :: () -> s32 {
	ctx := GetCurrentContext();
	return ctx.maxElementCount;
}

// clay.h:4326 — Clay_SetMaxElementCount
SetMaxElementCount :: (maxElementCount: s32) {
	ctx := GetCurrentContext();
	if ctx != null {
		ctx.maxElementCount = maxElementCount;
	} else {
		_defaultMaxElementCount = maxElementCount;
		_defaultMaxMeasureTextWordCacheCount = maxElementCount * 2;
	}
}

// clay.h:4337 — Clay_GetMaxMeasureTextCacheWordCount
GetMaxMeasureTextCacheWordCount :: () -> s32 {
	ctx := GetCurrentContext();
	return ctx.maxMeasureTextCacheWordCount;
}

// clay.h:4343 — Clay_SetMaxMeasureTextCacheWordCount
SetMaxMeasureTextCacheWordCount :: (maxMeasureTextCacheWordCount: s32) {
	ctx := GetCurrentContext();
	if ctx != null {
		// olib 这里写的是 _currentContext 而不是局部 ctx，效果相同，照抄。
		_currentContext.maxMeasureTextCacheWordCount = maxMeasureTextCacheWordCount;
	} else {
		_defaultMaxMeasureTextWordCacheCount = maxMeasureTextCacheWordCount;
	}
}

// clay.h:4353 — Clay_ResetMeasureTextCache
ResetMeasureTextCache :: () {
	ctx := GetCurrentContext();
	ctx.measureTextHashMapInternal.length = 0;
	ctx.measureTextHashMapInternalFreeList.length = 0;
	ctx.measureTextHashMap.length = 0;
	ctx.measuredWords.length = 0;
	ctx.measuredWordsFreeList.length = 0;
	i : s32 = 0;
	while i < ctx.measureTextHashMap.capacity {
		ctx.measureTextHashMap.internalArray[i] = 0;
		i += 1;
	}
	ctx.measureTextHashMapInternal.length = 1;
}
//@endregion
