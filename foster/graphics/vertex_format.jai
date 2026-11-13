#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Structs/VertexFormat.cs.
// Foster uses a StackList32 of Elements; Jai uses a fixed array + count.

Vertex_Format :: struct {
    Elements: [32] Vertex_Format_Element;
    ElementCount: s32;
    Stride: s32;
}

Vertex_Format_Element :: struct {
    Index:      s32;
    Type:       Vertex_Type;
    Normalized: bool;
}

vertex_format_make :: (elements: [] Vertex_Format_Element, stride: s32 = 0) -> Vertex_Format {
    f: Vertex_Format;
    for e: elements {
        f.Elements[f.ElementCount] = e;
        f.ElementCount += 1;
        f.Stride += cast(s32) vertex_type_size_in_bytes(e.Type);
    }
    if stride != 0 f.Stride = stride;
    return f;
}

operator == :: (a: Vertex_Format, b: Vertex_Format) -> bool {
    if a.Stride != b.Stride || a.ElementCount != b.ElementCount return false;
    for i: 0..a.ElementCount-1 {
        if a.Elements[i] != b.Elements[i] return false;
    }
    return true;
}

operator != :: (a: Vertex_Format, b: Vertex_Format) -> bool {
    return !(a == b);
}

operator == :: (a: Vertex_Format_Element, b: Vertex_Format_Element) -> bool {
    return a.Index == b.Index && a.Type == b.Type && a.Normalized == b.Normalized;
}

operator != :: (a: Vertex_Format_Element, b: Vertex_Format_Element) -> bool {
    return !(a == b);
}
