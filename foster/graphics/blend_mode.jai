#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Structs/BlendMode.cs.

Blend_Mode :: struct {
    ColorOperation:  Blend_Op;
    ColorSource:     Blend_Factor;
    ColorDestination: Blend_Factor;
    AlphaOperation:  Blend_Op;
    AlphaSource:     Blend_Factor;
    AlphaDestination: Blend_Factor;
    Mask:            Blend_Mask;
    BlendColor:      Color;   // field name differs from Foster (Color) to avoid shadowing
}

blend_mode_make :: (operation: Blend_Op, source: Blend_Factor, destination: Blend_Factor) -> Blend_Mode {
    return .{
        ColorOperation = operation, AlphaOperation = operation,
        ColorSource = source, AlphaSource = source,
        ColorDestination = destination, AlphaDestination = destination,
        Mask = .RGBA,
        BlendColor = Color_White,
    };
}

Blend_Mode_Premultiply :: Blend_Mode.{
    ColorOperation = .ADD, ColorSource = .ONE, ColorDestination = .ONE_MINUS_SRC_ALPHA,
    AlphaOperation = .ADD, AlphaSource = .ONE, AlphaDestination = .ONE_MINUS_SRC_ALPHA,
    Mask = .RGBA, BlendColor = Color_White,
};
Blend_Mode_NonPremultiplied :: Blend_Mode.{
    ColorOperation = .ADD, ColorSource = .SRC_ALPHA, ColorDestination = .ONE_MINUS_SRC_ALPHA,
    AlphaOperation = .ADD, AlphaSource = .SRC_ALPHA, AlphaDestination = .ONE_MINUS_SRC_ALPHA,
    Mask = .RGBA, BlendColor = Color_White,
};
Blend_Mode_Add :: Blend_Mode.{
    ColorOperation = .ADD, ColorSource = .ONE, ColorDestination = .DST_ALPHA,
    AlphaOperation = .ADD, AlphaSource = .ONE, AlphaDestination = .DST_ALPHA,
    Mask = .RGBA, BlendColor = Color_White,
};
Blend_Mode_Multiply :: Blend_Mode.{
    ColorOperation = .ADD, ColorSource = .DST_COLOR, ColorDestination = .ONE_MINUS_SRC_ALPHA,
    AlphaOperation = .ADD, AlphaSource = .DST_COLOR, AlphaDestination = .ONE_MINUS_SRC_ALPHA,
    Mask = .RGBA, BlendColor = Color_White,
};
Blend_Mode_Screen :: Blend_Mode.{
    ColorOperation = .ADD, ColorSource = .ONE, ColorDestination = .ONE_MINUS_SRC_COLOR,
    AlphaOperation = .ADD, AlphaSource = .ONE, AlphaDestination = .ONE_MINUS_SRC_COLOR,
    Mask = .RGBA, BlendColor = Color_White,
};

operator == :: (a: Blend_Mode, b: Blend_Mode) -> bool {
    return a.ColorOperation == b.ColorOperation && a.ColorSource == b.ColorSource &&
           a.ColorDestination == b.ColorDestination && a.AlphaOperation == b.AlphaOperation &&
           a.AlphaSource == b.AlphaSource && a.AlphaDestination == b.AlphaDestination &&
           a.Mask == b.Mask && a.BlendColor == b.BlendColor;
}

operator != :: (a: Blend_Mode, b: Blend_Mode) -> bool {
    return !(a == b);
}
