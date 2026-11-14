#import "Basic";
#load "../src/core/world.jai";

main :: () {
    a, b: World;
    step(*a, 0.5);
    assert(a.ticks == 1 && a.elapsed == 0.5 && b.ticks == 0);
    a.paused = true;
    step(*a, 1);
    assert(a.ticks == 1);
    reset(*a);
    assert(a.ticks == 0 && !a.paused);
    step(*a, -1);
    assert(a.ticks == 0);
    print("world: PASS\n");
}
