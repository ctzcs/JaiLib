// M1 sample: app lifecycle with a fixed 60Hz update step.
// The window title shows update/render frame counters; auto-exits after ~3s
// (set AUTO_EXIT to false to keep it running).
// Check from JaiLib: python tools/check/main.py --only foster/tests/app

#import "Basic";
#import "foster";

AUTO_EXIT :: true;

main :: () {
    App.startup = startup;
    App.update = update;
    App.render = render;

    app_run(.{
        application_name = "jfoster app sample",
        window_title = "jfoster app",
        width = 1280,
        height = 720,
    });

    app_destroy();
}

startup :: () {
    log_info("startup!");
}

update :: () {
    // title updates twice a second; demonstrate OnInterval parity
    if time_on_interval(App.time, 0.5) {
        ups := App.time.frame;
        fps := App.time.render_frame;
        window_set_title(App.window, tprint("jfoster app  |  updates %  renders %", ups, fps));
    }

    if AUTO_EXIT && App.time.elapsed > 3.0 {
        log_info("auto-exit (3s reached)");
        app_exit();
    }
}

render :: () {
    // M2: real rendering lands with the SDL_GPU port
}
