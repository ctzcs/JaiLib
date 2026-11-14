// 一比一移植自 olib tests/core/meshutil/meshutil_test.odin。
// 断言顺序、期望值与容差保持原样，只把 core:testing 的 @(test) proc 换成
// (state: *Test_State) 形式，expect_value / expectf 换成 test_support.expect。
//
// Jai 侧差异（测试语义不变）：
//   - 没有 [3] float32 / [2] float32 的 ==，结构体也没有 ==：判等走 t_v3_eq / t_v2_eq /
//     t_vertex_eq 逐分量或逐字段比较（IEEE 语义与 odin 相同）；
//   - odin 的 [dynamic]T + append / resize 换成 Jai 的 [..] T + array_add，末尾
//     indices.count = kept.count 等价于 resize；
//   - olib 的测试没有覆盖 primitive_positions（依赖 dasset）；这里补一节
//     primitive_positions_bridge，用与 dasset primitive 同形的结构体实例化泛型版本，
//     保证它能编译且取位置的行为与 olib 一致；
//   - 断言总数 55 + 4（补的一节），其余与 olib 一一对应。
#import "Basic";
#import "Math";
#import "test_support";
MU :: #import "core/meshutil";

//@region 测试辅助

// 追加一组元素（odin 的 append(&dst, items...)）：Jai 的 array_add 变参不接受
// `.[...]` 字面量，泛型在这里推断不出 array_add 的 T，所以按类型各写一个具体版本。
t_append_v3 :: (items: *[..][3] float32, list: [][3] float32) {
    for i: 0..list.count - 1 array_add(items, list[i]);
}

t_append_u32 :: (items: *[..] u32, list: [] u32) {
    for i: 0..list.count - 1 array_add(items, list[i]);
}

t_append_vertex :: (items: *[..] Vertex_Probe, list: [] Vertex_Probe) {
    for i: 0..list.count - 1 array_add(items, list[i]);
}

// 释放本包用默认分配器返回的切片（odin 的 delete）。
t_free :: (items: [] $T) {
    if items.data != null free(items.data);
}

t_v3_eq :: (a: [3] float32, b: [3] float32) -> bool {
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}

t_v2_eq :: (a: [2] float32, b: [2] float32) -> bool {
    return a[0] == b[0] && a[1] == b[1];
}

//@endregion

//@region 测试网格

Vertex_Probe :: struct {
    position: [3] float32;
    uv: [2] float32;
}

t_vertex_eq :: (a: Vertex_Probe, b: Vertex_Probe) -> bool {
    return t_v3_eq(a.position, b.position) && t_v2_eq(a.uv, b.uv);
}

// 每面独立 4 顶点的立方体（平直着色），外侧 CCW。
test_cube :: () -> ([..][3] float32, [..] u32) {
    positions: [..][3] float32;
    indices: [..] u32;
    sides: [2] float32 = .[-1, 1];
    corners: [4][2] float32 = .[.[-1, -1], .[1, -1], .[1, 1], .[-1, 1]];
    for axis: 0..2 {
        for side_index: 0..1 {
            side := sides[side_index];
            base := cast(u32) positions.count;
            for corner_index: 0..3 {
                p: [3] float32;
                p[axis] = side;
                p[(axis + 1) % 3] = corners[corner_index][0];
                p[(axis + 2) % 3] = corners[corner_index][1];
                array_add(*positions, p);
            }
            if side > 0 {
                array_add(*indices, base, base + 1, base + 2, base, base + 2, base + 3);
            } else {
                array_add(*indices, base, base + 2, base + 1, base, base + 3, base + 2);
            }
        }
    }
    return positions, indices;
}

// XZ 平面上 cells×cells 的网格，带开放边界。
test_plane :: (cells: int) -> ([..][3] float32, [..] u32) {
    positions: [..][3] float32;
    indices: [..] u32;
    for z: 0..cells {
        for x: 0..cells {
            array_add(*positions, .[cast(float32) x, 0, cast(float32) z]);
        }
    }
    row := cast(u32) cells + 1;
    for z: 0..cells - 1 {
        for x: 0..cells - 1 {
            a := cast(u32) z * row + cast(u32) x;
            array_add(*indices, a, a + row, a + 1, a + 1, a + row, a + row + 1);
        }
    }
    return positions, indices;
}

