#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Structs/TextureSampler.cs + BoundSampler.cs.

Texture_Sampler :: struct {
    Filter: Texture_Filter;
    WrapX:  Texture_Wrap;
    WrapY:  Texture_Wrap;
}

texture_sampler_make :: (filter: Texture_Filter, wrap: Texture_Wrap) -> Texture_Sampler {
    return .{ Filter = filter, WrapX = wrap, WrapY = wrap };
}

operator == :: (a: Texture_Sampler, b: Texture_Sampler) -> bool {
    return a.Filter == b.Filter && a.WrapX == b.WrapX && a.WrapY == b.WrapY;
}

operator != :: (a: Texture_Sampler, b: Texture_Sampler) -> bool {
    return !(a == b);
}

Bound_Sampler :: struct {
    Tex: *Texture;        // 'Texture' would shadow the type name
    Sampler: Texture_Sampler;
}

operator == :: (a: Bound_Sampler, b: Bound_Sampler) -> bool {
    return a.Tex == b.Tex && a.Sampler == b.Sampler;
}

operator != :: (a: Bound_Sampler, b: Bound_Sampler) -> bool {
    return !(a == b);
}
