// DragonLib EntitiesDemo workloads, adapted to Jai's fixed u16-index pools.
// Console benchmark: eight workloads, warmup, mean/P95/ns per operation.
// auto also checks sparse iteration, stale handles, component access and Clear.
// The container supports u32 indices; this benchmark uses 100,000 live entities.
#import "Basic";
#import "test_support";
#import "demo_console";
E :: #import "entities";
M :: #import "Math";

Position :: struct { x, y: float32; }
Velocity :: struct { x, y: float32; }
PerfEntity :: struct { base: E.Base; position: Position; velocity: Velocity; }
COUNT :: 100000;
ITERATIONS :: 25;
WARMUP :: 4;
checksum: float64;

value :: (index: s64) -> PerfEntity {
    return .{position = .{cast(float32) index * 0.25, -cast(float32) index * 0.125}, velocity = .{0.5, -0.25}};
}

update_entities :: (ents: *E.Entities, kind: s64, handles: [] E.Handle) {
    if kind == 0 || kind == 1 {
        it := E.begin_val(ents, PerfEntity);
        while true {
            p, ok := E.next_val(*it); if !ok break;
            p.position.x += p.velocity.x; p.position.y += p.velocity.y;
        }
    } else if kind == 2 {
        it := E.begin_sub(ents, Position);
        while true {
            raw, ok := E.next_sub(*it); if !ok break;
            p := cast(*Position) raw; p.x += 1; p.y -= 1;
        }
    } else if kind == 3 {
        for h: handles {
            ptr, ok := E.get(ents, h); assert(ok);
            p := cast(*PerfEntity) ptr.base;
            p.position.x += p.velocity.x; p.position.y += p.velocity.y;
        }
    } else if kind == 4 {
        for h: handles {
            p, ok := E.get_sub(ents, h, Position); assert(ok);
            p.x += 1; p.y -= 1;
        }
    } else {
        // Dense dataset only: get_buffer exposes the high-water range, including holes.
        for *p: E.get_buffer(ents, PerfEntity) {
            p.position.x += p.velocity.x; p.position.y += p.velocity.y;
        }
    }
}

create_all :: (ents: *E.Entities, handles: [] E.Handle) {
    for *h, i: handles { result, ok := E.create(ents, value(i)); assert(ok); <<h = result; }
}

destroy_all :: (ents: *E.Entities, handles: [] E.Handle) {
    for h: handles assert(E.destroy(ents, h));
}

milliseconds :: (start: Apollo_Time) -> float64 {
    seconds, _ := to_float64_seconds(current_time_monotonic() - start);
    return seconds * 1000;
}

report :: (name: string, ops: s64, samples: [] float64) {
    total: float64;
    for s: samples total += s;
    // Insertion sort of 25 timing samples, outside the measured region.
    for i: 1..samples.count-1 {
        sample := samples[i]; j := i;
        while j > 0 && samples[j-1] > sample { samples[j] = samples[j-1]; j -= 1; }
        samples[j] = sample;
    }
    mean := total / cast(float64) samples.count;
    p95 := cast(s64) M.ceil(cast(float64) samples.count * 0.95) - 1;
    print("% | ops=% | mean=% ms | P95=% ms | % ns/op\n", name, ops, mean, samples[p95], mean * 1000000 / cast(float64) ops);
}

check_lifecycle :: (st: *Test_State) {
    ents: E.Entities;
    E.init(*ents, .[PerfEntity], .[Position], default_cap = 16);
    defer E.shutdown(*ents);
    old, ok := E.create(*ents, value(0)); expect(st, ok, "create succeeds");
    expect(st, E.destroy(*ents, old), "destroy succeeds");
    _, stale_component := E.get_sub(*ents, old, Position);
    expect(st, !stale_component, "component access rejects destroyed handle");
    current, reused := E.create(*ents, value(1)); expect(st, reused, "slot reused");
    _, stale_reused := E.get_sub(*ents, old, Position);
    expect(st, !stale_reused, "component access rejects old generation after reuse");
    invalid := E.Handle.{index = 65535, variant = 255};
    _, invalid_ok := E.get_sub(*ents, invalid, Position);
    expect(st, !invalid_ok, "component access rejects invalid variant and index");
    _, absent_ok := E.get_sub(*ents, current, Velocity);
    expect(st, !absent_ok, "component access rejects unregistered type");
    E.clear(*ents);
    fresh, fresh_ok := E.create(*ents, value(2)); expect(st, fresh_ok, "create after clear succeeds");
    _, old_ok := E.get(*ents, current);
    expect(st, !old_ok, "clear invalidates previous generation");
    _, fresh_valid := E.get(*ents, fresh); expect(st, fresh_valid, "new handle after clear is valid");
}

