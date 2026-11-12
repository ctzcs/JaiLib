#import "Basic";

Scene_Router :: struct(Screen: Type) {
    current, previous: Screen;
    transitioning: bool;
    progress: float32 = 1;
    elapsed, duration: float32;
}

scene_init :: (router: *Scene_Router($Screen), initial: Screen) {
    <<router = .{current = initial, previous = initial};
}

scene_switch :: (router: *Scene_Router($Screen), screen: Screen, duration: float32 = 0) {
    if router.current == screen return;
    router.previous = router.current;
    router.current = screen;
    router.elapsed = 0;
    router.duration = max(duration, cast(float32) 0);
    router.transitioning = duration > 0;
    router.progress = cast(float32) (ifx router.transitioning then 0 else 1);
}

scene_update :: (router: *Scene_Router($Screen), dt: float32) {
    if !router.transitioning return;
    router.elapsed += max(dt, cast(float32) 0);
    router.progress = min(cast(float32) 1, router.elapsed / router.duration);
    if router.progress >= 1 router.transitioning = false;
}
