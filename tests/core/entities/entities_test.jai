// entities_test.jai —— 一比一移植自 olib tests/core/entities/entities_test.odin（508 行）。
// 测试拆分、断言顺序、断言语义与 olib 一一对应；testing.expect → test_support.expect。
// 前 7 个用例来自上游 ravn entities_test.odin（864cccb），get_sub 用例是 olib 本地修正
// 的回归，其后 4 个是 olib 的有限池安全边界用例。
//
// Jai 侧改写（只改写法，不改被验证的行为；每条在下面就近注释）：
//   - Entities(union{...}, union{...}) → init 时传两个类型列表：variant 下标就是类型在
//     列表中的位置（等同 olib 的 union 顺序），见 core/entities/entities.jai 文件头。
//   - ptr.variant.(^Foo) → (cast(*Foo) ptr.base)；h != {} → !handle_eq(h, Handle.{})；
//     p^ == Pos{1,2} → 逐字段比较（Jai 的结构体没有内建 ==）。
//   - create_val / create_sub → 同一个 create（Jai 无 union tag，见模块文件头 3)。
//   - Buffer 结构体比较用 buffer_eq（operator == 跨模块不可见，同 core/handle 测试的做法）。
//   - ents.buffers 是动态数组：未安装（init 失败）时不能索引，用 entities_installed 判定，
//     对应 olib 的 ents.buffers[0].data == nil && ents.buffers[1].data == nil。
//   - max(Handle_Gen) 等 → ENT.Handle_Gen_Max 等常量；_capacity_valid → 公开的
//     ENT.entities_capacity_valid；next_val/next_sub 用 while 循环（Jai 没有 for-in）。
#import "Basic";
#import "test_support";
ENT :: #import "core/entities";

//@region 测试辅助

// Handle 的具名等价物：Jai 的 operator == 按词法解析，core/entities 里声明的那份在
// 本文件不可见（同 Tests/core/handle/handle_test.jai / Libs/Engine/entities 的做法）。
handle_eq :: (a: ENT.Handle, b: ENT.Handle) -> bool {
    return a.index == b.index && a.gen == b.gen && a.variant == b.variant;
}

// olib 的 `ents.buffers[i] == before`（Buffer 是纯值类型，逐字段比较即可）。
buffer_eq :: (a: ENT.Buffer, b: ENT.Buffer) -> bool {
    return a.data == b.data && a.cap == b.cap && a.top == b.top &&
    a.free == b.free && a.retired == b.retired;
}

// olib 的 ents.buffers[0].data == nil && ents.buffers[1].data == nil：
// 容器完全没有被安装就是“一个 buffer 都没分配”。
entities_installed :: (ents: ENT.Entities) -> bool {
    return ents.buffers.count > 0;
}

//@endregion

//@region 上游 ravn 用例

// Port of entities_test.odin: _basic_test
entities_basic :: (state: *Test_State) {
    Named :: struct {
        name: string;
    }
    Foo :: struct {
        base: ENT.Base;
        named: Named;
        val: u8;
    }
    Bar :: struct {
        base: ENT.Base;
        named: Named;
        val: float64;
    }
    Baz :: struct {
        base: ENT.Base;
    }

    ents: ENT.Entities;
    ENT.init(*ents, .[Foo, Bar, Baz], .[], default_cap = 64);
    defer ENT.shutdown(*ents);

    expect(state, ENT.get_values(ents, Foo).count == 0, "Foo 初始为空");
    expect(state, ENT.get_values(ents, Bar).count == 0, "Bar 初始为空");

    a, a_ok := ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "First" }, val = 1 });
    expect(state, a_ok, "create(Foo) 成功");
    expect(state, !handle_eq(a, ENT.Handle.{}), "a 不是零句柄");
    expect(state, a.variant == 0, "a.variant == 0 (Foo)");

    expect(state, ENT.get_values(ents, Foo).count == 1, "Foo 有 1 个槽位");
    expect(state, ENT.destroy(*ents, a), "destroy(a) 成功");

    a_ptr, a_ptr_ok := ENT.get(*ents, a);
    expect(state, !a_ptr_ok, "destroy 后 get(a) 失败");
    expect(state, a_ptr.base == null, "a_ptr.base 为 null");

    b_val := Foo.{ base = ENT.Base.{}, named = .{ name = "Second" }, val = 2 };
    b, b_ok := ENT.create(*ents, b_val);

    expect(state, !handle_eq(b, ENT.Handle.{}), "b 不是零句柄");
    expect(state, b.index == a.index, "空闲槽复用：b.index == a.index");

    b_ptr, b_ptr_ok := ENT.get(*ents, b);
    expect(state, b_ptr_ok, "get(b) 成功");
    expect(state, b_ptr.base != null, "b_ptr.base 不为 null");
    expect(state, b_ptr.variant == 0, "b_ptr.variant == 0 (Foo)");
    expect(state, (cast(*Foo) b_ptr.base).named.name == "Second", "实体名是 Second");
    expect(state, !handle_eq(a, b), "a != b");
}