// UV 球：经线 0 与 2π 处重复顶点形成属性缝，两极也重复（退化三角形已移除）。
test_sphere :: (segments: int, rings: int) -> ([..][3] float32, [..] u32) {
    positions: [..][3] float32;
    indices: [..] u32;
    for r: 0..rings {
        phi := cast(float32) r * PI / cast(float32) rings;
        for s: 0..segments {
            theta := cast(float32) s * 2 * PI / cast(float32) segments;
            if s == segments theta = 0;
            p: [3] float32 = .[
            sin(phi) * cos(theta),
            cos(phi),
            sin(phi) * sin(theta),
            ];
            if r == 0 || r == rings p = .[0, cos(phi), 0];
            array_add(*positions, p);
        }
    }
    row := cast(u32) segments + 1;
    for r: 0..rings - 1 {
        for s: 0..segments - 1 {
            a := cast(u32) r * row + cast(u32) s;
            array_add(*indices, a, a + 1, a + row, a + 1, a + row + 1, a + row);
        }
    }
    kept := MU.remove_degenerate(positions, indices);
    indices.count = kept.count;
    return positions, indices;
}
//@endregion

//@region 统计与边

stats_cube_seams :: (state: *Test_State) {
    positions, indices := test_cube();
    defer array_free(positions);
    defer array_free(indices);
    s := MU.stats(positions, indices);
    expect(state, s.vertices == 24, "cube vertices");
    expect(state, s.used_vertices == 24, "cube used_vertices");
    expect(state, s.unique_positions == 8, "cube unique_positions");
    expect(state, s.triangles == 12, "cube triangles");
    expect(state, s.edges == 18, "cube edges");
    expect(state, s.seam_edges == 12, "cube seam_edges：立方体棱，两面使用不同顶点");
    expect(state, s.border_edges == 0, "cube border_edges");
    expect(state, s.non_manifold_edges == 0, "cube non_manifold_edges");
    expect(state, s.degenerate_triangles == 0, "cube degenerate_triangles");
    expect(state, t_v3_eq(s.bounds.min, .[-1, -1, -1]) && t_v3_eq(s.bounds.max, .[1, 1, 1]), "cube bounds");
}

edges_plane_border :: (state: *Test_State) {
    positions, indices := test_plane(4);
    defer array_free(positions);
    defer array_free(indices);
    list, ok := MU.edges(positions, indices);
    defer t_free(list);
    expect(state, ok, "plane edges ok");
    border := 0;
    interior := 0;
    for i: 0..list.count - 1 {
        if list[i].kind == MU.Edge_Kind.Border {
            border += 1;
        } else if list[i].kind == MU.Edge_Kind.Interior {
            interior += 1;
        }
    }
    expect(state, border == 16, "plane border edges");
    expect(state, interior == list.count - 16, "plane interior edges");
    bad_list, bad := MU.edges(positions, u32.[0, 1, 999]);
    t_free(bad_list);
    expect(state, !bad, "out-of-range index rejected");
    s := MU.stats(positions, u32.[0, 1, 999]);
    expect(state, s.invalid_indices == 1, "invalid index counted");
}

edges_non_manifold :: (state: *Test_State) {
    positions: [..][3] float32;
    defer array_free(positions);
    verts: [5][3] float32 = .[.[0, 0, 0], .[1, 0, 0], .[0, 1, 0], .[0, -1, 0], .[0, 0, 1]];
    t_append_v3(*positions, verts);
    indices: [..] u32;
    defer array_free(indices);
    tris: [9] u32 = .[0, 1, 2, 1, 0, 3, 0, 1, 4];
    t_append_u32(*indices, tris);
    s := MU.stats(positions, indices);
    expect(state, s.non_manifold_edges == 1, "non-manifold edges");
    expect(state, s.border_edges == 6, "border edges with non-manifold fan");
}
//@endregion

//@region 顶点整理

