//
// clay_types.jai — Clay v0.14 纯 Jai 移植（第一层：类型 + 内存）
//
// 移植自 olib: D:\MySpace\Github\olib\thirdparty\clay\clay_types.odin (829 行)
//   以及它依赖的基础类型（olib 放在 clay.odin / clay_backend.odin，见下方
//   “跨文件前置”说明）。上游: nicbarker/clay v0.14 (b25a31c1a152915cd7dd6796e6592273e5a10aac)。
// Copyright (c) 2024 Nic Barker. Altered source; see LICENSE.md and README.md.
//
// 纯 Jai，不链接 C 库，无 import。
//
// 命名约定（与 olib 一比一，为了 kit/ui 同路径 drop-in）：
//   - 公开类型 / 过程 / 字段：保留 olib 的 PascalCase / camelCase
//     （Context、ElementDeclaration、maxElementCount、cornerRadius …）
//   - olib 的内部符号保留同样的下划线前缀（_boolArray、_LayoutConfigArray …）
//   - 枚举成员是唯一例外：JaiLib 既有约定用大写下划线（.FIT / .CENTER），
//     olib 是 .Fit / .Center。成员顺序、数值、语义完全一致。
//
// Jai 与 Odin 的类型对应：
//   [^]T        -> *T      （Jai 没有可空的多重指针；*T 支持下标与加减，null 可比较）
//   [N]f32      -> [N] float（olib 的 Color / Vector2 就是数组）
//   rawptr      -> *void
//   uintptr     -> u64
//   #raw_union  -> union    （Jai 的 union 本身无 tag，尺寸取最大成员）
//

//@region 基础类型（olib: clay.odin “基础类型” + clay_backend.odin 的 PointerHitTest）

String :: struct {
	isStaticallyAllocated: bool;
	length:                s32;
	chars:                 *u8;
}

StringSlice :: struct {
	length:    s32;
	chars:     *u8;
	baseChars: *u8;
}

Vector2 :: [2] float;

Dimensions :: struct {
	width:  float;
	height: float;
}

Arena :: struct {
	nextAllocation: u64;
	capacity:       u64;
	memory:         *u8;
}

BoundingBox :: struct {
	x:      float;
	y:      float;
	width:  float;
	height: float;
}

Color :: [4] float;

CornerRadius :: struct {
	topLeft:     float;
	topRight:    float;
	bottomLeft:  float;
	bottomRight: float;
}

BorderData :: struct {
	width: u32;
	color: Color;
}

ElementId :: struct {
	id:       u32;
	offset:   u32;
	baseId:   u32;
	stringId: String;
}

// olib 的 EnumBackingType 在 Windows 是 u32；这里统一 u32（无 C ABI 需求）。
// clay_backend.odin 的 PointerHitTest —— Context 的第一个字段，必须一起带过来。
// ⚠ Jai 里「带具名参数但没有函数体」的写法会被当成过程常量（报 "missing its body"），
//   声明过程类型必须加 `#type`。
PointerHitTest :: #type (id: u32, position: Vector2, bounds: BoundingBox, clip: bool, userData: *void) -> bool;
//@endregion

//@region 渲染命令类型与元素配置（olib: clay.odin）

RenderCommandType :: enum u32 {
	NONE          :: 0;
	RECTANGLE     :: 1;
	BORDER        :: 2;
	TEXT          :: 3;
	IMAGE         :: 4;
	SCISSOR_START :: 5;
	SCISSOR_END   :: 6;
	CUSTOM        :: 7;
}

RectangleElementConfig :: struct {
	color: Color;
}

TextWrapMode :: enum u32 {
	WORDS    :: 0;
	NEWLINES :: 1;
	NONE     :: 2;
}

TextAlignment :: enum u32 {
	LEFT   :: 0;
	CENTER :: 1;
	RIGHT  :: 2;
}

TextElementConfig :: struct {
	userData:      *void;
	textColor:     Color;
	fontId:        u16;
	fontSize:      u16;
	letterSpacing: u16;
	lineHeight:    u16;
	wrapMode:      TextWrapMode;
	textAlignment: TextAlignment;
}

AspectRatioElementConfig :: struct {
	aspectRatio: float;
}