// Port of entities_test.odin: _iter_val_test
entities_iter_val :: (state: *Test_State) {
    Foo :: struct {
        base: ENT.Base;
        val: u8;
    }
    Bar :: struct {
        base: ENT.Base;
        x: float32;
    }

    ents: ENT.Entities;
    ENT.init(*ents, .[Foo, Bar], .[], default_cap = 64);
    defer ENT.shutdown(*ents);

    h0, _ := ENT.create(*ents, Foo.{});
    h1, _ := ENT.create(*ents, Foo.{});
    h2, _ := ENT.create(*ents, Foo.{});
    h3, _ := ENT.create(*ents, Foo.{});
    h4, _ := ENT.create(*ents, Foo.{});

    ENT.destroy(*ents, h0);
    ENT.destroy(*ents, h2);
    ENT.destroy(*ents, h4);

    counter := 0;
    it := ENT.begin_val(*ents, Foo);
    while true {
        _, ok := ENT.next_val(*it);
        if !ok break;
        counter += 1;
    }
    expect(state, counter == 2, "按 Val 迭代只数到 2 个存活实体");
    expect(state, !handle_eq(h1, h3), "h1 != h3");
}

// Port of entities_test.odin: _iter_sub_test
entities_iter_sub :: (state: *Test_State) {
    Named :: struct {
        name: string;
    }
    Foo :: struct {
        base: ENT.Base;
        named: Named;
        val: u8;
    }
    Bar :: struct {
        base: ENT.Base;
        named: Named;
        val: float64;
    }
    Baz :: struct {
        base: ENT.Base;
    }

    ents: ENT.Entities;
    ENT.init(*ents, .[Foo, Bar, Baz], .[ENT.Base, Named], default_cap = 64);
    defer ENT.shutdown(*ents);

    h0, _ := ENT.create(*ents, Bar.{ base = ENT.Base.{}, named = .{ name = "b" } });
    h1, _ := ENT.create(*ents, Bar.{ base = ENT.Base.{}, named = .{ name = "b" } });
    h2, _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" } });
    ENT.create(*ents, Baz.{ base = ENT.Base.{} });
    ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" } });
    ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" } });
    ENT.create(*ents, Bar.{ base = ENT.Base.{}, named = .{ name = "b" } });
    ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" } });
    ENT.create(*ents, Baz.{ base = ENT.Base.{} });
    ENT.create(*ents, Bar.{ base = ENT.Base.{}, named = .{ name = "b" } });
    ENT.create(*ents, Baz.{ base = ENT.Base.{} });
    ENT.create(*ents, Baz.{ base = ENT.Base.{} });
    ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" } });

    ENT.destroy(*ents, h0);
    ENT.destroy(*ents, h1);
    ENT.destroy(*ents, h2);

    counter := 0;
    it := ENT.begin_sub(*ents, Named);
    while true {
        _, ok := ENT.next_sub(*it);
        if !ok break;
        counter += 1;
    }
    expect(state, counter == 6, "按 Sub 迭代数到 6 个 Named 实体");
}

