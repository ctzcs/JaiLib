Test :: struct { assertions: int; tests_run: int; filter: string; }
expect :: ( t : * Test , condition : bool , message : string = "" ) -> bool {
t . assertions += 1 ; if ! condition print ( "FAILED: %\n" , message ) ; assert ( condition ) ; return condition ;
}
expect_value :: ( t : * Test , actual : $T , expected : T , message : string = "" ) -> bool {
t . assertions += 1 ; if actual != expected print ( "FAILED: % actual %, expected %\n" , message , actual , expected ) ; assert ( actual == expected ) ; return true ;
}
expectf :: ( t : * Test , condition : bool , message : string , args : .. Any ) -> bool { return expect ( t , condition , message ) ; }

 operator == :: ( a : U128 , b : U128 ) -> bool { return a . low == b . low && a . high == b . high ; }

 // Loop scopes adapted. 

 // Iterator semantics adapted.

 nan32 :: ( ) -> float32 { bits : u32 = 0x7fc00000 ; return ( cast ( * float32 ) * bits ) .* ; } 
raw_data :: (a: []$T) -> *T { return a.data; }
raw_data :: (a: string) -> *u8 { return a.data; }

min :: ($T: Type) -> T {
 #if T==s8 || T==s16 || T==s32 || T==s64 return cast,trunc(T)((cast(u64)1)<<(size_of(T)*8-1));
 else return 0;
}
max :: ($T: Type) -> T {
 #if T==s8 || T==s16 || T==s32 || T==s64 return cast,trunc(T)(0xffffffffffffffff>>(65-size_of(T)*8));
 else return cast,trunc(T)(0xffffffffffffffff>>(64-size_of(T)*8));
}
Worker :: struct { thread: Thread.Thread; callback: #type (*void); user: *void; }
create_worker :: (user:*void, callback: #type (*void)) -> *Worker {
 worker:=New(Worker); worker.user=user; worker.callback=callback;
 assert(Thread.thread_init(*worker.thread, (thread:*Thread.Thread)->s64 { worker:=cast(*Worker)thread.data; worker.callback(worker.user); return 0; }));
 worker.thread.data=worker; Thread.thread_start(*worker.thread); return worker;
}
join_worker :: (worker:*Worker) { assert(Thread.thread_is_done(*worker.thread,-1)); }
destroy_worker :: (worker:*Worker) { Thread.thread_deinit(*worker.thread); free(worker); }
Tracking_Allocator :: struct { backing: Allocator; allocation_map: H.Table(*void,int); bad_free_array: [..]*void; }
tracking_allocator_init :: (tracker:*Tracking_Allocator, backing:Allocator) { tracker.backing=backing; tracker.allocation_map.allocator=backing; tracker.bad_free_array.allocator=backing; }
tracking_allocator :: (tracker:*Tracking_Allocator) -> Allocator { return .{tracking_allocator_proc,tracker}; }
tracking_allocator_proc :: (mode:Allocator_Mode,size:s64,old_size:s64,old_memory:*void,data:*void) -> *void {
 t:=cast(*Tracking_Allocator)data; push_allocator(t.backing);
 if mode==.FREE {
  if old_memory==null return null;
  stored,found:=table_get(*t.allocation_map,old_memory);
  if !found { array_add(*t.bad_free_array,old_memory); return null; }
  H.table_remove(*t.allocation_map,old_memory);
  return t.backing.proc(.FREE,0,stored,old_memory,t.backing.data);
 }
 if mode==.RESIZE {
  if old_memory==null return tracking_allocator_proc(.ALLOCATE,size,0,null,data);
  stored,found:=table_get(*t.allocation_map,old_memory); assert(found);
  result:=tracking_allocator_proc(.ALLOCATE,size,0,null,data);
  memcpy(result,old_memory,min(size,stored)); tracking_allocator_proc(.FREE,0,stored,old_memory,data); return result;
 }
 result:=t.backing.proc(mode,size,old_size,old_memory,t.backing.data);
 if mode==.ALLOCATE && result!=null H.table_set(*t.allocation_map,result,size);
 return result;
}
tracking_allocator_destroy :: (t:*Tracking_Allocator) {
 push_allocator(t.backing);
 for size,pointer:t.allocation_map t.backing.proc(.FREE,0,size,pointer,t.backing.data);
 H.deinit(*t.allocation_map); array_free(t.bad_free_array); t.*=.{};
}

nan64 :: () -> float64 { bits:u64=0x7ff8000000000000; return (cast(*float64)*bits).*; }
panic :: (message:string) { assert(false,message); }

SceneTypes :: #import "thirdparty/onet/scenes";
TestHash :: #import "Hash";
test_resource_hash :: (k:SceneTypes.Resource_Key) -> u32 { return TestHash.get_hash(k.handle, TestHash.get_hash(k.namespace, cast(u32)5381)); }
test_resource_equal :: (a:SceneTypes.Resource_Key,b:SceneTypes.Resource_Key) -> bool { return a.namespace==b.namespace && a.handle==b.handle; }
expect_value :: (t:*Test,a:SceneTypes.Ticket,b:SceneTypes.Ticket,message:string="") -> bool { return expect(t,SceneTypes.operator ==(a,b),message); }
PhysicsTypes :: #import "thirdparty/onet/physics";
expect_value :: (t:*Test,a:PhysicsTypes.Snapshot,b:PhysicsTypes.Snapshot,message:string="") -> bool { return expect(t,a.tick==b.tick && a.time==b.time && a.position==b.position && a.rotation==b.rotation && a.linear_velocity==b.linear_velocity && a.angular_velocity==b.angular_velocity && a.flags==b.flags,message); }

run_case :: (t:*Test,name:string,test:#type (*Test)) { if t.filter.count>0 && !Str.contains(name,t.filter) return; print("%\n",name); test(t); t.tests_run+=1; }