ImageElementConfig :: struct {
	imageData: *void;
}

CustomElementConfig :: struct {
	customData: *void;
}

BorderWidth :: struct {
	left:            u16;
	right:           u16;
	top:             u16;
	bottom:          u16;
	betweenChildren: u16;
}

BorderElementConfig :: struct {
	color: Color;
	width: BorderWidth;
}

ClipElementConfig :: struct {
	horizontal:  bool;
	vertical:    bool;
	childOffset: Vector2;
}

FloatingAttachPointType :: enum u32 {
	LEFT_TOP      :: 0;
	LEFT_CENTER   :: 1;
	LEFT_BOTTOM   :: 2;
	CENTER_TOP    :: 3;
	CENTER_CENTER :: 4;
	CENTER_BOTTOM :: 5;
	RIGHT_TOP     :: 6;
	RIGHT_CENTER  :: 7;
	RIGHT_BOTTOM  :: 8;
}

FloatingAttachPoints :: struct {
	element: FloatingAttachPointType;
	parent:  FloatingAttachPointType;
}

PointerCaptureMode :: enum u32 {
	CAPTURE     :: 0;
	PASSTHROUGH :: 1;
}

FloatingAttachToElement :: enum u32 {
	NONE          :: 0;
	PARENT        :: 1;
	ELEMENT_WITH_ID :: 2;
	ROOT          :: 3;
}

FloatingClipToElement :: enum u32 {
	NONE            :: 0;
	ATTACHED_PARENT :: 1;
}

FloatingElementConfig :: struct {
	offset:             Vector2;
	expand:             Dimensions;
	parentId:           u32;
	zIndex:             s16;
	attachment:         FloatingAttachPoints;
	pointerCaptureMode: PointerCaptureMode;
	attachTo:           FloatingAttachToElement;
	clipTo:             FloatingClipToElement;
}
//@endregion

//@region 渲染命令数据（olib: clay.odin）

TextRenderData :: struct {
	stringContents: StringSlice;
	textColor:      Color;
	fontId:         u16;
	fontSize:       u16;
	letterSpacing:  u16;
	lineHeight:     u16;
}

RectangleRenderData :: struct {
	backgroundColor: Color;
	cornerRadius:    CornerRadius;
}

ImageRenderData :: struct {
	backgroundColor: Color;
	cornerRadius:    CornerRadius;
	imageData:       *void;
}

CustomRenderData :: struct {
	backgroundColor: Color;
	cornerRadius:    CornerRadius;
	customData:      *void;
}

BorderRenderData :: struct {
	color:        Color;
	cornerRadius: CornerRadius;
	width:        BorderWidth;
}

RenderCommandData :: union {
	clip:      ClipRenderData;
	rectangle: RectangleRenderData;
	text:      TextRenderData;
	image:     ImageRenderData;
	custom:    CustomRenderData;
	border:    BorderRenderData;
}

RenderCommand :: struct {
	// olib 扩展：布局元素归属（含文本行、边框与 scissor 结束命令）。
	elementId:   u32;
	boundingBox: BoundingBox;
	renderData:  RenderCommandData;
	userData:    *void;
	id:          u32;
	zIndex:      s16;
	commandType: RenderCommandType;
}
//@endregion

//@region 滚动、元素与指针数据（olib: clay.odin）

ScrollContainerData :: struct {
	// Note: 指向内部真实滚动位置；修改它会改变最终布局。
	scrollPosition:            *Vector2;
	scrollContainerDimensions: Dimensions;
	contentDimensions:         Dimensions;
	config:                    ClipElementConfig;
	// 是否真的匹配到了滚动容器（否则返回默认结构体）。
	found:                     bool;
}

ElementData :: struct {
	boundingBox: BoundingBox;
	found:       bool;
}

PointerDataInteractionState :: enum u32 {
	PRESSED_THIS_FRAME  :: 0;
	PRESSED             :: 1;
	RELEASED_THIS_FRAME :: 2;
	RELEASED            :: 3;
}

PointerData :: struct {
	position: Vector2;
	state:    PointerDataInteractionState;
}
//@endregion

//@region 布局配置与元素声明（olib: clay.odin）

SizingType :: enum u32 {
	FIT     :: 0;
	GROW    :: 1;
	PERCENT :: 2;
	FIXED   :: 3;
}