// Port of entities_test.odin: _generation_aba_test
entities_generation_aba :: (state: *Test_State) {
    Foo :: struct {
        base: ENT.Base;
        val: int;
    }
    Bar :: struct {
        base: ENT.Base;
        val: int;
        x: float32;
    }
    ents: ENT.Entities;
    ENT.init(*ents, .[Foo, Bar], .[ENT.Base], default_cap = 64);
    defer ENT.shutdown(*ents);

    h1, _ := ENT.create(*ents, Foo.{ val = 10 });
    ENT.destroy(*ents, h1);

    h2, _ := ENT.create(*ents, Foo.{ val = 20 });

    expect(state, h1.index == h2.index, "Freelist 复用旧槽位");
    expect(state, h1.gen != h2.gen, "复用时代数必须递增");

    _, ok1 := ENT.get(*ents, h1);
    expect(state, !ok1, "旧句柄彻底失效");

    ptr2, ok2 := ENT.get(*ents, h2);
    expect(state, ok2 && (cast(*Foo) ptr2.base).val == 20, "新句柄读到新值");
}

// Port of entities_test.odin: _capacity_limits_test
entities_capacity_limits :: (state: *Test_State) {
    Foo :: struct {
        base: ENT.Base;
    }
    Bar :: struct {
        base: ENT.Base;
        x: float32;
    }
    ents: ENT.Entities;

    ENT.init(*ents, .[Foo, Bar], .[ENT.Base], default_cap = 4);
    defer ENT.shutdown(*ents);

    _, ok1 := ENT.create(*ents, Foo.{});
    _, ok2 := ENT.create(*ents, Foo.{});
    h3, ok3 := ENT.create(*ents, Foo.{});
    expect(state, ok1 && ok2 && ok3, "容量内应全部分配成功");

    _, ok4 := ENT.create(*ents, Foo.{});
    expect(state, !ok4, "超出容量必须拒绝");

    ENT.destroy(*ents, h3);
    h5, ok5 := ENT.create(*ents, Foo.{});

    expect(state, ok5, "释放后应能继续分配");
    expect(state, h5.index == h3.index, "应复用刚释放的槽位");
}

// Port of entities_test.odin: _clear_invalidation_test
entities_clear_invalidation :: (state: *Test_State) {
    Foo :: struct {
        base: ENT.Base;
    }
    Bar :: struct {
        base: ENT.Base;
        x: float32;
    }
    ents: ENT.Entities;
    ENT.init(*ents, .[Foo, Bar], .[ENT.Base], default_cap = 64);
    defer ENT.shutdown(*ents);

    h1, _ := ENT.create(*ents, Foo.{});
    h2, _ := ENT.create(*ents, Foo.{});

    ENT.clear(*ents);

    _, ok1 := ENT.get(*ents, h1);
    _, ok2 := ENT.get(*ents, h2);
    expect(state, !ok1 && !ok2, "clear 必须立即失效存活句柄");

    h3, _ := ENT.create(*ents, Foo.{});
    expect(state, h3.index == 1, "clear 后复用最低的非退休槽位");
    expect(state, h3.gen != h1.gen, "clear 必须推进被复用槽位的代数");
    _, ok1_after := ENT.get(*ents, h1);
    expect(state, !ok1_after, "clear 前的句柄在槽位复用后仍须无效");
}

