// Authoritative game state; no window, GPU or editor dependency.
World :: struct {
    ticks: s64;
    elapsed: float64;
    paused: bool;
}

step :: (world: *World, dt: float64) {
    if world.paused || dt < 0 return;
    world.ticks += 1;
    world.elapsed += dt;
}

reset :: (world: *World) {
    world.* = .{};
}
