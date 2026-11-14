#import "Basic";
P :: #import "thirdparty/box2d";

#load "../native.jai";

#load "abi.jai";

Query_State :: struct {
    count: s32;
    target: P.b2ShapeId;
    found: bool;
}

query :: (shape: P.b2ShapeId, user: *void) -> bool #c_call {
    state := cast(*Query_State) user;
    state.count += 1;
    if P.b2StoreShapeId(shape) == P.b2StoreShapeId(state.target) state.found = true;
    return true;
}

physics :: () {
    def := P.b2DefaultWorldDef();
    def.gravity.y = -10;
    world := P.b2CreateWorld(*def);
    assert(P.b2World_IsValid(world));
    assert(P.B2_IS_NULL(P.b2_nullWorldId) && P.B2_IS_NON_NULL(world));
    assert(P.b2StoreWorldId(P.b2LoadWorldId(P.b2StoreWorldId(world))) == P.b2StoreWorldId(world));
    body_def := P.b2DefaultBodyDef();
    body_def.position.y = -0.5;
    ground := P.b2CreateBody(world, *body_def);
    shape_def := P.b2DefaultShapeDef();
    shape_def.enableContactEvents = true;
    shape_def.enableSensorEvents = true;
    ground_box := P.b2MakeBox(10, 0.5);
    P.b2CreatePolygonShape(ground, *shape_def, *ground_box);
    body_def.type = .b2_dynamicBody;
    body_def.position.y = 4;
    body_def.enableSleep = false;
    body := P.b2CreateBody(world, *body_def);
    circle: P.b2Circle = .{ radius = 0.5 };
    shape := P.b2CreateCircleShape(body, *shape_def, *circle);
    assert(P.b2Shape_IsValid(shape));
    assert(P.B2_ID_EQUALS(shape, P.b2LoadShapeId(P.b2StoreShapeId(shape))));
    assert(P.b2Body_GetMass(body) > 0);
    assert(P.b2Body_IsValid(P.b2LoadBodyId(P.b2StoreBodyId(body))));
    touches: s32;
    for 0..239 {
        P.b2World_Step(world, 1.0 / 60.0, 4);
        events := P.b2World_GetContactEvents(world);
        touches += events.beginCount;
        if events.beginCount > 0 {
            event := events.beginEvents[0];
            assert(P.b2Shape_IsValid(event.shapeIdA) && P.b2Shape_IsValid(event.shapeIdB));
        }
    }
    position := P.b2Body_GetPosition(body);
    assert(position.y > 0.45 && position.y < 0.6, "falling body did not settle: %", position.y);
    assert(touches > 0, "no contact events");
    filter := P.b2DefaultQueryFilter();
    hit := P.b2World_CastRayClosest(world, .{ 0, 5 }, .{ 0, -10 }, filter);
    assert(hit.hit && P.b2StoreShapeId(hit.shapeId) == P.b2StoreShapeId(shape));
    assert(hit.fraction > 0 && hit.fraction < 1);
    filter.maskBits = 0;
    miss := P.b2World_CastRayClosest(world, .{ 0, 5 }, .{ 0, -10 }, filter);
    assert(!miss.hit);
    filter = P.b2DefaultQueryFilter();
    state: Query_State = .{ target = shape };
    bounds: P.b2AABB = .{ lowerBound = .{ -2, -2 }, upperBound = .{ 2, 2 } };
    P.b2World_OverlapAABB(world, bounds, filter, query, *state);
    assert(state.found && state.count == 2, "overlap callback failed: %", state.count);

    // A sensor overlaps the resting body, then reports exit after a teleport.
    sensor_def := P.b2DefaultShapeDef();
    sensor_def.isSensor = true;
    sensor_def.enableSensorEvents = true;
    // Keep centers separated: upstream 3.1.1 skips radius adjustment below 0.1 * linear slop.
    sensor_circle: P.b2Circle = .{ center = .{ 0, 1.25 }, radius = 1 };
    sensor := P.b2CreateCircleShape(ground, *sensor_def, *sensor_circle);
    assert(P.b2Shape_IsSensor(sensor));
    assert(P.b2Shape_AreSensorEventsEnabled(sensor) && P.b2Shape_AreSensorEventsEnabled(shape));
    P.b2World_Step(world, 1.0 / 60.0, 4);
    entered := P.b2World_GetSensorEvents(world);
    assert(entered.beginCount > 0, "missing sensor entry");
    assert(P.b2StoreShapeId(entered.beginEvents[0].sensorShapeId) == P.b2StoreShapeId(sensor));
    P.b2Body_SetTransform(body, .{ 20, 5 }, P.b2Rot_identity);
    P.b2World_Step(world, 1.0 / 60.0, 4);
    left := P.b2World_GetSensorEvents(world);
    assert(left.endCount > 0, "missing sensor exit");
    P.b2DestroyShape(sensor, true);
    assert(!P.b2Shape_IsValid(sensor));
    P.b2DestroyBody(body);
    assert(!P.b2Body_IsValid(body));
    P.b2DestroyWorld(world);
    assert(!P.b2World_IsValid(world));
}

joint_test :: () {
    def := P.b2DefaultWorldDef();
    def.gravity.y = -10;
    world := P.b2CreateWorld(*def);
    defer P.b2DestroyWorld(world);
    body_def := P.b2DefaultBodyDef();
    anchor := P.b2CreateBody(world, *body_def);
    body_def.type = .b2_dynamicBody;
    body_def.position.y = -2;
    body := P.b2CreateBody(world, *body_def);
    shape_def := P.b2DefaultShapeDef();
    circle: P.b2Circle = .{ radius = 0.5 };
    shape := P.b2CreateCircleShape(body, *shape_def, *circle);
    joint_def := P.b2DefaultDistanceJointDef();
    joint_def.bodyIdA = anchor;
    joint_def.bodyIdB = body;
    joint_def.length = 2;
    joint := P.b2CreateDistanceJoint(world, *joint_def);
    assert(P.b2Joint_IsValid(joint));
    P.b2Body_SetLinearVelocity(body, .{ 3, 0 });
    for 0..179 P.b2World_Step(world, 1.0 / 60.0, 4);
    length := P.b2DistanceJoint_GetCurrentLength(joint);
    assert(length > 1.95 && length < 2.05, "distance joint drift: %", length);
    P.b2DestroyJoint(joint);
    assert(!P.b2Joint_IsValid(joint));
}

main :: () {
    check_abi();
    check_symbols();
    version := P.b2GetVersion();
    assert(version.major == 3 && version.minor == 1 && version.revision == 1);
    baseline := P.b2GetByteCount();
    for 0..2 {
        physics();
        joint_test();
    }
    assert(P.b2GetByteCount() == baseline, "native allocations leaked");
    print("box2d: 3.1.1, 570 C ABI checks, 494 symbols; collision, queries/callbacks, sensors, joints, IDs and allocation lifecycle passed\n");
}
