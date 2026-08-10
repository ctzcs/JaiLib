// main.jai
// Port of Ascension/src/main.odin
// App shell: window loop, Game/Editor mode switch.

#import "Basic";
#import "bindings/raylib";
#import "core/build";
#import "core/screen";
#import "core/frame";
#import "core/libs";
#import "content/game";
#import "content/entity";
#import "editor/editor";

DEFAULT_MODE :: Mode.Editor;

App :: struct {
    mode:   Mode;
    input:  InputState;
    game:   GameState;
    editor: EditorState;
}

Mode :: enum u32 {
    Game;
    Editor;
}

init :: (app: *App) {
    app.input = InputState.{};
    init_game(*app.game);
    #if DEV {
        app.mode = DEFAULT_MODE;
        init_editor(*app.editor);
    } else {
        app.mode = .Game;
    }
}

destroy :: (app: *App) {
    #if DEV {
        destroy_editor(*app.editor);
    }
    destroy_game(*app.game);
}

window_loop :: (app: *App) {
    while !WindowShouldClose() {
        update(app);
        render(app);
    }
}

update :: (app: *App) {
    poll_input(*app.input);
    frame := FrameContext.{
        dt    = GetFrameTime(),
        input = app.input,
    };
    #if DEV {
        if IsKeyPressed(.F1) {
            if app.mode == .Game {
                app.mode = .Editor;
            } else {
                app.mode = .Game;
            }
        }
    }
    if app.mode == .Game {
        update_game(*app.game, *frame);
    } else if app.mode == .Editor {
        #if DEV {
            update_editor(*app.editor);
        }
    }
}

render :: (app: *App) {
    BeginDrawing();
    if app.mode == .Game {
        draw_game(*app.game);
    } else if app.mode == .Editor {
        #if DEV {
            draw_editor(*app.editor);
        }
    }
    EndDrawing();
}


main :: () {
    InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Ascension : Sword Tao");
    defer CloseWindow();
    app := New(App);
    init(app);
    window_loop(app);
    destroy(app);
    free(app);
}