weld_and_compact :: (state: *Test_State) {
    raw: [7] Vertex_Probe = .[
    .{ .[0, 0, 0], .[0, 0] }, .{ .[1, 0, 0], .[1, 0] }, .{ .[0, 1, 0], .[0, 1] },
    .{ .[1, 0, 0], .[1, 0] }, .{ .[0, 1, 0], .[0, 1] }, .{ .[1, 1, 0], .[1, 1] },
    .{ .[1, 0, 0], .[0.5, 0] }, // 位置重复但 UV 不同：保留
    ];
    vertices: [..] Vertex_Probe;
    defer array_free(vertices);
    t_append_vertex(*vertices, raw);

    original: [9] u32 = .[0, 1, 2, 3, 5, 4, 6, 5, 4];
    indices: [..] u32;
    defer array_free(indices);
    t_append_u32(*indices, original);

    welded, ok := MU.weld(vertices, indices);
    defer t_free(welded);
    expect(state, ok, "weld ok");
    expect(state, welded.count == 5, "weld merges byte-identical vertices");
    expect(state, indices[3] == 1 && indices[5] == 2, "duplicates point at first occurrence");
    for i: 0..indices.count - 1 {
        expect(state, t_vertex_eq(welded[cast(int) indices[i]], vertices[cast(int) original[i]]),
        "welded index % points at the same vertex", i);
    }

    raw_unused: [4] Vertex_Probe = .[
   .{ .[9, 9, 9], .[0, 0] }, .{ .[0, 0, 0], .[0, 0] },
   .{ .[1, 0, 0], .[0, 0] }, .{ .[0, 1, 0], .[0, 0] },
   ];
    unused: [..] Vertex_Probe;
    defer array_free(unused);
    t_append_vertex(*unused, raw_unused);
    tri: [..] u32;
    defer array_free(tri);
    t_append_u32(*tri, u32.[3, 1, 2]);
    compacted, compact_ok := MU.compact(unused, tri);
    defer t_free(compacted);
    expect(state, compact_ok, "compact ok");
    expect(state, compacted.count == 3, "compact drops the unused vertex");
    expect(state, tri[0] == 0 && tri[1] == 1 && tri[2] == 2, "ordered by first use");
    expect(state, t_v3_eq(compacted[0].position, .[0, 1, 0]), "compacted[0] is the first referenced vertex");
    bad_result, bad := MU.compact(unused, u32.[7]);
    t_free(bad_result);
    expect(state, !bad, "compact rejects out-of-range index");
}

remove_degenerate_triangles :: (state: *Test_State) {
    positions: [..][3] float32;
    defer array_free(positions);
    verts: [4][3] float32 = .[.[0, 0, 0], .[1, 0, 0], .[0, 1, 0], .[0, 0, 0]];
    t_append_v3(*positions, verts);
    indices: [..] u32;
    defer array_free(indices);
    tris: [12] u32 = .[0, 1, 2, 0, 0, 1, 3, 1, 0, 2, 1, 0];
    t_append_u32(*indices, tris);
    kept := MU.remove_degenerate(positions, indices);
    expect(state, kept.count == 6, "degenerate triangles removed");
    expect(state, kept[3] == 2 && kept[4] == 1 && kept[5] == 0, "winding preserved");
}
//@endregion

//@region 简化

simplify_flat_plane_keeps_corners :: (state: *Test_State) {
    positions, indices := test_plane(16);
    defer array_free(positions);
    defer array_free(indices);
    result, error, ok := MU.simplify(positions, indices, 6, 0.001);
    defer t_free(result);
    expect(state, ok, "simplify plane ok");
    expect(state, result.count <= 24, "flat plane collapses almost fully, got %", result.count);
    expect(state, error < 0.0001, "flat plane error is zero-ish, got %", error);
    corners: [4][3] float32 = .[.[0, 0, 0], .[16, 0, 0], .[0, 0, 16], .[16, 0, 16]];
    for corner_index: 0..3 {
        found := false;
        for i: 0..result.count - 1 {
            if t_v3_eq(positions[cast(int) result[i]], corners[corner_index]) found = true;
        }
        expect(state, found, "border corner % is preserved", corner_index);
    }
    s := MU.stats(positions, result);
    expect(state, s.degenerate_triangles == 0, "simplified plane has no degenerate triangles");
    expect(state, t_v3_eq(s.bounds.min, .[0, 0, 0]) && t_v3_eq(s.bounds.max, .[16, 0, 16]),
    "simplified plane keeps the bounds");
}

