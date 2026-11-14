#load "driver.jai";
#load "protocol.jai";
#load "security.jai";
#load "transport.jai";
#load "types.jai";
#scope_module
#import "Basic";
#import "Atomics";
Math :: #import "Math";
net :: #import "thirdparty/onet/transport/net";
Crypto :: #import "thirdparty/onet/transport/crypto";
Hmac :: #import "thirdparty/onet/transport/crypto";
#load "../../support.jai";

set_v6_only :: net.set_v6_only;
kernel_connect :: net.kernel_connect;

zero_secret :: (secret: *[32] u8) {
    for *byte: secret.* atomic_write(byte, (cast, trunc(u8) 0));
}

hash_ip :: (key: IP_Key) -> u32 #no_aoc {
    h: u32 = 2166136261;
    for b: key h = (h ^ b) * 16777619;
    return h;
}

equal_ip :: (a: IP_Key, b: IP_Key) -> bool {
    for x, i: a if x != b[i] return false;
    return true;
}

// Loop scopes adapted.
// Cast semantics adapted.
