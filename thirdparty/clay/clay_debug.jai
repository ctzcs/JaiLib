//
// clay_debug.jai — Clay v0.14 纯 Jai 移植（第七层：debug 视图）
//
// 移植自 olib: D:\MySpace\Github\olib\thirdparty\clay\clay_debug.odin (876 行)
// 上游: nicbarker/clay v0.14 (b25a31c1a152915cd7dd6796e6592273e5a10aac)。
// Copyright (c) 2024 Nic Barker. Altered source; see LICENSE.md and README.md。
//
// 这一层**只**给 `Clay_SetDebugModeEnabled(true)` 用：EndLayout 会先把 debug 面板
// 当成一棵正常的布局树塞进去（_RenderDebugView），再走同一套 _CalculateFinalLayout。
// 所以它对 arena 的分配次数、_StoreTextElementConfig 的调用次数都极其敏感——
// 任何多一次/少一次的分配都会让后续元素的 arena 偏移错位，最终 layout 结果不一致。
// 本文件里所有 `_StoreTextElementConfig` 的调用点与 olib 一一对应，没有合并、没有预计算。
//
// 语法映射（与前几层一致），另外三处本文件特有的：
//   1. `switch cast(i32)(x) { case A: … break … }` -> if / else-if 链
//      （Jai 的 if-case 里 break 会跳出外层循环，这里一律用 if 链最稳）。
//   2. `{ _OpenElement(); _ConfigureOpenElement(d); defer _CloseElement(); … }`
//      -> `UI(d, #code { … });`（clay.jai 里的宏，展开就是同样的三条语句，
//      defer 在展开块末尾触发。用宏是为了从根本上避免 100+ 个 open/close 手写配错）。
//   3. `cond ? a : b` 里的「按需 _StoreTextElementConfig」抽成
//      `_DebugViewRawTextConfig(offscreen)` / `_DebugViewTextColor(offscreen)`，
//      保证与 olib 一样**只在需要时**才调用一次（见各函数注释）。
//

//@region 小工具

// olib: ((cast(i32)(offscreen) != 0) ? CLAY__DEBUGVIEW_COLOR_3 : CLAY__DEBUGVIEW_COLOR_4)
_DebugViewTextColor :: (offscreen: bool) -> Color {
    if offscreen {
        return CLAY__DEBUGVIEW_COLOR_3;
    }
    return CLAY__DEBUGVIEW_COLOR_4;
}

// olib: ((cast(i32)(offscreen) != 0) ? _StoreTextElementConfig(…COLOR_3, 16…) : &_DebugView_TextNameConfig)
// ⚠ 这个函数在 offscreen 时会**真的**调用一次 _StoreTextElementConfig（即一次 arena 分配），
//   与 olib 的三元表达式惰性求值行为一致。
_DebugViewRawTextConfig :: (offscreen: bool) -> *TextElementConfig {
    if offscreen {
        return _StoreTextElementConfig(.{ textColor = CLAY__DEBUGVIEW_COLOR_3, fontSize = 16 });
    }
    return *_DebugView_TextNameConfig;
}

// 反复出现的 _StoreTextElementConfig(TextElementConfig{textColor = C, fontSize = 16})
_DebugViewSmallConfig :: (color: Color) -> *TextElementConfig {
    return _StoreTextElementConfig(.{ textColor = color, fontSize = 16 });
}

// 反复出现的 label 底片：color 但 alpha = 90
_DebugViewLabelColor :: (color: Color) -> Color {
    c := color;
    c[3] = cast(float) 90;
    return c;
}

// olib 里两段一模一样的 8 层 if/else 链（element 与 parent 的 attach point 名字）。
// 抽成一个函数：默认 "LEFT_TOP"（= CLAY_ATTACH_POINT_LEFT_TOP），其余按值精确匹配，
// 未知值（> 8）保持默认，与 olib 的链式判断完全相同。
_DebugAttachPointName :: (point: FloatingAttachPointType) -> String {
    if point == .LEFT_CENTER {
        return _static_string("LEFT_CENTER");
    }
    if point == .LEFT_BOTTOM {
        return _static_string("LEFT_BOTTOM");
    }
    if point == .CENTER_TOP {
        return _static_string("CENTER_TOP");
    }
    if point == .CENTER_CENTER {
        return _static_string("CENTER_CENTER");
    }
    if point == .CENTER_BOTTOM {
        return _static_string("CENTER_BOTTOM");
    }
    if point == .RIGHT_TOP {
        return _static_string("RIGHT_TOP");
    }
    if point == .RIGHT_CENTER {
        return _static_string("RIGHT_CENTER");
    }
    if point == .RIGHT_BOTTOM {
        return _static_string("RIGHT_BOTTOM");
    }
    return _static_string("LEFT_TOP");
}
//@endregion

//@region 布局树列表

// clay.h:3116 — Clay__DebugGetElementConfigTypeLabel
_DebugGetElementConfigTypeLabel :: (kind: _ElementConfigType) -> _DebugElementConfigTypeLabelConfig {
    if kind == CLAY__ELEMENT_CONFIG_TYPE_SHARED {
        return .{ label = _static_string("Shared"), color = .[243, 134, 48, 255] };
    }
    if kind == CLAY__ELEMENT_CONFIG_TYPE_TEXT {
        return .{ label = _static_string("Text"), color = .[105, 210, 231, 255] };
    }
    if kind == CLAY__ELEMENT_CONFIG_TYPE_ASPECT {
        return .{ label = _static_string("Aspect"), color = .[101, 149, 194, 255] };
    }
    if kind == CLAY__ELEMENT_CONFIG_TYPE_IMAGE {
        return .{ label = _static_string("Image"), color = .[121, 189, 154, 255] };
    }
    if kind == CLAY__ELEMENT_CONFIG_TYPE_FLOATING {
        return .{ label = _static_string("Floating"), color = .[250, 105, 0, 255] };
    }
    if kind == CLAY__ELEMENT_CONFIG_TYPE_CLIP {
        return .{ label = _static_string("Scroll"), color = .[242, 196, 90, 255] };
    }
    if kind == CLAY__ELEMENT_CONFIG_TYPE_BORDER {
        return .{ label = _static_string("Border"), color = .[108, 91, 123, 255] };
    }
    if kind == CLAY__ELEMENT_CONFIG_TYPE_CUSTOM {
        return .{ label = _static_string("Custom"), color = .[11, 72, 107, 255] };
    }
    return .{ label = _static_string("Error"), color = .[0, 0, 0, 255] };
}