SizingConstraintsMinMax :: struct {
	min: float;
	max: float;
}

SizingConstraints :: union {
	sizeMinMax:  SizingConstraintsMinMax;
	sizePercent: float;
}

SizingAxis :: struct {
	// Note: PERCENT 用 constraints 里的 sizePercent，与 clay.h 略不同（C 无匿名的 union）。
	constraints: SizingConstraints;
	type:        SizingType;
}

Sizing :: struct {
	width:  SizingAxis;
	height: SizingAxis;
}

Padding :: struct {
	left:   u16;
	right:  u16;
	top:    u16;
	bottom: u16;
}

LayoutDirection :: enum u32 {
	LEFT_TO_RIGHT :: 0;
	TOP_TO_BOTTOM :: 1;
}

LayoutAlignmentX :: enum u32 {
	LEFT   :: 0;
	RIGHT  :: 1;
	CENTER :: 2;
}

LayoutAlignmentY :: enum u32 {
	TOP    :: 0;
	BOTTOM :: 1;
	CENTER :: 2;
}

ChildAlignment :: struct {
	x: LayoutAlignmentX;
	y: LayoutAlignmentY;
}

LayoutConfig :: struct {
	sizing:          Sizing;
	padding:         Padding;
	childGap:        u16;
	childAlignment:  ChildAlignment;
	layoutDirection: LayoutDirection;
}

// olib: ClayArray :: struct($type: typeid) —— Jai 的参数化结构体。
ClayArray :: struct (T: Type) {
	capacity:      s32;
	length:        s32;
	internalArray: *T;
}

ElementDeclaration :: struct {
	id:              ElementId;
	layout:          LayoutConfig;
	backgroundColor: Color;
	cornerRadius:    CornerRadius;
	aspectRatio:     AspectRatioElementConfig;
	image:           ImageElementConfig;
	floating:        FloatingElementConfig;
	custom:          CustomElementConfig;
	clip:            ClipElementConfig;
	border:          BorderElementConfig;
	userData:        *void;
}
//@endregion

//@region 错误（olib: clay.odin）

ErrorType :: enum u32 {
	TEXT_MEASUREMENT_FUNCTION_NOT_PROVIDED :: 0;
	ARENA_CAPACITY_EXCEEDED                :: 1;
	ELEMENTS_CAPACITY_EXCEEDED             :: 2;
	TEXT_MEASUREMENT_CAPACITY_EXCEEDED     :: 3;
	DUPLICATE_ID                           :: 4;
	FLOATING_CONTAINER_PARENT_NOT_FOUND    :: 5;
	PERCENTAGE_OVER_1                      :: 6;
	INTERNAL_ERROR                         :: 7;
}

ErrorData :: struct {
	errorType: ErrorType;
	errorText: String;
	userData:  *void;
}

ErrorHandler :: struct {
	handler:  (errorData: ErrorData) -> ();
	userData: *void;
}
//@endregion

//@region Context（olib: clay_types.odin）

