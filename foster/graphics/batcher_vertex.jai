#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Defaults/BatcherVertex.cs.
// 24 bytes: pos float2, tex float2, col ubyte4-norm, mode ubyte4-norm.

Batcher_Vertex :: struct {
    pos: Vector2;
    tex: Vector2;
    col: Color;
    mode: Color;
}

Batcher_Vertex_Elements: [4] Vertex_Format_Element = .[
    (Vertex_Format_Element.{ Index = 0, Type = .FLOAT2, Normalized = false }), // Pos
    (Vertex_Format_Element.{ Index = 1, Type = .FLOAT2, Normalized = false }), // Tex
    (Vertex_Format_Element.{ Index = 2, Type = .UBYTE4, Normalized = true }), // Col
    (Vertex_Format_Element.{ Index = 3, Type = .UBYTE4, Normalized = true }), // Mode
];

Batcher_Vertex_Format :: #run vertex_format_make(Batcher_Vertex_Elements);

// Vertex colors that select the Batcher shader's blend mode:
// R = multiply/normal, G = wash (alpha-only), B = fill (ignore texture).
Batcher_Mode_Normal :: Color.{ 255, 0, 0, 0 };
Batcher_Mode_Wash :: Color.{ 0, 255, 0, 0 };
Batcher_Mode_Fill :: Color.{ 0, 0, 255, 0 };
