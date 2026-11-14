#scope_file

#scope_export
// onet core: writer/reader pools.
//
// The pool is a plain stack of heap structs; reset keeps capacity.

Writer_Pool :: struct {
    items: [..] *Writer;
}

writer_pool_init :: (p: *Writer_Pool, capacity: int = 8) {
    p.items = new_dynamic(*Writer, 0, capacity);
}

writer_pool_destroy :: (p: *Writer_Pool) {
    for w: p.items {
        writer_destroy(w);
        free(w);
    }

    release(p.items);
    p.* = .{
    };
}

// Rents a writer, reusing a pooled one when available.

writer_pool_get :: (p: *Writer_Pool, allocator := context.allocator) -> *Writer {
    if (p.items).count > 0 {
        w := p.items[(p.items).count - 1];
        pop(*p.items);
        return w;
    }

    w := new_one(Writer, allocator);
    writer_init(w);
    return w;
}

// Returns a writer to the pool after resetting it.

writer_pool_put :: (p: *Writer_Pool, w: *Writer) {
    writer_reset(w);
    array_add(*p.items, w);
}

Reader_Pool :: struct {
    items: [..] *Reader;
}

reader_pool_init :: (p: *Reader_Pool, capacity: int = 8) {
    p.items = new_dynamic(*Reader, 0, capacity);
}

reader_pool_destroy :: (p: *Reader_Pool) {
    for r: p.items {
        free(r);
    }

    release(p.items);
    p.* = .{
    };
}

reader_pool_get :: (p: *Reader_Pool, allocator := context.allocator) -> *Reader {
    if (p.items).count > 0 {
        r := p.items[(p.items).count - 1];
        pop(*p.items);
        return r;
    }

    return new_one(Reader, allocator);
}

reader_pool_put :: (p: *Reader_Pool, r: *Reader) {
    r.data = .[];
    r.bit_position = 0;
    r.err = .None;
    array_add(*p.items, r);
}

// Cast semantics adapted.
// Loop scopes adapted.
