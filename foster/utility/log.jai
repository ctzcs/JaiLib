#scope_module
using Basic;   // module-private
using Math;
#scope_export

// Port of Foster Framework/Utility/Log.cs.
// log_info / log_warning / log_error append to a shared history buffer and
// forward to an optional callback (or print to stdout by default).

Log_Fn :: #type (text: string);

log_on_info:  Log_Fn = null;
log_on_warn:  Log_Fn = null;
log_on_error: Log_Fn = null;

log_builder: String_Builder;

// Sets optional custom logging callbacks. They are not guaranteed to run on the main thread.
log_set_callbacks :: (on_info: Log_Fn, on_warn: Log_Fn, on_error: Log_Fn) {
    log_on_info  = on_info;
    log_on_warn  = on_warn;
    log_on_error = on_error;
}

log_info :: (message: string) {
    log_append(message);
    if log_on_info != null log_on_info(message);
    else print("%\n", message);
}

log_warning :: (message: string) {
    log_append(message);
    if log_on_warn != null log_on_warn(message);
    else print("%\n", message);
}

log_error :: (message: string) {
    log_append(message);
    if log_on_error != null log_on_error(message);
    else print("%\n", message);
}

// Log a null-terminated UTF-8 C string (e.g. from SDL callbacks).
log_info_cstr :: (cstr: *u8)    { log_info(cstr_to_string(cstr)); }
log_warning_cstr :: (cstr: *u8) { log_warning(cstr_to_string(cstr)); }
log_error_cstr :: (cstr: *u8)   { log_error(cstr_to_string(cstr)); }

// Returns an owned copy without clearing the history (Foster: Log.GetHistory).
log_get_history :: () -> string {
    return builder_to_string(*log_builder, do_reset = false);
}

// Returns the accumulated log history and clears it.
log_take_history :: () -> string {
    result := builder_to_string(*log_builder);
    reset(*log_builder);
    return result;
}

log_append :: (message: string) {
    append(*log_builder, message);
    append(*log_builder, "\n");
}

// Converts a null-terminated C string to a Jai string (no copy).
cstr_to_string :: (c: *u8) -> string {
    len := 0;
    while c[len] != 0 len += 1;
    return .{ data = c, count = len };
}

// Allocates a null-terminated copy of `s` with the context allocator.
// SDL copies such strings immediately, so free() after the call.
to_cstr :: (s: string) -> *u8 {
    buf := cast(*u8) alloc(s.count + 1);
    if s.count > 0 memcpy(buf, s.data, s.count);
    buf[s.count] = 0;
    return buf;
}
