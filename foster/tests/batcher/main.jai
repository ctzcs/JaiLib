// M3 sample: the Batcher draws 2D primitives — rects, rounded rects, circles,
// lines, gradients — plus a generated texture. Auto-exits after ~3 seconds.
// Build from the repo root:  jai first.jai - batcher
// Default shaders are embedded; run from any working directory.

#import "Basic";
#import "File";
#import "Math";
#import "foster";

main :: () {
    App.startup = startup;
    App.render = render;
    App.update = update;

    app_run(.{
        application_name = "jfoster batcher sample",
        window_title = "jfoster batcher",
        width = 1280,
        height = 720,
    });

    app_destroy();
}

State :: struct {
    batcher: *Batcher = null;
    checker: *Texture = null;
}

S: State;

startup :: () {
    S.batcher = batcher_create(App.device, "main");
}

update :: () {
    if App.time.elapsed > 3.0 app_exit();
}

render :: () {
    t := App.time.elapsed;

    batcher_clear(S.batcher);
    b := S.batcher;

    // gradient background
    batcher_rect_gradient(b, .{ 0, 0, 1280, 720 },
        Color.{ 30, 30, 60, 255 },
        Color.{ 30, 30, 60, 255 },
        Color.{ 90, 40, 120, 255 },
        Color.{ 20, 60, 100, 255 });

    // rounded rects
    batcher_rect_rounded(b, .{ 100, 100, 200, 140 }, 20, Color_White);
    batcher_rect_rounded(b, .{ 350, 100, 200, 140 }, 20, Color.{ 255, 100, 100, 255 });
    batcher_rect_rounded_line(b, .{ 600, 100, 200, 140 }, 20, 4, Color.{ 100, 255, 200, 255 });

    // circles
    batcher_circle(b, .{ 180, 380 }, 70, 32, Color.{ 100, 200, 255, 255 });
    batcher_circle_gradient(b, .{ 380, 380 }, 70, 32, Color.{ 255, 255, 100, 255 }, Color.{ 255, 100, 100, 255 });
    batcher_circle_line(b, .{ 580, 380 }, 70, 6, 32, Color_White);

    // lines
    batcher_line(b, .{ 700, 320 }, .{ 900, 440 }, 4, Color.{ 255, 200, 100, 255 });
    batcher_line_gradient(b, .{ 700, 460 }, .{ 900, 580 }, 4, Color.{ 100, 255, 100, 255 }, Color.{ 100, 100, 255, 255 });

    // animated radial bar
    batcher_radial_bar(b, .{ 1050, 380 }, cast(float) ((sin(t * 2.0) + 1.0) * 0.5), 40, 80, Color.{ 255, 150, 50, 255 });

    // dashed circle + rect line
    batcher_circle_dashed(b, .{ 180, 580 }, 50, 3, 24, Color.{ 200, 200, 255, 255 }, 8, cast(float) (t * 10.0));
    batcher_rect_line(b, .{ 300, 530, 180, 100 }, 2, Color.{ 255, 255, 255, 255 });

    // transformed quad (matrix stack)
    batcher_push_matrix_trs(b, .{ 800, 600 }, .{ 50, 50 }, .{ 1, 1 }, cast(float) (t * 0.8));
    batcher_rect_gradient(b, .{ -50, -50, 100, 100 },
        Color.{ 255, 0, 0, 255 }, Color.{ 0, 255, 0, 255 },
        Color.{ 0, 0, 255, 255 }, Color.{ 255, 255, 0, 255 });
    batcher_pop_matrix(b);

    // triangle fan
    batcher_triangle(b, .{ 1100, 530 }, .{ 1200, 600 }, .{ 1000, 600 }, Color.{ 150, 255, 150, 255 });

    batcher_render(b, drawable_target_window(App.window));
}
