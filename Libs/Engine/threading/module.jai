#import "Basic";
TH :: #import "Thread"(LOAD_THREAD_GROUP=false);

Job_Proc :: #type (first: s64, end: s64, user: *void, worker: s64);
Job_Handle :: struct {
    mutex: TH.Mutex;
    changed: TH.Condition_Variable;
    remaining: s64;
}
Job_Item :: struct { proc: Job_Proc; first, end: s64; user: *void; handle: *Job_Handle; }
Job_Worker :: struct { thread: TH.Thread; scheduler: *Job_Scheduler; index: s64; }
Job_Scheduler :: struct {
    mutex: TH.Mutex;
    available: TH.Condition_Variable;
    queue: [] Job_Item;
    head, count: s64;
    workers: [] Job_Worker;
    started: s64;
    stopping: bool;
    initialized: bool;
}

jobs_init :: (s: *Job_Scheduler, worker_count: s64 = 2, capacity: s64 = 256) -> bool {
    if worker_count < 0 || capacity < 1 return false;
    <<s = .{};
    TH.init(*s.mutex); TH.init(*s.available);
    s.queue = NewArray(capacity, Job_Item);
    s.workers = NewArray(worker_count, Job_Worker);
    s.initialized = true;
    for *worker, index: s.workers {
        worker.scheduler = s; worker.index = index + 1;
        if !TH.thread_init(*worker.thread, jobs_worker) { jobs_destroy(s); return false; }
        worker.thread.data = worker;
        TH.thread_start(*worker.thread);
        s.started += 1;
    }
    return true;
}

jobs_execute :: (item: Job_Item, worker: s64) {
    item.proc(item.first, item.end, item.user, worker);
    TH.lock(*item.handle.mutex);
    item.handle.remaining -= 1;
    if item.handle.remaining == 0 TH.wake_all(*item.handle.changed);
    TH.unlock(*item.handle.mutex);
}

jobs_take_locked :: (s: *Job_Scheduler) -> Job_Item {
    item := s.queue[s.head];
    s.head = (s.head + 1) % s.queue.count; s.count -= 1;
    return item;
}

jobs_help :: (s: *Job_Scheduler) -> bool {
    TH.lock(*s.mutex);
    if s.count == 0 { TH.unlock(*s.mutex); return false; }
    item := jobs_take_locked(s);
    TH.unlock(*s.mutex);
    jobs_execute(item, 0);
    return true;
}

jobs_worker :: (thread: *TH.Thread) -> s64 {
    worker := cast(*Job_Worker) thread.data;
    s := worker.scheduler;
    while true {
        TH.lock(*s.mutex);
        while s.count == 0 && !s.stopping TH.wait(*s.available, *s.mutex);
        if s.count == 0 && s.stopping { TH.unlock(*s.mutex); break; }
        item := jobs_take_locked(s);
        TH.unlock(*s.mutex);
        jobs_execute(item, worker.index);
        reset_temporary_storage();
    }
    return 0;
}

// Half-open ranges [first,end). Bounded queue; submitting/waiting threads help.
jobs_schedule_range :: (s: *Job_Scheduler, count: s64, batch: s64, proc: Job_Proc, user: *void = null) -> *Job_Handle {
    assert(s.initialized && !s.stopping && count >= 0 && batch > 0 && proc != null);
    handle := New(Job_Handle);
    TH.init(*handle.mutex); TH.init(*handle.changed);
    handle.remaining = count / batch + ifx count % batch != 0 then 1 else 0;
    first: s64;
    while first < count {
        end := first + min(batch, count - first);
        while true {
            TH.lock(*s.mutex);
            if s.count < s.queue.count {
                tail := (s.head + s.count) % s.queue.count;
                s.queue[tail] = .{proc = proc, first = first, end = end, user = user, handle = handle};
                s.count += 1;
                TH.wake(*s.available);
                TH.unlock(*s.mutex); break;
            }
            TH.unlock(*s.mutex);
            _ := jobs_help(s);
        }
        first = end;
    }
    return handle;
}
jobs_schedule :: (s: *Job_Scheduler, proc: Job_Proc, user: *void = null) -> *Job_Handle {
    return jobs_schedule_range(s, 1, 1, proc, user);
}
job_done :: (handle: *Job_Handle) -> bool {
    TH.lock(*handle.mutex); defer TH.unlock(*handle.mutex);
    return handle.remaining == 0;
}
job_complete :: (s: *Job_Scheduler, handle: *Job_Handle) {
    while !job_done(handle) {
        if jobs_help(s) continue;
        TH.lock(*handle.mutex);
        while handle.remaining > 0 TH.wait(*handle.changed, *handle.mutex);
        TH.unlock(*handle.mutex);
    }
}
job_release :: (handle: *Job_Handle) {
    if handle == null return;
    assert(job_done(handle), "Complete jobs before releasing their handle");
    TH.destroy(*handle.changed); TH.destroy(*handle.mutex); free(handle);
}
// Call after producers stop. All queued work finishes before resources free.
jobs_destroy :: (s: *Job_Scheduler) {
    if !s.initialized return;
    while jobs_help(s) {}
    TH.lock(*s.mutex); s.stopping = true; TH.wake_all(*s.available); TH.unlock(*s.mutex);
    for i: 0..s.started-1 {
        _ := TH.thread_is_done(*s.workers[i].thread, -1);
        TH.thread_deinit(*s.workers[i].thread);
    }
    free(s.workers.data); free(s.queue.data);
    TH.destroy(*s.available); TH.destroy(*s.mutex); <<s = .{};
}