// clay.h:3137 — Clay__RenderDebugLayoutElementsList
//
// 移植注记：
//   * 外层 `for rootIndex: i32 = 0; rootIndex < initialRootsLength; rootIndex += 1`
//     体内没有 continue → while + 末尾自增，等价。
//   * DFS `for (dfsBuffer.length > 0)` 只有条件 → while，里面的 continue 照抄。
//   * 内层 `for elementConfigIndex` 体里 SHARED 分支原本用 `continue` 跳过通用 label；
//     这里改成 if / else，效果完全一样（且省掉手动补自增的坑）。
_RenderDebugLayoutElementsList :: (initialRootsLength: s32, highlightedRowIndex: s32) -> _RenderDebugLayoutData {
    ctx := GetCurrentContext();
    dfsBuffer: _int32_tArray = ctx.reusableElementIndexBuffer;
    _DebugView_ScrollViewItemLayoutConfig = .{
        sizing = .{ height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT, max = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT } }, type = .FIXED } },
        childGap = 6,
        childAlignment = .{ y = .CENTER },
    };
    layoutData: _RenderDebugLayoutData = .{ rowCount = 0 };
    highlightedElementId: u32 = 0;
    rootIndex: s32 = 0;
    while rootIndex < initialRootsLength {
        dfsBuffer.length = 0;
        root := _LayoutElementTreeRootArray_Get(*ctx.layoutElementTreeRoots, rootIndex);
        _int32_tArray_Add(*dfsBuffer, root.layoutElementIndex);
        ctx.treeNodeVisited.internalArray[0] = false;
        if rootIndex > 0 {
            UI(.{
                id = _HashString(_static_string("Clay__DebugView_EmptyRowOuter"), cast(u32) rootIndex, 0),
                layout = .{
                    sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW } },
                    padding = .{ left = cast(u16) (CLAY__DEBUGVIEW_INDENT_WIDTH / 2), right = 0, top = 0, bottom = 0 },
                },
            }, #code {
                UI(.{
                    id = _HashString(_static_string("Clay__DebugView_EmptyRow"), cast(u32) rootIndex, 0),
                    layout = .{
                        sizing = .{
                            width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                            height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT, max = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT } }, type = .FIXED },
                        },
                    },
                    border = .{ color = CLAY__DEBUGVIEW_COLOR_3, width = .{ top = 1 } },
                }, #code {});
            });
            layoutData.rowCount += 1;
        }
        while dfsBuffer.length > 0 {
            currentElementIndex := _int32_tArray_GetValue(*dfsBuffer, dfsBuffer.length - 1);
            currentElement := LayoutElementArray_Get(*ctx.layoutElements, currentElementIndex);
            if ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] {
                if !_ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT)
                && currentElement.childrenOrTextContent.children.length > 0 {
                    _CloseElement();
                    _CloseElement();
                    _CloseElement();
                }
                dfsBuffer.length -= 1;
                continue;
            }
            if highlightedRowIndex == layoutData.rowCount {
                if ctx.pointerInfo.state == .PRESSED_THIS_FRAME {
                    ctx.debugSelectedElementId = currentElement.id;
                }
                highlightedElementId = currentElement.id;
            }
            ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = true;
            currentElementData := _GetHashMapItem(currentElement.id);
            offscreen := _ElementIsOffscreen(*currentElementData.boundingBox);
            if ctx.debugSelectedElementId == currentElement.id {
                layoutData.selectedElementRowIndex = layoutData.rowCount;
            }
            UI(.{
                id = _HashString(_static_string("Clay__DebugView_ElementOuter"), currentElement.id, 0),
                layout = _DebugView_ScrollViewItemLayoutConfig,
            }, #code {
                // Collapse icon / button
                if !(_ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT)
                || currentElement.childrenOrTextContent.children.length == 0) {
                    UI(.{
                        id = _HashString(_static_string("Clay__DebugView_CollapseElement"), currentElement.id, 0),
                        layout = .{
                            sizing = .{
                                width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 16, max = cast(float) 16 } }, type = .FIXED },
                                height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 16, max = cast(float) 16 } }, type = .FIXED },
                            },
                            childAlignment = .{ x = .CENTER, y = .CENTER },
                        },
                        cornerRadius = CornerRadiusAll(4),
                        border = .{ color = CLAY__DEBUGVIEW_COLOR_3, width = .{ left = 1, right = 1, top = 1, bottom = 1, betweenChildren = 0 } },
                    }, #code {
                        // olib: ((currentElementData != nil) && collapsed) ? "+" : "-"
                        if currentElementData != null && currentElementData.debugData.collapsed {
                            _OpenTextElement(_static_string("+"), _StoreTextElementConfig(.{ textColor = CLAY__DEBUGVIEW_COLOR_4, fontSize = 16 }));
                        } else {
                            _OpenTextElement(_static_string("-"), _StoreTextElementConfig(.{ textColor = CLAY__DEBUGVIEW_COLOR_4, fontSize = 16 }));
                        }
                    });
                } else {
                    UI(.{
                        layout = .{
                            sizing = .{
                                width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 16, max = cast(float) 16 } }, type = .FIXED },
                                height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 16, max = cast(float) 16 } }, type = .FIXED },
                            },
                            childAlignment = .{ x = .CENTER, y = .CENTER },
                        },
                    }, #code {
                        UI(.{
                            layout = .{
                                sizing = .{
                                    width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 8, max = cast(float) 8 } }, type = .FIXED },
                                    height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 8, max = cast(float) 8 } }, type = .FIXED },
                                },
                            },
                            backgroundColor = CLAY__DEBUGVIEW_COLOR_3,
                            cornerRadius = CornerRadiusAll(2),
                        }, #code {});
                    });
                }
                // Collisions and offscreen info
                if currentElementData != null {
                    if currentElementData.debugData.collision {
                        UI(.{
                            layout = .{ padding = .{ left = 8, right = 8, top = 2, bottom = 2 } },
                            border = .{ color = .[177, 147, 8, 255], width = .{ left = 1, right = 1, top = 1, bottom = 1, betweenChildren = 0 } },
                        }, #code {
                            _OpenTextElement(_static_string("Duplicate ID"), _DebugViewSmallConfig(CLAY__DEBUGVIEW_COLOR_3));
                        });
                    }
                    if offscreen {
                        UI(.{
                            layout = .{ padding = .{ left = 8, right = 8, top = 2, bottom = 2 } },
                            border = .{ color = CLAY__DEBUGVIEW_COLOR_3, width = .{ left = 1, right = 1, top = 1, bottom = 1, betweenChildren = 0 } },
                        }, #code {
                            _OpenTextElement(_static_string("Offscreen"), _DebugViewSmallConfig(CLAY__DEBUGVIEW_COLOR_3));
                        });
                    }
                }
                idString := ctx.layoutElementIdStrings.internalArray[currentElementIndex];
                if idString.length > 0 {
                    _OpenTextElement(idString, _DebugViewRawTextConfig(offscreen));
                }
                elementConfigIndex: s32 = 0;
                while elementConfigIndex < currentElement.elementConfigs.length {
                    elementConfig := _ElementConfigArraySlice_Get(*currentElement.elementConfigs, elementConfigIndex);
                    if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_SHARED {
                        labelColor: Color = .[243, 134, 48, 90];
                        labelColor[3] = cast(float) 90;
                        backgroundColor := elementConfig.config.sharedElementConfig.backgroundColor;
                        radius := elementConfig.config.sharedElementConfig.cornerRadius;
                        if backgroundColor[3] > cast(float) 0 {
                            UI(.{
                                layout = .{ padding = .{ left = 8, right = 8, top = 2, bottom = 2 } },
                                backgroundColor = labelColor,
                                cornerRadius = CornerRadiusAll(4),
                                border = .{ color = labelColor, width = .{ left = 1, right = 1, top = 1, bottom = 1, betweenChildren = 0 } },
                            }, #code {
                                _OpenTextElement(_static_string("Color"), _DebugViewSmallConfig(_DebugViewTextColor(offscreen)));
                            });
                        }
                        if radius.bottomLeft > cast(float) 0 {
                            UI(.{
                                layout = .{ padding = .{ left = 8, right = 8, top = 2, bottom = 2 } },
                                backgroundColor = labelColor,
                                cornerRadius = CornerRadiusAll(4),
                                border = .{ color = labelColor, width = .{ left = 1, right = 1, top = 1, bottom = 1, betweenChildren = 0 } },
                            }, #code {
                                _OpenTextElement(_static_string("Radius"), _DebugViewSmallConfig(_DebugViewTextColor(offscreen)));
                            });
                        }
                    } else {
                        config := _DebugGetElementConfigTypeLabel(elementConfig.type);
                        backgroundColor := _DebugViewLabelColor(config.color);
                        UI(.{
                            layout = .{ padding = .{ left = 8, right = 8, top = 2, bottom = 2 } },
                            backgroundColor = backgroundColor,
                            cornerRadius = CornerRadiusAll(4),
                            border = .{ color = config.color, width = .{ left = 1, right = 1, top = 1, bottom = 1, betweenChildren = 0 } },
                        }, #code {
                            _OpenTextElement(config.label, _DebugViewSmallConfig(_DebugViewTextColor(offscreen)));
                        });
                    }
                    elementConfigIndex += 1;
                }
            });
            // Render the text contents below the element as a non-interactive row
            if _ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT) {
                layoutData.rowCount += 1;
                textElementData := currentElement.childrenOrTextContent.textElementData;
                rawTextConfig := _DebugViewRawTextConfig(offscreen);
                UI(.{
                    layout = .{
                        sizing = .{ height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT, max = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT } }, type = .FIXED } },
                        childAlignment = .{ y = .CENTER },
                    },
                }, #code {
                    UI(.{
                        layout = .{
                            sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) (CLAY__DEBUGVIEW_INDENT_WIDTH + 16), max = cast(float) (CLAY__DEBUGVIEW_INDENT_WIDTH + 16) } }, type = .FIXED } },
                        },
                    }, #code {});
                    _OpenTextElement(_static_string("\""), rawTextConfig);
                    // olib: (text.length > 40) ? String{length = 40, chars = text.chars} : text
                    if textElementData.text.length > 40 {
                        _OpenTextElement(.{ length = 40, chars = textElementData.text.chars }, rawTextConfig);
                    } else {
                        _OpenTextElement(textElementData.text, rawTextConfig);
                    }
                    if textElementData.text.length > 40 {
                        _OpenTextElement(_static_string("..."), rawTextConfig);
                    }
                    _OpenTextElement(_static_string("\""), rawTextConfig);
                });
            } else {
                // ⚠ 这三个 open 故意**不**关闭：由上面 treeNodeVisited 分支里的
                // 三次 _CloseElement() 收尾（olib 原样如此）。
                if currentElement.childrenOrTextContent.children.length > 0 {
                    _OpenElement();
                    _ConfigureOpenElement(.{ layout = .{ padding = .{ left = 8 } } });
                    _OpenElement();
                    _ConfigureOpenElement(.{
                        layout = .{ padding = .{ left = cast(u16) CLAY__DEBUGVIEW_INDENT_WIDTH } },
                        border = .{ color = CLAY__DEBUGVIEW_COLOR_3, width = .{ left = 1 } },
                    });
                    _OpenElement();
                    _ConfigureOpenElement(.{ layout = .{ layoutDirection = .TOP_TO_BOTTOM } });
                }
            }
            layoutData.rowCount += 1;
            if !(_ElementHasConfig(currentElement, CLAY__ELEMENT_CONFIG_TYPE_TEXT)
            || (currentElementData != null && currentElementData.debugData.collapsed)) {
                i := cast(s32) currentElement.childrenOrTextContent.children.length - 1;
                while i >= 0 {
                    _int32_tArray_Add(*dfsBuffer, currentElement.childrenOrTextContent.children.elements[i]);
                    ctx.treeNodeVisited.internalArray[dfsBuffer.length - 1] = false;
                    i -= 1;
                }
            }
        }
        rootIndex += 1;
    }
    if ctx.pointerInfo.state == .PRESSED_THIS_FRAME {
        collapseButtonId := _HashString(_static_string("Clay__DebugView_CollapseElement"), 0, 0);
        i := ctx.pointerOverIds.length - 1;
        while i >= 0 {
            elementId := ElementIdArray_Get(*ctx.pointerOverIds, i);
            if elementId.baseId == collapseButtonId.baseId {
                highlightedItem := _GetHashMapItem(elementId.offset);
                highlightedItem.debugData.collapsed = !highlightedItem.debugData.collapsed;
                break;
            }
            i -= 1;
        }
    }
    if highlightedElementId != 0 {
        UI(.{
            id = _HashString(_static_string("Clay__DebugView_ElementHighlight"), 0, 0),
            layout = .{
                sizing = .{
                    width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                    height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                },
            },
            floating = .{
                parentId = highlightedElementId,
                zIndex = 32767,
                pointerCaptureMode = .PASSTHROUGH,
                attachTo = .ELEMENT_WITH_ID,
            },
        }, #code {
            UI(.{
                id = _HashString(_static_string("Clay__DebugView_ElementHighlightRectangle"), 0, 0),
                layout = .{
                    sizing = .{
                        width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                        height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                    },
                },
                backgroundColor = _debugViewHighlightColor,
            }, #code {});
        });
    }
    return layoutData;
}
//@endregion