Context :: struct {
	// 可选 olib 后端命中测试；为 null 时保持上游行为。
	pointerHitTest:                     PointerHitTest;
	pointerHitTestUserData:             *void;
	maxElementCount:                    s32;
	maxMeasureTextCacheWordCount:       s32;
	warningsEnabled:                    bool;
	errorHandler:                       ErrorHandler;
	booleanWarnings:                    BooleanWarnings;
	warnings:                           _WarningArray;
	pointerInfo:                        PointerData;
	layoutDimensions:                   Dimensions;
	dynamicElementIndexBaseHash:        ElementId;
	dynamicElementIndex:                u32;
	debugModeEnabled:                   bool;
	disableCulling:                     bool;
	externalScrollHandlingEnabled:      bool;
	debugSelectedElementId:             u32;
	generation:                         u32;
	arenaResetOffset:                   u64;
	measureTextUserData:                *void;
	queryScrollOffsetUserData:          *void;
	internalArena:                      Arena;
	layoutElements:                     LayoutElementArray;
	renderCommands:                     ClayArray(RenderCommand);
	openLayoutElementStack:             _int32_tArray;
	layoutElementChildren:              _int32_tArray;
	layoutElementChildrenBuffer:        _int32_tArray;
	textElementData:                    _TextElementDataArray;
	aspectRatioElementIndexes:          _int32_tArray;
	reusableElementIndexBuffer:         _int32_tArray;
	layoutElementClipElementIds:        _int32_tArray;
	layoutConfigs:                      _LayoutConfigArray;
	elementConfigs:                     _ElementConfigArray;
	textElementConfigs:                 _TextElementConfigArray;
	aspectRatioElementConfigs:          _AspectRatioElementConfigArray;
	imageElementConfigs:                _ImageElementConfigArray;
	floatingElementConfigs:             _FloatingElementConfigArray;
	clipElementConfigs:                 _ClipElementConfigArray;
	customElementConfigs:               _CustomElementConfigArray;
	borderElementConfigs:               _BorderElementConfigArray;
	sharedElementConfigs:               _SharedElementConfigArray;
	layoutElementIdStrings:             _StringArray;
	wrappedTextLines:                   _WrappedTextLineArray;
	layoutElementTreeNodeArray1:        _LayoutElementTreeNodeArray;
	layoutElementTreeRoots:             _LayoutElementTreeRootArray;
	layoutElementsHashMapInternal:      _LayoutElementHashMapItemArray;
	layoutElementsHashMap:              _int32_tArray;
	measureTextHashMapInternal:         _MeasureTextCacheItemArray;
	measureTextHashMapInternalFreeList: _int32_tArray;
	measureTextHashMap:                 _int32_tArray;
	measuredWords:                      _MeasuredWordArray;
	measuredWordsFreeList:              _int32_tArray;
	openClipElementStack:               _int32_tArray;
	pointerOverIds:                     ElementIdArray;
	scrollContainerDatas:               _ScrollContainerDataInternalArray;
	treeNodeVisited:                    _boolArray;
	dynamicStringData:                  _charArray;
	debugElementData:                   _DebugElementDataArray;
}
//@endregion

//@region 内部结构与类型化数组（olib: clay_types.odin）

ElementIdArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *ElementId;
}

_Clay_PaddingWrapper :: struct {
	wrapped: Padding;
}

_Clay_LayoutConfigWrapper :: struct {
	wrapped: LayoutConfig;
}

_Clay_TextElementConfigWrapper :: struct {
	wrapped: TextElementConfig;
}

_Clay_AspectRatioElementConfigWrapper :: struct {
	wrapped: AspectRatioElementConfig;
}

_Clay_ImageElementConfigWrapper :: struct {
	wrapped: ImageElementConfig;
}

_Clay_FloatingElementConfigWrapper :: struct {
	wrapped: FloatingElementConfig;
}

_Clay_CustomElementConfigWrapper :: struct {
	wrapped: CustomElementConfig;
}

_Clay_ClipElementConfigWrapper :: struct {
	wrapped: ClipElementConfig;
}

_Clay_BorderElementConfigWrapper :: struct {
	wrapped: BorderElementConfig;
}

ClipRenderData :: struct {
	horizontal: bool;
	vertical:   bool;
}

_Clay_ElementDeclarationWrapper :: struct {
	wrapped: ElementDeclaration;
}

BooleanWarnings :: struct {
	maxElementsExceeded:           bool;
	maxRenderCommandsExceeded:     bool;
	maxTextMeasureCacheExceeded:   bool;
	textMeasurementFunctionNotSet: bool;
}

_Warning :: struct {
	baseMessage:    String;
	dynamicMessage: String;
}

_WarningArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *_Warning;
}

SharedElementConfig :: struct {
	backgroundColor: Color;
	cornerRadius:    CornerRadius;
	userData:        *void;
}

_Clay_SharedElementConfigWrapper :: struct {
	wrapped: SharedElementConfig;
}

_boolArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *bool;
}

_boolArraySlice :: struct {
	length:        s32;
	internalArray: *bool;
}

_int32_tArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *s32;
}

_int32_tArraySlice :: struct {
	length:        s32;
	internalArray: *s32;
}

_charArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *u8;
}

_charArraySlice :: struct {
	length:        s32;
	internalArray: *u8;
}

ElementIdArraySlice :: struct {
	length:        s32;
	internalArray: *ElementId;
}

_LayoutConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *LayoutConfig;
}

_LayoutConfigArraySlice :: struct {
	length:        s32;
	internalArray: *LayoutConfig;
}

_TextElementConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *TextElementConfig;
}

_TextElementConfigArraySlice :: struct {
	length:        s32;
	internalArray: *TextElementConfig;
}

_AspectRatioElementConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *AspectRatioElementConfig;
}

_AspectRatioElementConfigArraySlice :: struct {
	length:        s32;
	internalArray: *AspectRatioElementConfig;
}

_ImageElementConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *ImageElementConfig;
}

_ImageElementConfigArraySlice :: struct {
	length:        s32;
	internalArray: *ImageElementConfig;
}

_FloatingElementConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *FloatingElementConfig;
}

_FloatingElementConfigArraySlice :: struct {
	length:        s32;
	internalArray: *FloatingElementConfig;
}

_CustomElementConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *CustomElementConfig;
}

_CustomElementConfigArraySlice :: struct {
	length:        s32;
	internalArray: *CustomElementConfig;
}

_ClipElementConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *ClipElementConfig;
}

_ClipElementConfigArraySlice :: struct {
	length:        s32;
	internalArray: *ClipElementConfig;
}

_BorderElementConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *BorderElementConfig;
}

_BorderElementConfigArraySlice :: struct {
	length:        s32;
	internalArray: *BorderElementConfig;
}

_StringArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *String;
}

_StringArraySlice :: struct {
	length:        s32;
	internalArray: *String;
}

_SharedElementConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *SharedElementConfig;
}

_SharedElementConfigArraySlice :: struct {
	length:        s32;
	internalArray: *SharedElementConfig;
}

RenderCommandArraySlice :: struct {
	length:        s32;
	internalArray: *RenderCommand;
}

ElementConfigUnion :: union {
	textElementConfig:        *TextElementConfig;
	aspectRatioElementConfig: *AspectRatioElementConfig;
	imageElementConfig:       *ImageElementConfig;
	floatingElementConfig:    *FloatingElementConfig;
	customElementConfig:      *CustomElementConfig;
	clipElementConfig:        *ClipElementConfig;
	borderElementConfig:      *BorderElementConfig;
	sharedElementConfig:      *SharedElementConfig;
}

ElementConfig :: struct {
	type:   _ElementConfigType;
	config: ElementConfigUnion;
}

_ElementConfigArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *ElementConfig;
}

_ElementConfigArraySlice :: struct {
	length:        s32;
	internalArray: *ElementConfig;
}

_WrappedTextLine :: struct {
	dimensions: Dimensions;
	line:       String;
}

_WrappedTextLineArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *_WrappedTextLine;
}

_WrappedTextLineArraySlice :: struct {
	length:        s32;
	internalArray: *_WrappedTextLine;
}

_TextElementData :: struct {
	text:               String;
	preferredDimensions: Dimensions;
	elementIndex:       s32;
	wrappedLines:       _WrappedTextLineArraySlice;
}

_TextElementDataArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *_TextElementData;
}

_TextElementDataArraySlice :: struct {
	length:        s32;
	internalArray: *_TextElementData;
}

_LayoutElementChildren :: struct {
	elements: *s32;
	length:   u16;
}

LayoutElement :: struct {
	childrenOrTextContent: LayoutElement_childrenOrTextContent;
	dimensions:            Dimensions;
	minDimensions:         Dimensions;
	layoutConfig:          *LayoutConfig;
	elementConfigs:        _ElementConfigArraySlice;
	id:                    u32;
}

LayoutElementArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *LayoutElement;
}

LayoutElementArraySlice :: struct {
	length:        s32;
	internalArray: *LayoutElement;
}

_ScrollContainerDataInternal :: struct {
	layoutElement:      *LayoutElement;
	boundingBox:        BoundingBox;
	contentSize:        Dimensions;
	scrollOrigin:       Vector2;
	pointerOrigin:      Vector2;
	scrollMomentum:     Vector2;
	scrollPosition:     Vector2;
	previousDelta:      Vector2;
	momentumTime:       float;
	elementId:          u32;
	openThisFrame:      bool;
	pointerScrollActive: bool;
}

_ScrollContainerDataInternalArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *_ScrollContainerDataInternal;
}

_ScrollContainerDataInternalArraySlice :: struct {
	length:        s32;
	internalArray: *_ScrollContainerDataInternal;
}

_DebugElementData :: struct {
	collision: bool;
	collapsed: bool;
}

_DebugElementDataArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *_DebugElementData;
}

_DebugElementDataArraySlice :: struct {
	length:        s32;
	internalArray: *_DebugElementData;
}

LayoutElementHashMapItem :: struct {
	boundingBox:           BoundingBox;
	elementId:             ElementId;
	layoutElement:         *LayoutElement;
	onHoverFunction:       (ElementId, PointerData, *void) -> ();
	hoverFunctionUserData: *void;
	nextIndex:             s32;
	generation:            u32;
	idAlias:               u32;
	debugData:             *_DebugElementData;
}

_LayoutElementHashMapItemArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *LayoutElementHashMapItem;
}

_LayoutElementHashMapItemArraySlice :: struct {
	length:        s32;
	internalArray: *LayoutElementHashMapItem;
}

_MeasuredWord :: struct {
	startOffset: s32;
	length:      s32;
	width:       float;
	next:        s32;
}

_MeasuredWordArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *_MeasuredWord;
}

_MeasuredWordArraySlice :: struct {
	length:        s32;
	internalArray: *_MeasuredWord;
}

_MeasureTextCacheItem :: struct {
	unwrappedDimensions:      Dimensions;
	measuredWordsStartIndex:  s32;
	minWidth:                 float;
	containsNewlines:         bool;
	id:                       u32;
	nextIndex:                s32;
	generation:               u32;
}

_MeasureTextCacheItemArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *_MeasureTextCacheItem;
}

_MeasureTextCacheItemArraySlice :: struct {
	length:        s32;
	internalArray: *_MeasureTextCacheItem;
}

_LayoutElementTreeNode :: struct {
	layoutElement:   *LayoutElement;
	position:        Vector2;
	nextChildOffset: Vector2;
}

_LayoutElementTreeNodeArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *_LayoutElementTreeNode;
}

_LayoutElementTreeNodeArraySlice :: struct {
	length:        s32;
	internalArray: *_LayoutElementTreeNode;
}

_LayoutElementTreeRoot :: struct {
	layoutElementIndex: s32;
	parentId:           u32;
	clipElementId:      u32;
	zIndex:             s16;
	pointerOffset:      Vector2;
}

_LayoutElementTreeRootArray :: struct {
	capacity:      s32;
	length:        s32;
	internalArray: *_LayoutElementTreeRoot;
}

_LayoutElementTreeRootArraySlice :: struct {
	length:        s32;
	internalArray: *_LayoutElementTreeRoot;
}

_DebugElementConfigTypeLabelConfig :: struct {
	label: String;
	color: Color;
}

_RenderDebugLayoutData :: struct {
	rowCount:                 s32;
	selectedElementRowIndex:  s32;
}

ScrollRenderData :: struct {
	horizontal: bool;
	vertical:   bool;
}

LayoutElement_childrenOrTextContent :: union {
	children:        _LayoutElementChildren;
	textElementData: *_TextElementData;
}
//@endregion

//@region C 枚举常量（olib: clay_types.odin）
// 保持 olib 的常数形态：_ElementConfigType 是 u8，不是 Jai enum，
// 这样 clay_layout 的 `config.type == CLAY__ELEMENT_CONFIG_TYPE_TEXT` 可以照抄。

CLAY_LEFT_TO_RIGHT :: 0;
CLAY_TOP_TO_BOTTOM :: 1;

CLAY_ALIGN_X_LEFT :: 0;
CLAY_ALIGN_X_RIGHT :: 1;
CLAY_ALIGN_X_CENTER :: 2;

CLAY_ALIGN_Y_TOP :: 0;
CLAY_ALIGN_Y_BOTTOM :: 1;
CLAY_ALIGN_Y_CENTER :: 2;

CLAY__SIZING_TYPE_FIT :: 0;
CLAY__SIZING_TYPE_GROW :: 1;
CLAY__SIZING_TYPE_PERCENT :: 2;
CLAY__SIZING_TYPE_FIXED :: 3;