// Port of entities_test.odin: _clone_test
entities_clone :: (state: *Test_State) {
    Foo :: struct {
        base: ENT.Base;
        val: int;
    }
    Bar :: struct {
        base: ENT.Base;
        x: float32;
    }
    ents: ENT.Entities;
    ENT.init(*ents, .[Foo, Bar], .[ENT.Base], default_cap = 64);
    defer ENT.shutdown(*ents);

    h1, _ := ENT.create(*ents, Foo.{ val = 10 });

    ents_clone := ENT.clone(*ents);
    defer ENT.shutdown(*ents_clone);

    ptr_clone, _ := ENT.get(*ents_clone, h1);
    (cast(*Foo) ptr_clone.base).val = 99;
    ptr_orig, _ := ENT.get(*ents, h1);
    expect(state, (cast(*Foo) ptr_orig.base).val == 10, "克隆体改动不影响原容器");

    h2, _ := ENT.create(*ents_clone, Foo.{ val = 20 });
    _, ok_orig := ENT.get(*ents, h2);
    expect(state, !ok_orig, "原容器取不到克隆体里创建的句柄");
    _, ok_clone := ENT.get(*ents_clone, h2);
    expect(state, ok_clone, "克隆体能取到自己的新句柄");
}

// Port of entities_test.odin: _get_sub_rejects_invalid_handles_test
entities_get_sub_rejects_invalid_handles :: (state: *Test_State) {
    Pos :: struct {
        x: float32;
        y: float32;
    }
    Unit :: struct {
        base: ENT.Base;
        pos: Pos;
        hp: int;
    }
    Wall :: struct {
        base: ENT.Base;
        hp: int;
    }
    ents: ENT.Entities;
    ENT.init(*ents, .[Unit, Wall], .[Pos], default_cap = 8);
    defer ENT.shutdown(*ents);

    a, _ := ENT.create(*ents, Unit.{ pos = .{ x = 1, y = 2 } });
    p, ok := ENT.get_sub(*ents, a, Pos);
    expect(state, ok && p.x == 1 && p.y == 2, "get_sub 返回组件");

    // 过期句柄不能拿到复用该槽位的新实体的组件。
    ENT.destroy(*ents, a);
    b, _ := ENT.create(*ents, Unit.{ pos = .{ x = 7, y = 8 } });
    expect(state, b.index == a.index, "新实体复用旧槽位");
    _, stale_ok := ENT.get_sub(*ents, a, Pos);
    expect(state, !stale_ok, "get_sub 拒绝过期句柄");
    pb, b_ok := ENT.get_sub(*ents, b, Pos);
    expect(state, b_ok && pb.x == 7 && pb.y == 8, "get_sub 接受当前代数的句柄");

    // 越界的 index / variant、零值句柄、没有该子结构的 variant 都返回 false。
    beyond := b;
    beyond.index = 5;
    _, beyond_ok := ENT.get_sub(*ents, beyond, Pos);
    expect(state, !beyond_ok, "get_sub 拒绝越界 index");
    bad_variant := b;
    bad_variant.variant = 9;
    _, variant_ok := ENT.get_sub(*ents, bad_variant, Pos);
    expect(state, !variant_ok, "get_sub 拒绝越界 variant");
    // u32 高位不能窄化为负 i32 后绕过范围检查。
    bad_indices: [2] ENT.Handle_Index = .[0x8000_0000, ENT.Handle_Index_Max];
    for index: bad_indices {
        bad := b;
        bad.index = index;
        bad_ptr, bad_ok := ENT.get_sub(*ents, bad, Pos);
        _, get_ok := ENT.get(*ents, bad);
        expect(state, bad_ptr == null && !bad_ok && !get_ok, "高位 index 被拒绝");
        expect(state, !ENT.destroy(*ents, bad), "高位 index 无法 destroy");
    }
    wrong_gen := b;
    wrong_gen.gen += 1;
    wrong_ptr, wrong_ok := ENT.get_sub(*ents, wrong_gen, Pos);
    expect(state, wrong_ptr == null && !wrong_ok, "错误代数被拒绝");
    _, zero_ok := ENT.get_sub(*ents, ENT.Handle.{}, Pos);
    expect(state, !zero_ok, "零值句柄被拒绝");
    w, _ := ENT.create(*ents, Wall.{ hp = 3 });
    _, wall_ok := ENT.get_sub(*ents, w, Pos);
    expect(state, !wall_ok, "没有该子结构的 variant 被拒绝");

    // clear 之后旧句柄同样失效。
    ENT.clear(*ents);
    c, _ := ENT.create(*ents, Unit.{ pos = .{ x = 5, y = 5 } });
    expect(state, c.index == b.index, "clear 后复用同一槽位");
    _, cleared_ok := ENT.get_sub(*ents, b, Pos);
    expect(state, !cleared_ok, "clear 后的旧句柄拿不到组件");
}