simplify_sphere_keeps_seam_closed :: (state: *Test_State) {
    positions, indices := test_sphere(32, 16);
    defer array_free(positions);
    defer array_free(indices);
    before := MU.stats(positions, indices);
    expect(state, before.border_edges == 0, "sphere has no border before simplify");
    expect(state, before.seam_edges > 0, "sphere has seam edges before simplify");
    target := indices.count / 4;
    result, error, ok := MU.simplify(positions, indices, target, 0.2);
    defer t_free(result);
    expect(state, ok, "simplify sphere ok");
    expect(state, result.count <= indices.count / 2, "reduced % -> %", indices.count, result.count);
    expect(state, error > 0 && error < 0.2, "sphere error within limit, got %", error);
    after := MU.stats(positions, result);
    expect(state, after.border_edges == 0, "seam pairs collapse together, no crack");
    expect(state, after.non_manifold_edges == 0, "simplified sphere stays manifold");
    expect(state, after.degenerate_triangles == 0, "simplified sphere has no degenerate triangles");

    // 误差上限阻止过度简化。
    strict, strict_error, _ := MU.simplify(positions, indices, 0, 0.0001);
    defer t_free(strict);
    expect(state, strict.count == indices.count && strict_error == 0, "max_error stops simplification");
    bad_result, _, bad := MU.simplify(positions, u32.[0, 1], 0);
    t_free(bad_result);
    expect(state, !bad, "simplify rejects non-triangle index list");
}
//@endregion

//@region primitive_positions 桥接（olib 测试未覆盖，core/dasset 未移植）

// 与 dasset.Dasset_Vertex / Dasset_Skin_Vertex 同形的最小子集：本包只读 position。
Dasset_Vertex_Probe :: struct {
    position: [3] float32;
    normal: [3] float32;
    uv: [2] float32;
    tangent: [4] float32;
}

Dasset_Skin_Vertex_Probe :: struct {
    position: [3] float32;
    normal: [3] float32;
    uv: [2] float32;
    tangent: [4] float32;
    joints: u32;
    weights: [4] float32;
}

Dasset_Primitive_Probe :: struct {
    vertices: [] Dasset_Vertex_Probe;
    skin_vertices: [] Dasset_Skin_Vertex_Probe;
    skin_index: s32;
    indices: [] u32;
}

primitive_positions_bridge :: (state: *Test_State) {
    vertices := Dasset_Vertex_Probe.[
    .{ .[1, 2, 3], .[0, 1, 0], .[0, 0], .[1, 0, 0, 1] },
    .{ .[4, 5, 6], .[0, 1, 0], .[1, 0], .[1, 0, 0, 1] },
    ];
    primitive: Dasset_Primitive_Probe;
    primitive.vertices = vertices;
    static_positions := MU.primitive_positions(*primitive);
    defer t_free(static_positions);
    expect(state, static_positions.count == 2, "static primitive positions count");
    expect(state, t_v3_eq(static_positions[0], .[1, 2, 3]), "static primitive position 0");
    expect(state, t_v3_eq(static_positions[1], .[4, 5, 6]), "static primitive position 1");

    skin := Dasset_Skin_Vertex_Probe.[
   .{ .[7, 8, 9], .[0, 1, 0], .[0, 0], .[1, 0, 0, 1], 0, .[1, 0, 0, 0] },
   ];
    skinned: Dasset_Primitive_Probe;
    skinned.skin_vertices = skin;
    skin_positions := MU.primitive_positions(*skinned);
    defer t_free(skin_positions);
    expect(state, skin_positions.count == 1, "skinned primitive positions count");
    expect(state, t_v3_eq(skin_positions[0], .[7, 8, 9]), "skinned primitive position 0");
}
//@endregion

// Loop scopes adapted.