main :: () {
    print("DragonLib EntitiesDemo workloads: % entities, % samples, % warmup runs\n", COUNT, ITERATIONS, WARMUP);
    print("Use an optimized build for timing comparisons. Allocation/GC metrics are not measured.\n");
    st := test_begin();
    check_lifecycle(*st);
    dense, sparse, lifecycle: E.Entities;
    E.init(*dense, .[PerfEntity], .[Position], default_cap = COUNT + 1);
    E.init(*sparse, .[PerfEntity], .[Position], default_cap = COUNT + 1);
    E.init(*lifecycle, .[PerfEntity], .[Position], default_cap = COUNT + 1);
    defer E.shutdown(*dense); defer E.shutdown(*sparse); defer E.shutdown(*lifecycle);
    handles := NewArray(COUNT, E.Handle);
    lifetime_handles := NewArray(COUNT, E.Handle);
    defer free(handles.data); defer free(lifetime_handles.data);
    create_all(*dense, handles);
    // Build all slots before removal, preserving a true 50%-hole high-water range.
    create_all(*sparse, lifetime_handles);
    for h, i: lifetime_handles if i % 2 != 0 assert(E.destroy(*sparse, h));
    alive := 0;
    iterator := E.begin_val(*sparse, PerfEntity);
    while true { _, ok := E.next_val(*iterator); if !ok break; alive += 1; }
    expect(*st, alive == COUNT / 2, "sparse iterator visits only live slots");
    expect(*st, E.get_buffer(*sparse, PerfEntity).count == COUNT, "sparse storage preserves high-water range");
    names := string.["Dense ForEach", "Sparse 50% ForEach", "Component ForEach", "Sequential GetRef", "Component GetRef", "Raw dense buffer"];
    for name, kind: names {
        ents := ifx kind == 1 then *sparse else *dense;
        for 0..WARMUP-1 update_entities(ents, kind, handles);
        samples: [ITERATIONS] float64;
        before := (cast(*PerfEntity) E.get_buffer(ents, PerfEntity).data).position.x;
        for *s: samples {
            start := current_time_monotonic();
            update_entities(ents, kind, handles);
            <<s = milliseconds(start);
        }
        buffer := E.get_buffer(ents, PerfEntity);
        delta := ifx kind == 2 || kind == 4 then 1.0 else 0.5;
        expect(*st, buffer[0].position.x == before + delta * ITERATIONS, "benchmark mutates expected entity values");
        for p: buffer if p.base.handle.index != 0 checksum += cast(float64) p.position.x;
        report(name, ifx kind == 1 then COUNT / 2 else COUNT, samples);
    }
    for 0..1 { create_all(*lifecycle, lifetime_handles); destroy_all(*lifecycle, lifetime_handles); }
    create_samples, destroy_samples: [ITERATIONS] float64;
    for i: 0..ITERATIONS-1 {
        start := current_time_monotonic(); create_all(*lifecycle, lifetime_handles); create_samples[i] = milliseconds(start);
        start = current_time_monotonic(); destroy_all(*lifecycle, lifetime_handles); destroy_samples[i] = milliseconds(start);
    }
    report("Create (reuse)", COUNT, create_samples); report("Destroy", COUNT, destroy_samples);
    print("Checksum: %\n", checksum);
    demo_console_finish(test_summary("EntitiesDemo", *st));
}