//@endregion

//@region 有限池安全边界

Pool_Test_Value :: struct {
    base: ENT.Base;
    value: *int;
}

Pool_Test_Other :: struct {
    base: ENT.Base;
}

// olib: Pool_Test_Entities :: Entities(union {Pool_Test_Value, Pool_Test_Other}, union {Base})
// Jai 的 Entities 不带类型参数，类型列表改由 pool_test_init 传入。
Pool_Test_Entities :: ENT.Entities;

// 未被任何 val_types 注册的实体类型（对应 olib 里“空 union 传 create_val”的失败分支）。
Unregistered_Value :: struct {
    base: ENT.Base;
}

pool_test_init :: (ents: *Pool_Test_Entities, capacity: int, allocator: Allocator = context.allocator) -> bool {
    return ENT.init(ents, .[Pool_Test_Value, Pool_Test_Other], .[ENT.Base], capacity, .[], allocator);
}

// 只在分配阶段注入失败，释放仍转交原 allocator，检验候选回滚和资源配对。
Pool_Test_Allocator :: struct {
    parent: Allocator;
    attempts: int;
    fail_after: int;
    frees: int;
}

pool_test_allocator_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, data: *void) -> *void {
    test_state := cast(*Pool_Test_Allocator) data;
    if mode == {
        case .ALLOCATE;
            test_state.attempts += 1;
            if test_state.attempts > test_state.fail_after return null;
    }
    if mode == {
        case .FREE;
            if old_memory != null test_state.frees += 1;
    }
    parent := test_state.parent;
    return parent.proc(mode, size, old_size, old_memory, parent.data);
}

// Port of entities_test.odin: _clear_free_list_reuse_test
entities_clear_free_list_reuse :: (state: *Test_State) {
    ents: Pool_Test_Entities;
    expect(state, pool_test_init(*ents, 5), "init 成功");
    defer ENT.shutdown(*ents);
    // olib: Handle_Variant(UNION_INDEX(union {Pool_Test_Value, Pool_Test_Other}, Pool_Test_Value))
    // Pool_Test_Value 是第一个 val_type，所以下标 0。
    variant: ENT.Handle_Variant = 0;
    a, _ := ENT.create(*ents, Pool_Test_Value.{});
    b, _ := ENT.create(*ents, Pool_Test_Value.{});
    c, _ := ENT.create(*ents, Pool_Test_Value.{});
    expect(state, ENT.destroy(*ents, a), "destroy(a) 成功");
    ENT.clear(*ents);
    ENT.clear(*ents);
    expect(state, ents.buffers[cast(int) variant].top == 3, "clear 不回退水位");
    expect(state, ENT.available_slots(*ents, variant) == 4, "两个尾部槽 + 三个空闲槽");
    count := 0;
    it := ENT.begin_sub(*ents, ENT.Base);
    while true {
        _, ok := ENT.next_sub(*it);
        if !ok break;
        count += 1;
    }
    expect(state, count == 0, "clear 后没有存活实体");
    olds: [3] ENT.Handle = .[a, b, c];
    for old: olds {
        reused, ok := ENT.create(*ents, Pool_Test_Value.{});
        expect(state, ok && reused.index == old.index && reused.gen == old.gen + 1,
        "按 free list 顺序复用槽位并推进代数");
        _, old_ok := ENT.get(*ents, old);
        expect(state, !old_ok, "复用后旧句柄失效");
    }
    _, tail_ok := ENT.create(*ents, Pool_Test_Value.{});
    _, full_ok := ENT.create(*ents, Pool_Test_Value.{});
    expect(state, tail_ok && !full_ok && ENT.available_slots(*ents, variant) == 0,
    "尾部槽用完后池满");
    ENT.clear(*ents);
    first, _ := ENT.create(*ents, Pool_Test_Value.{});
    expect(state, first.index == a.index && first.gen == a.gen + 2, "两次 clear 后代数继续递增");
    _, stale_ok := ENT.get_sub(*ents, b, ENT.Base);
    expect(state, !stale_ok, "被复用的旧句柄拿不到 Base 子结构");
}