CLAY_TEXT_WRAP_WORDS :: 0;
CLAY_TEXT_WRAP_NEWLINES :: 1;
CLAY_TEXT_WRAP_NONE :: 2;

CLAY_TEXT_ALIGN_LEFT :: 0;
CLAY_TEXT_ALIGN_CENTER :: 1;
CLAY_TEXT_ALIGN_RIGHT :: 2;

CLAY_ATTACH_POINT_LEFT_TOP :: 0;
CLAY_ATTACH_POINT_LEFT_CENTER :: 1;
CLAY_ATTACH_POINT_LEFT_BOTTOM :: 2;
CLAY_ATTACH_POINT_CENTER_TOP :: 3;
CLAY_ATTACH_POINT_CENTER_CENTER :: 4;
CLAY_ATTACH_POINT_CENTER_BOTTOM :: 5;
CLAY_ATTACH_POINT_RIGHT_TOP :: 6;
CLAY_ATTACH_POINT_RIGHT_CENTER :: 7;
CLAY_ATTACH_POINT_RIGHT_BOTTOM :: 8;

CLAY_POINTER_CAPTURE_MODE_CAPTURE :: 0;
CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH :: 1;

CLAY_ATTACH_TO_NONE :: 0;
CLAY_ATTACH_TO_PARENT :: 1;
CLAY_ATTACH_TO_ELEMENT_WITH_ID :: 2;
CLAY_ATTACH_TO_ROOT :: 3;

CLAY_CLIP_TO_NONE :: 0;
CLAY_CLIP_TO_ATTACHED_PARENT :: 1;

CLAY_RENDER_COMMAND_TYPE_NONE :: 0;
CLAY_RENDER_COMMAND_TYPE_RECTANGLE :: 1;
CLAY_RENDER_COMMAND_TYPE_BORDER :: 2;
CLAY_RENDER_COMMAND_TYPE_TEXT :: 3;
CLAY_RENDER_COMMAND_TYPE_IMAGE :: 4;
CLAY_RENDER_COMMAND_TYPE_SCISSOR_START :: 5;
CLAY_RENDER_COMMAND_TYPE_SCISSOR_END :: 6;
CLAY_RENDER_COMMAND_TYPE_CUSTOM :: 7;

CLAY_POINTER_DATA_PRESSED_THIS_FRAME :: 0;
CLAY_POINTER_DATA_PRESSED :: 1;
CLAY_POINTER_DATA_RELEASED_THIS_FRAME :: 2;
CLAY_POINTER_DATA_RELEASED :: 3;

CLAY_ERROR_TYPE_TEXT_MEASUREMENT_FUNCTION_NOT_PROVIDED :: 0;
CLAY_ERROR_TYPE_ARENA_CAPACITY_EXCEEDED :: 1;
CLAY_ERROR_TYPE_ELEMENTS_CAPACITY_EXCEEDED :: 2;
CLAY_ERROR_TYPE_TEXT_MEASUREMENT_CAPACITY_EXCEEDED :: 3;
CLAY_ERROR_TYPE_DUPLICATE_ID :: 4;
CLAY_ERROR_TYPE_FLOATING_CONTAINER_PARENT_NOT_FOUND :: 5;
CLAY_ERROR_TYPE_PERCENTAGE_OVER_1 :: 6;
CLAY_ERROR_TYPE_INTERNAL_ERROR :: 7;

_ElementConfigType :: u8;

CLAY__ELEMENT_CONFIG_TYPE_NONE :: 0;
CLAY__ELEMENT_CONFIG_TYPE_BORDER :: 1;
CLAY__ELEMENT_CONFIG_TYPE_FLOATING :: 2;
CLAY__ELEMENT_CONFIG_TYPE_CLIP :: 3;
CLAY__ELEMENT_CONFIG_TYPE_ASPECT :: 4;
CLAY__ELEMENT_CONFIG_TYPE_IMAGE :: 5;
CLAY__ELEMENT_CONFIG_TYPE_TEXT :: 6;
CLAY__ELEMENT_CONFIG_TYPE_CUSTOM :: 7;
CLAY__ELEMENT_CONFIG_TYPE_SHARED :: 8;
//@endregion
