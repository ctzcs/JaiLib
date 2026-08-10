#import "Basic";
#import "test_support";

ENT :: #import "entities/entities";

// operator == must be visible in this scope for bare == on handles.
operator == :: (a: ENT.Handle, b: ENT.Handle) -> bool {
    return a.index == b.index && a.gen == b.gen && a.variant == b.variant;
}

// Port of entities_test.odin: _basic_test
test_entities_basic :: (state: *Test_State) {
    Named :: struct { name: string; }
    Foo :: struct {
        base:  ENT.Base;
        named: Named;
        val:   u8;
    }
    Bar :: struct {
        base:  ENT.Base;
        named: Named;
        val:   float64;
    }
    Baz :: struct {
        base: ENT.Base;
    }

    ents: ENT.Entities;
    ENT.init(*ents, .[Foo, Bar, Baz], .[ENT.Base, Named], default_cap = 64);

    expect(state, ENT.get_buffer(*ents, Foo).count == 0, "Foo buffer empty");
    expect(state, ENT.get_buffer(*ents, Bar).count == 0, "Bar buffer empty");

    a, _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "First" }, val = 1 });
    expect(state, !(a == ENT.Handle.{}), "a is not the null handle");
    expect(state, a.variant == 0, "a.variant == 0 (Foo)");

    expect(state, ENT.get_buffer(*ents, Foo).count == 1, "Foo buffer has 1 after create");
    expect(state, ENT.destroy(*ents, a), "destroy(a) ok");

    a_ptr, a_ok := ENT.get(*ents, a);
    expect(state, !a_ok, "get(a) fails after destroy");
    expect(state, a_ptr.base == null, "a_ptr.base is null");

    b, _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "Second" }, val = 2 });
    expect(state, !(b == ENT.Handle.{}), "b is not the null handle");
    expect(state, b.index == a.index, "b reuses a's slot index");

    b_ptr, b_ok := ENT.get(*ents, b);
    expect(state, b_ok, "get(b) ok");
    expect(state, b_ptr.base != null, "b_ptr.base not null");
    expect(state, (cast(*Foo) b_ptr.base).named.name == "Second", "entity name is Second");
    expect(state, !(a == b), "a != b");

    ENT.shutdown(*ents);
}

// Port of entities_test.odin: _iter_val_test
test_entities_iter_val :: (state: *Test_State) {
    Foo :: struct {
        base: ENT.Base;
        val:  u8;
    }

    ents: ENT.Entities;
    ENT.init(*ents, .[Foo], .[], default_cap = 64);

    h0, _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, val = 0 });
    h1, _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, val = 0 });
    h2, _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, val = 0 });
    h3, _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, val = 0 });
    h4, _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, val = 0 });

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
    expect(state, counter == 2, "val iteration counts 2 live entities");
    expect(state, !(h1 == h3), "h1 != h3");

    ENT.shutdown(*ents);
}

// Port of entities_test.odin: _iter_sub_test
test_entities_iter_sub :: (state: *Test_State) {
    Named :: struct { name: string; }
    Foo :: struct {
        base:  ENT.Base;
        named: Named;
        val:   u8;
    }
    Bar :: struct {
        base:  ENT.Base;
        named: Named;
        val:   float64;
    }
    Baz :: struct {
        base: ENT.Base;
    }

    ents: ENT.Entities;
    ENT.init(*ents, .[Foo, Bar, Baz], .[ENT.Base, Named], default_cap = 64);

    h0, _ := ENT.create(*ents, Bar.{ base = ENT.Base.{}, named = .{ name = "b" }, val = 0 });
    h1, _ := ENT.create(*ents, Bar.{ base = ENT.Base.{}, named = .{ name = "b" }, val = 0 });
    h2, _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" }, val = 0 });
    _ := ENT.create(*ents, Baz.{ base = ENT.Base.{} });
    _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" }, val = 0 });
    _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" }, val = 0 });
    _ := ENT.create(*ents, Bar.{ base = ENT.Base.{}, named = .{ name = "b" }, val = 0 });
    _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" }, val = 0 });
    _ := ENT.create(*ents, Baz.{ base = ENT.Base.{} });
    _ := ENT.create(*ents, Bar.{ base = ENT.Base.{}, named = .{ name = "b" }, val = 0 });
    _ := ENT.create(*ents, Baz.{ base = ENT.Base.{} });
    _ := ENT.create(*ents, Baz.{ base = ENT.Base.{} });
    _ := ENT.create(*ents, Foo.{ base = ENT.Base.{}, named = .{ name = "f" }, val = 0 });

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
    expect(state, counter == 6, "sub iteration counts 6 named entities");
    ENT.shutdown(*ents);
}