// Port of entities_test.odin: _generation_exhaustion_test
entities_generation_exhaustion :: (state: *Test_State) {
    ents: Pool_Test_Entities;
    expect(state, pool_test_init(*ents, 4), "init 成功");
    defer ENT.shutdown(*ents);
    a, _ := ENT.create(*ents, Pool_Test_Value.{});
    b, _ := ENT.create(*ents, Pool_Test_Value.{});
    pa, pa_ok := ENT.get(*ents, a);
    expect(state, pa_ok, "get(a) 成功");
    pa.base.handle.gen = ENT.Handle_Gen_Max - 1;
    a = pa.base.handle;
    expect(state, ENT.destroy(*ents, a), "destroy(a) 成功");
    // 空闲槽在 clear 中不推进代数，最大代数仍可使用最后一次。
    ENT.clear(*ents);
    last, _ := ENT.create(*ents, Pool_Test_Value.{});
    expect(state, last.index == a.index && last.gen == ENT.Handle_Gen_Max, "最大代数仍可分配一次");
    expect(state, ENT.destroy(*ents, last), "destroy(last) 成功");
    expect(state, !ENT.destroy(*ents, last), "重复 destroy 失败");
    _, last_ok := ENT.get_sub(*ents, last, ENT.Base);
    expect(state, !last_ok, "退休槽位的句柄无效");
    expect(state, ents.buffers[cast(int) a.variant].retired == 1, "退休计数 +1");

    live, _ := ENT.create(*ents, Pool_Test_Value.{});
    expect(state, live.index == b.index, "退休槽位不再被分配");
    pl, pl_ok := ENT.get(*ents, live);
    expect(state, pl_ok, "get(live) 成功");
    pl.base.handle.gen = ENT.Handle_Gen_Max;
    live = pl.base.handle;
    ENT.clear(*ents);
    ENT.clear(*ents);
    expect(state, ents.buffers[cast(int) a.variant].retired == 2, "两次 clear 后退休计数为 2");
    expect(state, ENT.available_slots(*ents, a.variant) == 1, "只剩尾部槽可用");
    _, live_ok := ENT.get(*ents, live);
    expect(state, !live_ok, "退休后存活句柄失效");
    fresh, _ := ENT.create(*ents, Pool_Test_Value.{});
    expect(state, fresh.index == 3 && fresh.gen == 0, "新槽位从代数 0 开始");
    _, full_ok := ENT.create(*ents, Pool_Test_Value.{});
    expect(state, !full_ok, "池已满");
    expect(state, ENT.reserve(*ents, Pool_Test_Value, 6), "reserve 扩容成功");
    expect(state, ents.buffers[cast(int) a.variant].retired == 2, "扩容不影响退休计数");
    expect(state, ENT.available_slots(*ents, a.variant) == 2, "扩容后可用 2 个槽位");
    copied := ENT.clone(*ents);
    defer ENT.shutdown(*copied);
    ENT.clear(*copied);
    expect(state, copied.buffers[cast(int) a.variant].retired == 2, "克隆体保留退休计数");
    expect(state, ENT.available_slots(*copied, a.variant) == 3, "克隆体的空闲槽位");
}