//@region 属性视图

// clay.h:3296 — Clay__RenderDebugLayoutSizing
_RenderDebugLayoutSizing :: (sizing: SizingAxis, infoTextConfig: *TextElementConfig) {
    sizingLabel := _static_string("GROW");
    if sizing.type == .FIT {
        sizingLabel = _static_string("FIT");
    } else if sizing.type == .PERCENT {
        sizingLabel = _static_string("PERCENT");
    } else if sizing.type == .FIXED {
        sizingLabel = _static_string("FIXED");
    }
    _OpenTextElement(sizingLabel, infoTextConfig);
    if sizing.type == .GROW || sizing.type == .FIT || sizing.type == .FIXED {
        _OpenTextElement(_static_string("("), infoTextConfig);
        if sizing.constraints.sizeMinMax.min != cast(float) 0 {
            _OpenTextElement(_static_string("min: "), infoTextConfig);
            _OpenTextElement(_IntToString(cast(s32) sizing.constraints.sizeMinMax.min), infoTextConfig);
            if sizing.constraints.sizeMinMax.max != _CLAY_MAX_FLOAT {
                _OpenTextElement(_static_string(", "), infoTextConfig);
            }
        }
        if sizing.constraints.sizeMinMax.max != _CLAY_MAX_FLOAT {
            _OpenTextElement(_static_string("max: "), infoTextConfig);
            _OpenTextElement(_IntToString(cast(s32) sizing.constraints.sizeMinMax.max), infoTextConfig);
        }
        _OpenTextElement(_static_string(")"), infoTextConfig);
    } else if sizing.type == .PERCENT {
        _OpenTextElement(_static_string("("), infoTextConfig);
        _OpenTextElement(_IntToString(cast(s32) (sizing.constraints.sizePercent * cast(float) 100)), infoTextConfig);
        _OpenTextElement(_static_string("%)"), infoTextConfig);
    }
}

