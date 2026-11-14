#import "Basic";

// Minimal test harness for tlib, mirroring Odin's core:testing.expect.
// Convention:
//   - each module gets a *_test.jai file declaring test procedures that take a *Test_State
//   - run_tests.jai imports them, runs each test, and prints a summary
//   - test names match the Odin test case names they were ported from

Test_State :: struct {
    passed: int;
    failed: int;
}

test_begin :: () -> Test_State {
    return .{ passed = 0, failed = 0 };
}

expect :: (state: *Test_State, condition: bool, msg: string, args: ..Any) {
    if condition {
        state.passed += 1;
    } else {
        state.failed += 1;
        print("  [FAIL] %\n", sprint(msg, args));
    }
}

// Prints a per-module summary and returns whether it passed.
test_summary :: (name: string, state: *Test_State) -> bool {
    print("[%] % passed, % failed\n", name, state.passed, state.failed);
    return state.failed == 0;
}

// Iterator semantics adapted.

// Loop scopes adapted.