// Port of entities_test.odin: _reserve_atomic_test
entities_reserve_atomic :: (state: *Test_State) {
    test_state := Pool_Test_Allocator.{ parent = context.allocator, fail_after = 100 };
    allocator := Allocator.{ proc = pool_test_allocator_proc, data = *test_state };
    ents: Pool_Test_Entities;
    expect(state, pool_test_init(*ents, 3, allocator), "init 成功");
    defer ENT.shutdown(*ents);
    value := New(int, false);
    defer free(cast(*void) value);
    value.* = 42;
    a, _ := ENT.create(*ents, Pool_Test_Value.{ value = value });
    b, _ := ENT.create(*ents, Pool_Test_Value.{});
    expect(state, ENT.destroy(*ents, b), "destroy(b) 成功");
    before := ents.buffers[cast(int) a.variant];
    other := ents.buffers[1];
    test_state.fail_after = test_state.attempts;
    expect(state, !ENT.reserve(*ents, Pool_Test_Value, 8), "分配失败时 reserve 返回 false");
    expect(state, buffer_eq(ents.buffers[cast(int) a.variant], before) && buffer_eq(ents.buffers[1], other),
    "失败时 buffer 表完全不变");
    pa, a_ok := ENT.get(*ents, a);
    expect(state, a_ok && (cast(*Pool_Test_Value) pa.base).value == value, "失败后句柄与实体值不变");
    expect(state, (cast(*Pool_Test_Value) pa.base).value.* == 42, "失败后用户指针字段仍是原值");
    expect(state, ENT.available_slots(*ents, a.variant) == 1, "失败后可用槽位不变");
    attempts := test_state.attempts;
    expect(state, ENT.reserve_variant(*ents, a.variant, 2), "容量已足够时不分配");
    expect(state, test_state.attempts == attempts && buffer_eq(ents.buffers[cast(int) a.variant], before),
    "容量足够时连分配都不发生");

    test_state.fail_after = 100;
    expect(state, ENT.reserve(*ents, Pool_Test_Value, 8), "恢复后扩容成功");
    expect(state, ents.buffers[cast(int) a.variant].data != before.data, "扩容换了新 buffer");
    expect(state, ents.buffers[cast(int) a.variant].cap == 8 && buffer_eq(ents.buffers[1], other),
    "只有目标 variant 扩容");
    moved, moved_ok := ENT.get(*ents, a);
    expect(state, moved_ok && (cast(*Pool_Test_Value) moved.base).value == value, "扩容后句柄仍有效");
    (cast(*Pool_Test_Value) moved.base).value.* = 77;
    expect(state, value.* == 77, "扩容搬移后用户指针仍指向同一块内存");
    reused, _ := ENT.create(*ents, Pool_Test_Value.{});
    expect(state, reused.index == b.index && reused.gen == b.gen + 1, "扩容保留 free list");
    _, stale_ok := ENT.get(*ents, b);
    expect(state, !stale_ok, "扩容后旧句柄仍失效");
    expect(state, ENT.reserve_variant(*ents, 1, 5), "variant 1 扩容成功");
    expect(state, ents.buffers[1].cap == 5, "variant 1 容量生效");
    ENT.shutdown(*ents);
    expect(state, value.* == 77, "shutdown 不得释放用户持有的指针字段");
    expect(state, test_state.frees == 4, "分配/释放配对：两次扩容 + 两个 buffer");
}