// clay.h:3327 — Clay__RenderDebugViewElementConfigHeader
_RenderDebugViewElementConfigHeader :: (elementId: String, kind: _ElementConfigType) {
    config := _DebugGetElementConfigTypeLabel(kind);
    backgroundColor := _DebugViewLabelColor(config.color);
    UI(.{
        layout = .{
            sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW } },
            padding = .{
                left = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                right = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                top = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                bottom = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
            },
            childAlignment = .{ y = .CENTER },
        },
    }, #code {
        UI(.{
            layout = .{ padding = .{ left = 8, right = 8, top = 2, bottom = 2 } },
            backgroundColor = backgroundColor,
            cornerRadius = CornerRadiusAll(4),
            border = .{ color = config.color, width = .{ left = 1, right = 1, top = 1, bottom = 1, betweenChildren = 0 } },
        }, #code {
            _OpenTextElement(config.label, _StoreTextElementConfig(.{ textColor = CLAY__DEBUGVIEW_COLOR_4, fontSize = 16 }));
        });
        UI(.{
            layout = .{ sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW } } },
        }, #code {});
        _OpenTextElement(elementId, _StoreTextElementConfig(.{ textColor = CLAY__DEBUGVIEW_COLOR_3, fontSize = 16, wrapMode = .NONE }));
    });
}

// clay.h:3340 — Clay__RenderDebugViewColor
_RenderDebugViewColor :: (color: Color, textConfig: *TextElementConfig) {
    UI(.{
        layout = .{ childAlignment = .{ y = .CENTER } },
    }, #code {
        _OpenTextElement(_static_string("{ r: "), textConfig);
        _OpenTextElement(_IntToString(cast(s32) color[0]), textConfig);
        _OpenTextElement(_static_string(", g: "), textConfig);
        _OpenTextElement(_IntToString(cast(s32) color[1]), textConfig);
        _OpenTextElement(_static_string(", b: "), textConfig);
        _OpenTextElement(_IntToString(cast(s32) color[2]), textConfig);
        _OpenTextElement(_static_string(", a: "), textConfig);
        _OpenTextElement(_IntToString(cast(s32) color[3]), textConfig);
        _OpenTextElement(_static_string(" }"), textConfig);
        UI(.{
            layout = .{ sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 10, max = cast(float) 10 } }, type = .FIXED } } },
        }, #code {});
        UI(.{
            layout = .{
                sizing = .{
                    width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT - 8), max = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT - 8) } }, type = .FIXED },
                    height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT - 8), max = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT - 8) } }, type = .FIXED },
                },
            },
            backgroundColor = color,
            cornerRadius = CornerRadiusAll(4),
            border = .{ color = CLAY__DEBUGVIEW_COLOR_4, width = .{ left = 1, right = 1, top = 1, bottom = 1, betweenChildren = 0 } },
        }, #code {});
    });
}

// clay.h:3356 — Clay__RenderDebugViewCornerRadius
_RenderDebugViewCornerRadius :: (cornerRadius: CornerRadius, textConfig: *TextElementConfig) {
    UI(.{
        layout = .{ childAlignment = .{ y = .CENTER } },
    }, #code {
        _OpenTextElement(_static_string("{ topLeft: "), textConfig);
        _OpenTextElement(_IntToString(cast(s32) cornerRadius.topLeft), textConfig);
        _OpenTextElement(_static_string(", topRight: "), textConfig);
        _OpenTextElement(_IntToString(cast(s32) cornerRadius.topRight), textConfig);
        _OpenTextElement(_static_string(", bottomLeft: "), textConfig);
        _OpenTextElement(_IntToString(cast(s32) cornerRadius.bottomLeft), textConfig);
        _OpenTextElement(_static_string(", bottomRight: "), textConfig);
        _OpenTextElement(_IntToString(cast(s32) cornerRadius.bottomRight), textConfig);
        _OpenTextElement(_static_string(" }"), textConfig);
    });
}

// clay.h:3370 — HandleDebugViewCloseButtonInteraction
//
// olib 在这里 `_ = elementId; _ = pointerInfo; _ = userData`（只用到 pointerInfo.state，
// 前两个参数纯占位）。Jai 不要求消费参数，所以直接不引用即可。
HandleDebugViewCloseButtonInteraction :: (elementId: ElementId, pointerInfo: PointerData, userData: *void) {
    ctx := GetCurrentContext();
    if pointerInfo.state == .PRESSED_THIS_FRAME {
        ctx.debugModeEnabled = false;
    }
}
//@endregion

//@region 调试面板

