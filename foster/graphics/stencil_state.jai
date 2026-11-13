#scope_module
using Basic;
using Math;
#scope_export

// Port of Foster Framework/Graphics/Structs/StencilState.cs.

Stencil_State :: struct {
    FailOp:       Stencil_Op;
    PassOp:       Stencil_Op;
    DepthFailOp:  Stencil_Op;
    CompareOp:    Depth_Compare;
}

stencil_state_make :: (op: Stencil_Op, compare: Depth_Compare) -> Stencil_State {
    return .{ FailOp = op, PassOp = op, DepthFailOp = op, CompareOp = compare };
}

operator == :: (a: Stencil_State, b: Stencil_State) -> bool {
    return a.FailOp == b.FailOp && a.PassOp == b.PassOp &&
           a.DepthFailOp == b.DepthFailOp && a.CompareOp == b.CompareOp;
}

operator != :: (a: Stencil_State, b: Stencil_State) -> bool {
    return !(a == b);
}
