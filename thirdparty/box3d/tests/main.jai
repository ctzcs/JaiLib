#import "Basic";
P :: #import "thirdparty/box3d";

#load "../native.jai";

#load "abi.jai";

Query_State :: struct {
    count: s32;
    target: P.b3ShapeId;
    found: bool;
}

query :: (shape: P.b3ShapeId, user: *void) -> bool #c_call {
    state := cast(*Query_State) user;
    state.count += 1;
    if P.b3StoreShapeId(shape) == P.b3StoreShapeId(state.target) state.found = true;
    return true;
}

physics :: () {
    def := P.b3DefaultWorldDef();
    def.gravity.y = -10;
    world := P.b3CreateWorld(*def);
    assert(P.b3World_IsValid(world));
    assert(P.B3_IS_NULL(P.b3_nullWorldId) && P.B3_IS_NON_NULL(world));
    assert(P.b3StoreWorldId(P.b3LoadWorldId(P.b3StoreWorldId(world))) == P.b3StoreWorldId(world));
    body_def := P.b3DefaultBodyDef();
    body_def.position.y = -0.5;
    ground := P.b3CreateBody(world, *body_def);
    shape_def := P.b3DefaultShapeDef();
    shape_def.enableContactEvents = true;
    shape_def.enableSensorEvents = true;
    ground_box := P.b3MakeBoxHull(10, 0.5, 10);
    P.b3CreateHullShape(ground, *shape_def, *ground_box.base);
    body_def.type = .b3_dynamicBody;
    body_def.position.y = 4;
    body_def.enableSleep = false;
    body := P.b3CreateBody(world, *body_def);
    sphere: P.b3Sphere = .{ radius = 0.5 };
    shape := P.b3CreateSphereShape(body, *shape_def, *sphere);
    assert(P.b3Shape_IsValid(shape));
    assert(P.B3_ID_EQUALS(shape, P.b3LoadShapeId(P.b3StoreShapeId(shape))));
    assert(P.b3Body_GetMass(body) > 0);
    assert(P.b3Body_IsValid(P.b3LoadBodyId(P.b3StoreBodyId(body))));
    touches: s32;
    for 0..239 {
        P.b3World_Step(world, 1.0 / 60.0, 4);
        events := P.b3World_GetContactEvents(world);
        touches += events.beginCount;
        if events.beginCount > 0 {
            event := events.beginEvents[0];
            assert(P.b3Shape_IsValid(event.shapeIdA) && P.b3Shape_IsValid(event.shapeIdB));
        }
    }
    position := P.b3Body_GetPosition(body);
    assert(position.y > 0.45 && position.y < 0.6, "falling body did not settle: %", position.y);
    assert(touches > 0, "no contact events");
    filter := P.b3DefaultQueryFilter();
    hit := P.b3World_CastRayClosest(world, .{ 0, 5, 0 }, .{ 0, -10, 0 }, filter);
    assert(hit.hit && P.b3StoreShapeId(hit.shapeId) == P.b3StoreShapeId(shape));
    assert(hit.fraction > 0 && hit.fraction < 1);
    filter.maskBits = 0;
    miss := P.b3World_CastRayClosest(world, .{ 0, 5, 0 }, .{ 0, -10, 0 }, filter);
    assert(!miss.hit);
    filter = P.b3DefaultQueryFilter();
    state: Query_State = .{ target = shape };
    bounds: P.b3AABB = .{ lowerBound = .{ -2, -2, -2 }, upperBound = .{ 2, 2, 2 } };
    P.b3World_OverlapAABB(world, bounds, filter, query, *state);
    assert(state.found && state.count == 2, "overlap callback failed: %", state.count);

    // A sensor overlaps the resting body, then reports exit after a teleport.
    sensor_def := P.b3DefaultShapeDef();
    sensor_def.isSensor = true;
    sensor_def.enableSensorEvents = true;
    sensor_sphere: P.b3Sphere = .{ center = .{ 0, 1, 0 }, radius = 1 };
    sensor := P.b3CreateSphereShape(ground, *sensor_def, *sensor_sphere);
    P.b3World_Step(world, 1.0 / 60.0, 4);
    entered := P.b3World_GetSensorEvents(world);
    assert(entered.beginCount > 0, "missing sensor entry");
    assert(P.b3StoreShapeId(entered.beginEvents[0].sensorShapeId) == P.b3StoreShapeId(sensor));
    P.b3Body_SetTransform(body, .{ 20, 5, 0 }, P.b3Quat_identity);
    P.b3World_Step(world, 1.0 / 60.0, 4);
    left := P.b3World_GetSensorEvents(world);
    assert(left.endCount > 0, "missing sensor exit");
    P.b3DestroyShape(sensor, true);
    assert(!P.b3Shape_IsValid(sensor));
    P.b3DestroyBody(body);
    assert(!P.b3Body_IsValid(body));
    P.b3DestroyWorld(world);
    assert(!P.b3World_IsValid(world));
}

joint_test :: () {
    def := P.b3DefaultWorldDef();
    def.gravity.y = -10;
    world := P.b3CreateWorld(*def);
    defer P.b3DestroyWorld(world);
    body_def := P.b3DefaultBodyDef();
    anchor := P.b3CreateBody(world, *body_def);
    body_def.type = .b3_dynamicBody;
    body_def.position.y = -2;
    body := P.b3CreateBody(world, *body_def);
    shape_def := P.b3DefaultShapeDef();
    sphere: P.b3Sphere = .{ radius = 0.5 };
    shape := P.b3CreateSphereShape(body, *shape_def, *sphere);
    joint_def := P.b3DefaultDistanceJointDef();
    joint_def.base.bodyIdA = anchor;
    joint_def.base.bodyIdB = body;
    joint_def.length = 2;
    joint := P.b3CreateDistanceJoint(world, *joint_def);
    assert(P.b3Joint_IsValid(joint));
    P.b3Body_SetLinearVelocity(body, .{ 3, 0, 0 });
    for 0..179 P.b3World_Step(world, 1.0 / 60.0, 4);
    length := P.b3DistanceJoint_GetCurrentLength(joint);
    assert(length > 1.95 && length < 2.05, "distance joint drift: %", length);
    P.b3DestroyJoint(joint, true);
    assert(!P.b3Joint_IsValid(joint));
}

main :: () {
    check_abi();
    check_symbols();
    version := P.b3GetVersion();
    assert(version.major == 0 && version.minor == 1 && version.revision == 0);
    assert(!P.b3IsDoublePrecision());
    baseline := P.b3GetByteCount();
    for 0..2 {
        physics();
        joint_test();
    }
    assert(P.b3GetByteCount() == baseline, "native allocations leaked");
    print("box3d: 0.1.0, 889 C ABI checks, 699 symbols; collision, queries/callbacks, sensors, joints, IDs and allocation lifecycle passed\n");
}
