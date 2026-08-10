// arena.jai
// Port of Ascension/tlib/handle/handle_map_growing/arena_default.odin
// (the Odin package split this into arena_default.odin for non-js and
// arena_js.odin for js; this Jai port targets Windows/non-js so only the
// growing arena is ported).
//
// A simple linear-growing arena: items are packed into fixed-size blocks.
// Blocks are never moved, so pointers into the arena stay stable.

#import "Basic";

Arena_Block :: struct {
    memory: *u8;
    size:   s64;
    used:   s64;
    next:   *Arena_Block;
}

Arena :: struct {
    curr_block: *Arena_Block;
    all_blocks: *Arena_Block;
    block_size: s64;
}

// One memory page, matching the minimum growing-arena block size in Odin.
ARENA_DEFAULT_BLOCK_SIZE :: 4096;

arena_initialized :: (arena: Arena) -> bool {
    return arena.curr_block != null;
}

arena_init :: (arena: *Arena, block_size: s64 = ARENA_DEFAULT_BLOCK_SIZE) -> bool {
    arena.block_size = block_size;
    arena.curr_block = null;
    arena.all_blocks = null;
    return true;
}

arena_allocate :: (arena: *Arena, size: s64, alignment: s64) -> *void {
    block := arena.curr_block;
    if block != null {
        aligned_used := (block.used + alignment - 1) / alignment * alignment;
        if aligned_used + size <= block.size {
            result := block.memory + aligned_used;
            block.used = aligned_used + size;
            return result;
        }
    }

    block_size := max(size + alignment, arena.block_size);
    new_block := New(Arena_Block);
    new_block.memory = cast(*u8) alloc(block_size);
    new_block.size = block_size;
    new_block.used = size;
    new_block.next = arena.all_blocks;
    arena.all_blocks = new_block;
    arena.curr_block = new_block;
    return new_block.memory;
}

arena_free_all :: (arena: *Arena) {
    // Keep the first block (it will be reused); free the rest.
    first := arena.all_blocks;
    block := arena.all_blocks;
    while block != null {
        next := block.next;
        if block != first {
            free(block.memory);
            free(block);
        }
        block = next;
    }
    if first != null {
        first.used = 0;
        first.next = null;
        arena.all_blocks = first;
        arena.curr_block = first;
    } else {
        arena.all_blocks = null;
        arena.curr_block = null;
    }
}

arena_destroy :: (arena: *Arena) {
    block := arena.all_blocks;
    while block != null {
        next := block.next;
        free(block.memory);
        free(block);
        block = next;
    }
    arena.all_blocks = null;
    arena.curr_block = null;
    arena.block_size = 0;
}

arena_alloc_proc :: (mode: Allocator_Mode, size: s64, old_size: s64, old_memory: *void, allocator_data: *void) -> *void {
    arena := cast(*Arena) allocator_data;
    if mode == .ALLOCATE {
        return arena_allocate(arena, size, 16);
    }
    // Arena semantics: individual frees/resizes are no-ops; free everything
    // by calling arena_free_all directly (Jai's Allocator_Mode has no FREE_ALL).
    return null;
}

arena_allocator :: (arena: *Arena) -> Allocator {
    return .{ proc = arena_alloc_proc, data = cast(*void) arena };
}
