#import "Basic";
MSG :: #import "messaging";
W :: #import "world";
S :: #import "storage";
Screen :: enum { Menu; Game; }
sum: s64;
consume :: (value: s64,user: *void) {sum+=value;}
embedded :: (user: *void,path: string,allocator: Allocator) -> ([]u8,bool) {
    if path != "hello.txt" return .[],false;
    push_allocator(allocator);
    data := copy_string("embedded");return .{data=data.data,count=data.count},true;
}
main :: () {
    q: MSG.Command_Queue(s64); defer MSG.command_destroy(*q);
    MSG.command_enqueue(*q,20);MSG.command_enqueue(*q,22);
    n := MSG.command_drain(*q,consume);
    scene: W.Scene_Router(Screen);
    W.scene_init(*scene,.Menu);W.scene_switch(*scene,.Game,1);W.scene_update(*scene,.5);
    game: S.Game_Storage;S.game_resources_set(*game,.{read=embedded});
    bytes,ok := S.storage_read(*game.resources,"hello.txt");defer free(bytes.data);
    if n == 2 && sum == 42 && scene.current == .Game && scene.progress == .5 && ok && bytes.count == 8 print("JaiLib WASM64 CPU PASS: queue=42 scene=Game storage=embedded\n");
    else print("JaiLib WASM64 CPU FAIL\n");
}