// Port of entities_test.odin: _init_validation_and_capacity_test
entities_init_validation_and_capacity :: (state: *Test_State) {
    test_state := Pool_Test_Allocator.{ parent = context.allocator, fail_after = 100 };
    allocator := Allocator.{ proc = pool_test_allocator_proc, data = *test_state };
    Wrong_Order :: struct {
        prefix: int;
        base: ENT.Base;
    }
    Nested :: struct {
        wrapped: Pool_Test_Other;
    }
    Missing :: struct {
        value: int;
    }
    Empty :: struct {}
    Not_First :: struct {
        empty: Empty;
        base: ENT.Base;
    }
    bad_order: ENT.Entities;
    bad_nested: ENT.Entities;
    bad_missing: ENT.Entities;
    bad_kind: ENT.Entities;
    bad_first: ENT.Entities;
    expect(state, !ENT.init(*bad_order, .[Pool_Test_Other, Wrong_Order], .[], 2, .[], allocator),
    "Base 不在首字段时 init 失败");
    expect(state, !ENT.init(*bad_nested, .[Pool_Test_Other, Nested], .[], 2, .[], allocator),
    "嵌套类型没有 Base 首字段时 init 失败");
    expect(state, !ENT.init(*bad_missing, .[Pool_Test_Other, Missing], .[], 2, .[], allocator),
    "缺 Base 字段时 init 失败");
    expect(state, !ENT.init(*bad_kind, .[Pool_Test_Other, int], .[], 2, .[], allocator),
    "非结构体 variant 时 init 失败");
    expect(state, !ENT.init(*bad_first, .[Pool_Test_Other, Not_First], .[], 2, .[], allocator),
    "首字段不是 Base 时 init 失败");
    expect(state, test_state.attempts == 0, "所有布局必须在任何分配之前校验完");

    ents: Pool_Test_Entities;
    bad_caps: [4] int = .[-1, 0, 1, 0x7FFF_FFFF_FFFF_FFFF];
    for capacity: bad_caps {
        expect(state, !pool_test_init(*ents, capacity, allocator), "非法容量必须拒绝");
        expect(state, !entities_installed(ents), "失败不改 ents");
    }
    caps_array: [2] int = .[2, 1];
    expect(state, !ENT.init(*ents, .[Pool_Test_Value, Pool_Test_Other], .[ENT.Base], 4096, caps_array, allocator),
    "caps 里出现非法容量时 init 失败");
    expect(state, test_state.attempts == 0, "容量校验不产生分配");
    expect(state, !ENT.entities_capacity_valid(0x7FFF_FFFF_FFFF_FFFF, 2), "_capacity_valid 拒绝字节乘法溢出");
    expect(state, !ENT.entities_capacity_valid(0, 2), "_capacity_valid 拒绝零长度");
    expect(state, ENT.entities_capacity_valid(1, 0x7FFF_FFFF), "_capacity_valid 接受 i32 上限");
    #if size_of(int) > size_of(s32) {
        expect(state, !ENT.entities_capacity_valid(1, 0x8000_0000), "_capacity_valid 拒绝超过 i32 的槽数");
    }

    test_state.fail_after = 1;
    expect(state, !pool_test_init(*ents, 2, allocator), "第二个 buffer 分配失败后 init 失败");
    expect(state, test_state.attempts == 2 && test_state.frees == 1, "回滚只释放已安装的 buffer");
    expect(state, !entities_installed(ents), "失败不改 ents");
    test_state.fail_after = 100;
    expect(state, pool_test_init(*ents, 2, allocator), "恢复后 init 成功");
    defer ENT.shutdown(*ents);
    a, _ := ENT.create(*ents, Pool_Test_Value.{});
    before := ents.buffers[cast(int) a.variant];
    attempts := test_state.attempts;
    for capacity: bad_caps {
        expect(state, !ENT.reserve(*ents, Pool_Test_Value, capacity), "非法容量必须拒绝扩容");
    }
    expect(state, !ENT.reserve_variant(*ents, ENT.Handle_Variant_Max, 3), "越界 variant 拒绝扩容");
    expect(state, ENT.available_slots(*ents, ENT.Handle_Variant_Max) == 0, "越界 variant 没有可用槽位");
    expect(state, !ENT.init(*ents, .[Pool_Test_Value, Pool_Test_Other], .[ENT.Base], 4, .[], allocator),
    "重复 init 必须拒绝");
    expect(state, test_state.attempts == attempts && buffer_eq(ents.buffers[cast(int) a.variant], before),
    "被拒绝的调用不改 buffer");
    _, alive := ENT.get(*ents, a);
    expect(state, alive, "被拒绝的调用不影响存活句柄");
    // olib: create_val(&ents, empty_union) —— 空 union 的 tag 无效，必须失败。
    // Jai 没有 union tag，等价断言换成“未注册的实体类型被拒绝”。
    _, empty_ok := ENT.create(*ents, Unregistered_Value.{});
    expect(state, !empty_ok, "未注册类型不会被创建");
}

//@endregion

// Loop scopes adapted.