// clay.h:3378 — Clay__RenderDebugView
_RenderDebugView :: () {
    ctx := GetCurrentContext();
    closeButtonId := _HashString(_static_string("Clay__DebugViewTopHeaderCloseButtonOuter"), 0, 0);
    if ctx.pointerInfo.state == .PRESSED_THIS_FRAME {
        i: s32 = 0;
        while i < ctx.pointerOverIds.length {
            elementId := ElementIdArray_Get(*ctx.pointerOverIds, i);
            if elementId.id == closeButtonId.id {
                ctx.debugModeEnabled = false;
                return;
            }
            i += 1;
        }
    }
    initialRootsLength: u32 = cast(u32) ctx.layoutElementTreeRoots.length;
    initialElementsLength: u32 = cast(u32) ctx.layoutElements.length;
    infoTextConfig := _StoreTextElementConfig(.{ textColor = CLAY__DEBUGVIEW_COLOR_4, fontSize = 16, wrapMode = .NONE });
    infoTitleConfig := _StoreTextElementConfig(.{ textColor = CLAY__DEBUGVIEW_COLOR_3, fontSize = 16, wrapMode = .NONE });
    scrollId := _HashString(_static_string("Clay__DebugViewOuterScrollPane"), 0, 0);
    scrollYOffset := cast(float) 0;
    pointerInDebugView := ctx.pointerInfo.position[1] < (ctx.layoutDimensions.height - cast(float) 300);
    i: s32 = 0;
    while i < ctx.scrollContainerDatas.length {
        scrollContainerData := _ScrollContainerDataInternalArray_Get(*ctx.scrollContainerDatas, i);
        if scrollContainerData.elementId == scrollId.id {
            if !ctx.externalScrollHandlingEnabled {
                scrollYOffset = scrollContainerData.scrollPosition[1];
            } else {
                pointerInDebugView = (ctx.pointerInfo.position[1] + scrollContainerData.scrollPosition[1]) < (ctx.layoutDimensions.height - cast(float) 300);
            }
            break;
        }
        i += 1;
    }
    // olib: (pointerInDebugView ? cast(i32)((pos[1]-offset)/ROW_HEIGHT) - 1 : -1)
    highlightedRow: s32 = -1;
    if pointerInDebugView {
        highlightedRow = cast(s32) ((ctx.pointerInfo.position[1] - scrollYOffset) / cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT) - 1;
    }
    if ctx.pointerInfo.position[0] < (ctx.layoutDimensions.width - cast(float) _debugViewWidth) {
        highlightedRow = -1;
    }
    layoutData: _RenderDebugLayoutData = .{ rowCount = 0 };
    UI(.{
        id = _HashString(_static_string("Clay__DebugView"), 0, 0),
        layout = .{
            sizing = .{
                width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) _debugViewWidth, max = cast(float) _debugViewWidth } }, type = .FIXED },
                height = .{ constraints = .{ sizeMinMax = .{ min = ctx.layoutDimensions.height, max = ctx.layoutDimensions.height } }, type = .FIXED },
            },
            layoutDirection = .TOP_TO_BOTTOM,
        },
        floating = .{
            zIndex = 32765,
            attachment = .{ element = .LEFT_CENTER, parent = .RIGHT_CENTER },
            attachTo = .ROOT,
            clipTo = .ATTACHED_PARENT,
        },
        border = .{ color = CLAY__DEBUGVIEW_COLOR_3, width = .{ bottom = 1 } },
    }, #code {
        UI(.{
            layout = .{
                sizing = .{
                    width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                    height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT, max = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT } }, type = .FIXED },
                },
                padding = .{
                    left = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                    right = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                    top = 0,
                    bottom = 0,
                },
                childAlignment = .{ y = .CENTER },
            },
            backgroundColor = CLAY__DEBUGVIEW_COLOR_2,
        }, #code {
            _OpenTextElement(_static_string("Clay Debug Tools"), infoTextConfig);
            UI(.{
                layout = .{ sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW } } },
            }, #code {});
            UI(.{
                layout = .{
                    sizing = .{
                        width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT - 10), max = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT - 10) } }, type = .FIXED },
                        height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT - 10), max = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT - 10) } }, type = .FIXED },
                    },
                    childAlignment = .{ x = .CENTER, y = .CENTER },
                },
                backgroundColor = .[217, 91, 67, 80],
                cornerRadius = CornerRadiusAll(4),
                border = .{ color = .[217, 91, 67, 255], width = .{ left = 1, right = 1, top = 1, bottom = 1, betweenChildren = 0 } },
            }, #code {
                OnHover(HandleDebugViewCloseButtonInteraction, null);
                _OpenTextElement(_static_string("x"), _StoreTextElementConfig(.{ textColor = CLAY__DEBUGVIEW_COLOR_4, fontSize = 16 }));
            });
        });
        UI(.{
            layout = .{
                sizing = .{
                    width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                    height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 1, max = cast(float) 1 } }, type = .FIXED },
                },
            },
            backgroundColor = CLAY__DEBUGVIEW_COLOR_3,
        }, #code {});
        UI(.{
            id = scrollId,
            layout = .{
                sizing = .{
                    width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                    height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                },
            },
            clip = .{ horizontal = true, vertical = true, childOffset = GetScrollOffset() },
        }, #code {
            // olib: (((initialElementsLength + initialRootsLength) & 1) == 0) ? COLOR_2 : COLOR_1
            // 这个三元表达式在 olib 里是在 _OpenElement() 之前求值的（只读，不分配 arena），
            // 放成局部变量即可，分配顺序不变。
            panelBackground: Color = CLAY__DEBUGVIEW_COLOR_1;
            if ((initialElementsLength + initialRootsLength) & 1) == 0 {
                panelBackground = CLAY__DEBUGVIEW_COLOR_2;
            }
            UI(.{
                layout = .{
                    sizing = .{
                        width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                        height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                    },
                    layoutDirection = .TOP_TO_BOTTOM,
                },
                backgroundColor = panelBackground,
            }, #code {
                panelContentsId := _HashString(_static_string("Clay__DebugViewPaneOuter"), 0, 0);
                UI(.{
                    id = panelContentsId,
                    layout = .{
                        sizing = .{
                            width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                            height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                        },
                    },
                    floating = .{
                        zIndex = 32766,
                        pointerCaptureMode = .PASSTHROUGH,
                        attachTo = .PARENT,
                        clipTo = .ATTACHED_PARENT,
                    },
                }, #code {
                    UI(.{
                        layout = .{
                            sizing = .{
                                width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                                height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                            },
                            padding = .{
                                left = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                                right = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                                top = 0,
                                bottom = 0,
                            },
                            layoutDirection = .TOP_TO_BOTTOM,
                        },
                    }, #code {
                        layoutData = _RenderDebugLayoutElementsList(cast(s32) initialRootsLength, highlightedRow);
                    });
                });
                contentWidth := _GetHashMapItem(panelContentsId.id).layoutElement.dimensions.width;
                // ⚠ 迁移注记：olib 这里是
                //     { _OpenElement(); _ConfigureOpenElement(行背景列); defer _CloseElement() }
                // ——「行背景列」是**没有子元素**的空元素（宽 contentWidth、高 0），开完立刻关；
                // 紧跟着 for 循环创建的行背景是它的**兄弟**，不是子元素。
                // 早期移植把整个行循环塞进了这一层的 #code { } 里，等于多造了一层父子关系：
                // 匿名元素 id = hash(父元素 id, 兄弟序号)，父元素一换，整批行的 id 全部错位，
                // 32 行被吞进同一个父元素（对拍里表现为 ELEM 221 h=960000 nchild=32）。
                // 这里用空 #code 让宏的 defer 立刻配对，行循环留在外层。
                UI(.{
                    layout = .{
                        sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = contentWidth, max = contentWidth } }, type = .FIXED } },
                        layoutDirection = .TOP_TO_BOTTOM,
                    },
                }, #code {});
                rowIndex: s32 = 0;
                while rowIndex < layoutData.rowCount {
                    // olib: ((i & 1) == 0) ? COLOR_2 : COLOR_1
                    rowColor: Color = CLAY__DEBUGVIEW_COLOR_1;
                    if (rowIndex & 1) == 0 {
                        rowColor = CLAY__DEBUGVIEW_COLOR_2;
                    }
                    if rowIndex == layoutData.selectedElementRowIndex {
                        rowColor = CLAY__DEBUGVIEW_COLOR_SELECTED_ROW;
                    }
                    if rowIndex == highlightedRow {
                        rowColor[0] *= cast(float) 1.25;
                        rowColor[1] *= cast(float) 1.25;
                        rowColor[2] *= cast(float) 1.25;
                    }
                    UI(.{
                        layout = .{
                            sizing = .{
                                width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                                height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT, max = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT } }, type = .FIXED },
                            },
                            layoutDirection = .TOP_TO_BOTTOM,
                        },
                        backgroundColor = rowColor,
                    }, #code {});
                    rowIndex += 1;
                }
            });
        });
        UI(.{
            layout = .{
                sizing = .{
                    width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                    height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 1, max = cast(float) 1 } }, type = .FIXED },
                },
            },
            backgroundColor = CLAY__DEBUGVIEW_COLOR_3,
        }, #code {});
        if ctx.debugSelectedElementId != 0 {
            selectedItem := _GetHashMapItem(ctx.debugSelectedElementId);
            UI(.{
                layout = .{
                    sizing = .{
                        width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                        height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 300, max = cast(float) 300 } }, type = .FIXED },
                    },
                    layoutDirection = .TOP_TO_BOTTOM,
                },
                backgroundColor = CLAY__DEBUGVIEW_COLOR_2,
                clip = .{ vertical = true, childOffset = GetScrollOffset() },
                border = .{ color = CLAY__DEBUGVIEW_COLOR_3, width = .{ betweenChildren = 1 } },
            }, #code {
                UI(.{
                    layout = .{
                        sizing = .{
                            width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                            height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT + 8), max = cast(float) (CLAY__DEBUGVIEW_ROW_HEIGHT + 8) } }, type = .FIXED },
                        },
                        padding = .{
                            left = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                            right = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                            top = 0,
                            bottom = 0,
                        },
                        childAlignment = .{ y = .CENTER },
                    },
                }, #code {
                    _OpenTextElement(_static_string("Layout Config"), infoTextConfig);
                    UI(.{
                        layout = .{ sizing = .{ width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW } } },
                    }, #code {});
                    if selectedItem.elementId.stringId.length != 0 {
                        _OpenTextElement(selectedItem.elementId.stringId, infoTitleConfig);
                        if selectedItem.elementId.offset != 0 {
                            _OpenTextElement(_static_string(" ("), infoTitleConfig);
                            _OpenTextElement(_IntToString(cast(s32) selectedItem.elementId.offset), infoTitleConfig);
                            _OpenTextElement(_static_string(")"), infoTitleConfig);
                        }
                    }
                });
                attributeConfigPadding: Padding = .{
                    left = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                    right = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                    top = 8,
                    bottom = 8,
                };
                UI(.{
                    layout = .{ padding = attributeConfigPadding, childGap = 8, layoutDirection = .TOP_TO_BOTTOM },
                }, #code {
                    _OpenTextElement(_static_string("Bounding Box"), infoTitleConfig);
                    UI(.{
                        layout = .{ layoutDirection = .LEFT_TO_RIGHT },
                    }, #code {
                        _OpenTextElement(_static_string("{ x: "), infoTextConfig);
                        _OpenTextElement(_IntToString(cast(s32) selectedItem.boundingBox.x), infoTextConfig);
                        _OpenTextElement(_static_string(", y: "), infoTextConfig);
                        _OpenTextElement(_IntToString(cast(s32) selectedItem.boundingBox.y), infoTextConfig);
                        _OpenTextElement(_static_string(", width: "), infoTextConfig);
                        _OpenTextElement(_IntToString(cast(s32) selectedItem.boundingBox.width), infoTextConfig);
                        _OpenTextElement(_static_string(", height: "), infoTextConfig);
                        _OpenTextElement(_IntToString(cast(s32) selectedItem.boundingBox.height), infoTextConfig);
                        _OpenTextElement(_static_string(" }"), infoTextConfig);
                    });
                    _OpenTextElement(_static_string("Layout Direction"), infoTitleConfig);
                    layoutConfig := selectedItem.layoutElement.layoutConfig;
                    // olib: (layoutDirection == TOP_TO_BOTTOM) ? "TOP_TO_BOTTOM" : "LEFT_TO_RIGHT"
                    if layoutConfig.layoutDirection == .TOP_TO_BOTTOM {
                        _OpenTextElement(_static_string("TOP_TO_BOTTOM"), infoTextConfig);
                    } else {
                        _OpenTextElement(_static_string("LEFT_TO_RIGHT"), infoTextConfig);
                    }
                    _OpenTextElement(_static_string("Sizing"), infoTitleConfig);
                    UI(.{
                        layout = .{ layoutDirection = .LEFT_TO_RIGHT },
                    }, #code {
                        _OpenTextElement(_static_string("width: "), infoTextConfig);
                        _RenderDebugLayoutSizing(layoutConfig.sizing.width, infoTextConfig);
                    });
                    UI(.{
                        layout = .{ layoutDirection = .LEFT_TO_RIGHT },
                    }, #code {
                        _OpenTextElement(_static_string("height: "), infoTextConfig);
                        _RenderDebugLayoutSizing(layoutConfig.sizing.height, infoTextConfig);
                    });
                    _OpenTextElement(_static_string("Padding"), infoTitleConfig);
                    UI(.{
                        id = _HashString(_static_string("Clay__DebugViewElementInfoPadding"), 0, 0),
                    }, #code {
                        _OpenTextElement(_static_string("{ left: "), infoTextConfig);
                        _OpenTextElement(_IntToString(cast(s32) layoutConfig.padding.left), infoTextConfig);
                        _OpenTextElement(_static_string(", right: "), infoTextConfig);
                        _OpenTextElement(_IntToString(cast(s32) layoutConfig.padding.right), infoTextConfig);
                        _OpenTextElement(_static_string(", top: "), infoTextConfig);
                        _OpenTextElement(_IntToString(cast(s32) layoutConfig.padding.top), infoTextConfig);
                        _OpenTextElement(_static_string(", bottom: "), infoTextConfig);
                        _OpenTextElement(_IntToString(cast(s32) layoutConfig.padding.bottom), infoTextConfig);
                        _OpenTextElement(_static_string(" }"), infoTextConfig);
                    });
                    _OpenTextElement(_static_string("Child Gap"), infoTitleConfig);
                    _OpenTextElement(_IntToString(cast(s32) layoutConfig.childGap), infoTextConfig);
                    _OpenTextElement(_static_string("Child Alignment"), infoTitleConfig);
                    UI(.{
                        layout = .{ layoutDirection = .LEFT_TO_RIGHT },
                    }, #code {
                        _OpenTextElement(_static_string("{ x: "), infoTextConfig);
                        alignX := _static_string("LEFT");
                        if layoutConfig.childAlignment.x == .CENTER {
                            alignX = _static_string("CENTER");
                        } else if layoutConfig.childAlignment.x == .RIGHT {
                            alignX = _static_string("RIGHT");
                        }
                        _OpenTextElement(alignX, infoTextConfig);
                        _OpenTextElement(_static_string(", y: "), infoTextConfig);
                        alignY := _static_string("TOP");
                        if layoutConfig.childAlignment.y == .CENTER {
                            alignY = _static_string("CENTER");
                        } else if layoutConfig.childAlignment.y == .BOTTOM {
                            alignY = _static_string("BOTTOM");
                        }
                        _OpenTextElement(alignY, infoTextConfig);
                        _OpenTextElement(_static_string(" }"), infoTextConfig);
                    });
                });
                elementConfigIndex: s32 = 0;
                while elementConfigIndex < selectedItem.layoutElement.elementConfigs.length {
                    elementConfig := _ElementConfigArraySlice_Get(*selectedItem.layoutElement.elementConfigs, elementConfigIndex);
                    _RenderDebugViewElementConfigHeader(selectedItem.elementId.stringId, elementConfig.type);
                    // olib 是 switch + 每个 case 里 break（只跳出 switch）；Jai 用 if 链。
                    if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_SHARED {
                        sharedConfig := elementConfig.config.sharedElementConfig;
                        UI(.{
                            layout = .{ padding = attributeConfigPadding, childGap = 8, layoutDirection = .TOP_TO_BOTTOM },
                        }, #code {
                            _OpenTextElement(_static_string("Background Color"), infoTitleConfig);
                            _RenderDebugViewColor(sharedConfig.backgroundColor, infoTextConfig);
                            _OpenTextElement(_static_string("Corner Radius"), infoTitleConfig);
                            _RenderDebugViewCornerRadius(sharedConfig.cornerRadius, infoTextConfig);
                        });
                    } else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_TEXT {
                        textConfig := elementConfig.config.textElementConfig;
                        UI(.{
                            layout = .{ padding = attributeConfigPadding, childGap = 8, layoutDirection = .TOP_TO_BOTTOM },
                        }, #code {
                            _OpenTextElement(_static_string("Font Size"), infoTitleConfig);
                            _OpenTextElement(_IntToString(cast(s32) textConfig.fontSize), infoTextConfig);
                            _OpenTextElement(_static_string("Font ID"), infoTitleConfig);
                            _OpenTextElement(_IntToString(cast(s32) textConfig.fontId), infoTextConfig);
                            _OpenTextElement(_static_string("Line Height"), infoTitleConfig);
                            if textConfig.lineHeight == 0 {
                                _OpenTextElement(_static_string("auto"), infoTextConfig);
                            } else {
                                _OpenTextElement(_IntToString(cast(s32) textConfig.lineHeight), infoTextConfig);
                            }
                            _OpenTextElement(_static_string("Letter Spacing"), infoTitleConfig);
                            _OpenTextElement(_IntToString(cast(s32) textConfig.letterSpacing), infoTextConfig);
                            _OpenTextElement(_static_string("Wrap Mode"), infoTitleConfig);
                            wrapMode := _static_string("WORDS");
                            if textConfig.wrapMode == .NONE {
                                wrapMode = _static_string("NONE");
                            } else if textConfig.wrapMode == .NEWLINES {
                                wrapMode = _static_string("NEWLINES");
                            }
                            _OpenTextElement(wrapMode, infoTextConfig);
                            _OpenTextElement(_static_string("Text Alignment"), infoTitleConfig);
                            textAlignment := _static_string("LEFT");
                            if textConfig.textAlignment == .CENTER {
                                textAlignment = _static_string("CENTER");
                            } else if textConfig.textAlignment == .RIGHT {
                                textAlignment = _static_string("RIGHT");
                            }
                            _OpenTextElement(textAlignment, infoTextConfig);
                            _OpenTextElement(_static_string("Text Color"), infoTitleConfig);
                            _RenderDebugViewColor(textConfig.textColor, infoTextConfig);
                        });
                    } else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_ASPECT {
                        aspectRatioConfig := elementConfig.config.aspectRatioElementConfig;
                        UI(.{
                            id = _HashString(_static_string("Clay__DebugViewElementInfoAspectRatioBody"), 0, 0),
                            layout = .{ padding = attributeConfigPadding, childGap = 8, layoutDirection = .TOP_TO_BOTTOM },
                        }, #code {
                            _OpenTextElement(_static_string("Aspect Ratio"), infoTitleConfig);
                            _OpenTextElement(_IntToString(cast(s32) aspectRatioConfig.aspectRatio), infoTextConfig);
                        });
                    } else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_IMAGE {
                        imageConfig := elementConfig.config.imageElementConfig;
                        aspectConfig: AspectRatioElementConfig = .{ aspectRatio = 1 };
                        if _ElementHasConfig(selectedItem.layoutElement, CLAY__ELEMENT_CONFIG_TYPE_ASPECT) {
                            aspectConfig = _FindElementConfigWithType(selectedItem.layoutElement, CLAY__ELEMENT_CONFIG_TYPE_ASPECT).aspectRatioElementConfig.*;
                        }
                        UI(.{
                            id = _HashString(_static_string("Clay__DebugViewElementInfoImageBody"), 0, 0),
                            layout = .{ padding = attributeConfigPadding, childGap = 8, layoutDirection = .TOP_TO_BOTTOM },
                        }, #code {
                            _OpenTextElement(_static_string("Preview"), infoTitleConfig);
                            UI(.{
                                layout = .{
                                    sizing = .{
                                        width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 64, max = cast(float) 128 } }, type = .GROW },
                                        height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 64, max = cast(float) 128 } }, type = .GROW },
                                    },
                                },
                                aspectRatio = aspectConfig,
                                image = imageConfig.*,
                            }, #code {});
                        });
                    } else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_CLIP {
                        clipConfig := elementConfig.config.clipElementConfig;
                        UI(.{
                            layout = .{ padding = attributeConfigPadding, childGap = 8, layoutDirection = .TOP_TO_BOTTOM },
                        }, #code {
                            _OpenTextElement(_static_string("Vertical"), infoTitleConfig);
                            if clipConfig.vertical {
                                _OpenTextElement(_static_string("true"), infoTextConfig);
                            } else {
                                _OpenTextElement(_static_string("false"), infoTextConfig);
                            }
                            _OpenTextElement(_static_string("Horizontal"), infoTitleConfig);
                            if clipConfig.horizontal {
                                _OpenTextElement(_static_string("true"), infoTextConfig);
                            } else {
                                _OpenTextElement(_static_string("false"), infoTextConfig);
                            }
                        });
                    } else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_FLOATING {
                        floatingConfig := elementConfig.config.floatingElementConfig;
                        UI(.{
                            layout = .{ padding = attributeConfigPadding, childGap = 8, layoutDirection = .TOP_TO_BOTTOM },
                        }, #code {
                            _OpenTextElement(_static_string("Offset"), infoTitleConfig);
                            UI(.{
                                layout = .{ layoutDirection = .LEFT_TO_RIGHT },
                            }, #code {
                                _OpenTextElement(_static_string("{ x: "), infoTextConfig);
                                _OpenTextElement(_IntToString(cast(s32) floatingConfig.offset[0]), infoTextConfig);
                                _OpenTextElement(_static_string(", y: "), infoTextConfig);
                                _OpenTextElement(_IntToString(cast(s32) floatingConfig.offset[1]), infoTextConfig);
                                _OpenTextElement(_static_string(" }"), infoTextConfig);
                            });
                            _OpenTextElement(_static_string("Expand"), infoTitleConfig);
                            UI(.{
                                layout = .{ layoutDirection = .LEFT_TO_RIGHT },
                            }, #code {
                                _OpenTextElement(_static_string("{ width: "), infoTextConfig);
                                _OpenTextElement(_IntToString(cast(s32) floatingConfig.expand.width), infoTextConfig);
                                _OpenTextElement(_static_string(", height: "), infoTextConfig);
                                _OpenTextElement(_IntToString(cast(s32) floatingConfig.expand.height), infoTextConfig);
                                _OpenTextElement(_static_string(" }"), infoTextConfig);
                            });
                            _OpenTextElement(_static_string("z-index"), infoTitleConfig);
                            _OpenTextElement(_IntToString(cast(s32) floatingConfig.zIndex), infoTextConfig);
                            _OpenTextElement(_static_string("Parent"), infoTitleConfig);
                            hashItem := _GetHashMapItem(floatingConfig.parentId);
                            _OpenTextElement(hashItem.elementId.stringId, infoTextConfig);
                            _OpenTextElement(_static_string("Attach Points"), infoTitleConfig);
                            UI(.{
                                layout = .{ layoutDirection = .LEFT_TO_RIGHT },
                            }, #code {
                                _OpenTextElement(_static_string("{ element: "), infoTextConfig);
                                _OpenTextElement(_DebugAttachPointName(floatingConfig.attachment.element), infoTextConfig);
                                _OpenTextElement(_static_string(", parent: "), infoTextConfig);
                                _OpenTextElement(_DebugAttachPointName(floatingConfig.attachment.parent), infoTextConfig);
                                _OpenTextElement(_static_string(" }"), infoTextConfig);
                            });
                            _OpenTextElement(_static_string("Pointer Capture Mode"), infoTitleConfig);
                            pointerCaptureMode := _static_string("NONE");
                            if floatingConfig.pointerCaptureMode == .PASSTHROUGH {
                                pointerCaptureMode = _static_string("PASSTHROUGH");
                            }
                            _OpenTextElement(pointerCaptureMode, infoTextConfig);
                            _OpenTextElement(_static_string("Attach To"), infoTitleConfig);
                            attachTo := _static_string("NONE");
                            if floatingConfig.attachTo == .PARENT {
                                attachTo = _static_string("PARENT");
                            } else if floatingConfig.attachTo == .ELEMENT_WITH_ID {
                                attachTo = _static_string("ELEMENT_WITH_ID");
                            } else if floatingConfig.attachTo == .ROOT {
                                attachTo = _static_string("ROOT");
                            }
                            _OpenTextElement(attachTo, infoTextConfig);
                            _OpenTextElement(_static_string("Clip To"), infoTitleConfig);
                            clipTo := _static_string("ATTACHED_PARENT");
                            if floatingConfig.clipTo == .NONE {
                                clipTo = _static_string("NONE");
                            }
                            _OpenTextElement(clipTo, infoTextConfig);
                        });
                    } else if elementConfig.type == CLAY__ELEMENT_CONFIG_TYPE_BORDER {
                        borderConfig := elementConfig.config.borderElementConfig;
                        UI(.{
                            id = _HashString(_static_string("Clay__DebugViewElementInfoBorderBody"), 0, 0),
                            layout = .{ padding = attributeConfigPadding, childGap = 8, layoutDirection = .TOP_TO_BOTTOM },
                        }, #code {
                            _OpenTextElement(_static_string("Border Widths"), infoTitleConfig);
                            UI(.{
                                layout = .{ layoutDirection = .LEFT_TO_RIGHT },
                            }, #code {
                                _OpenTextElement(_static_string("{ left: "), infoTextConfig);
                                _OpenTextElement(_IntToString(cast(s32) borderConfig.width.left), infoTextConfig);
                                _OpenTextElement(_static_string(", right: "), infoTextConfig);
                                _OpenTextElement(_IntToString(cast(s32) borderConfig.width.right), infoTextConfig);
                                _OpenTextElement(_static_string(", top: "), infoTextConfig);
                                _OpenTextElement(_IntToString(cast(s32) borderConfig.width.top), infoTextConfig);
                                _OpenTextElement(_static_string(", bottom: "), infoTextConfig);
                                _OpenTextElement(_IntToString(cast(s32) borderConfig.width.bottom), infoTextConfig);
                                _OpenTextElement(_static_string(" }"), infoTextConfig);
                            });
                            _OpenTextElement(_static_string("Border Color"), infoTitleConfig);
                            _RenderDebugViewColor(borderConfig.color, infoTextConfig);
                        });
                    }
                    elementConfigIndex += 1;
                }
            });
        } else {
            UI(.{
                id = _HashString(_static_string("Clay__DebugViewWarningsScrollPane"), 0, 0),
                layout = .{
                    sizing = .{
                        width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                        height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 300, max = cast(float) 300 } }, type = .FIXED },
                    },
                    childGap = 6,
                    layoutDirection = .TOP_TO_BOTTOM,
                },
                backgroundColor = CLAY__DEBUGVIEW_COLOR_2,
                clip = .{ horizontal = true, vertical = true, childOffset = GetScrollOffset() },
            }, #code {
                warningConfig := _StoreTextElementConfig(.{ textColor = CLAY__DEBUGVIEW_COLOR_4, fontSize = 16, wrapMode = .NONE });
                UI(.{
                    id = _HashString(_static_string("Clay__DebugViewWarningItemHeader"), 0, 0),
                    layout = .{
                        sizing = .{ height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT, max = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT } }, type = .FIXED } },
                        padding = .{
                            left = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                            right = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                            top = 0,
                            bottom = 0,
                        },
                        childGap = 8,
                        childAlignment = .{ y = .CENTER },
                    },
                }, #code {
                    _OpenTextElement(_static_string("Warnings"), warningConfig);
                });
                UI(.{
                    id = _HashString(_static_string("Clay__DebugViewWarningsTopBorder"), 0, 0),
                    layout = .{
                        sizing = .{
                            width = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 0 } }, type = .GROW },
                            height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) 1, max = cast(float) 1 } }, type = .FIXED },
                        },
                    },
                    backgroundColor = .[200, 200, 200, 255],
                }, #code {});
                previousWarningsLength := ctx.warnings.length;
                warningIndex: s32 = 0;
                while warningIndex < previousWarningsLength {
                    warning := ctx.warnings.internalArray[warningIndex];
                    UI(.{
                        id = _HashString(_static_string("Clay__DebugViewWarningItem"), cast(u32) warningIndex, 0),
                        layout = .{
                            sizing = .{ height = .{ constraints = .{ sizeMinMax = .{ min = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT, max = cast(float) CLAY__DEBUGVIEW_ROW_HEIGHT } }, type = .FIXED } },
                            padding = .{
                                left = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                                right = cast(u16) CLAY__DEBUGVIEW_OUTER_PADDING,
                                top = 0,
                                bottom = 0,
                            },
                            childGap = 8,
                            childAlignment = .{ y = .CENTER },
                        },
                    }, #code {
                        _OpenTextElement(warning.baseMessage, warningConfig);
                        if warning.dynamicMessage.length > 0 {
                            _OpenTextElement(warning.dynamicMessage, warningConfig);
                        }
                    });
                    warningIndex += 1;
                }
            });
        }
    });
}
//@endregion
