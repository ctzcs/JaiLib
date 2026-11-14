// core 层回归入口：与 olib tests/core 对位，按模块逐个跑。
// 构建：jaic -import_dir . -import_dir Tests -exe core_tests -output_path bin Tests/core/run_core_tests.jai
#import "Basic";
#import "test_support";
#import "core/coroutine/coroutine_test";
#import "core/curve/curve_test";
#import "core/tween/tween_test";
#import "core/profiler/profiler_test";
#import "core/messaging/messaging_test";
#import "core/entities/entities_test";
#import "core/encoding/encoding_test";
#import "core/debug/debug_test";
#import "core/dasset/dasset_test";
#import "core/devbuild/devbuild_test";
#import "core/geometry/geometry_test";
#import "core/handle/handle_test";
#import "core/hotreload/hotreload_test";
#import "core/localization/localization_test";
#import "core/meshutil/meshutil_test";

main :: () {
    all_ok := true;

    // coroutine
    st := test_begin();
    flow_wait_and_once_run_in_order(*st);
    flow_wait_carries_surplus_time(*st);
    flow_large_dt_passes_several_checkpoints(*st);
    flow_nested_child_runs_after_parent_wait(*st);
    flow_until_resets_timer(*st);
    flow_progress_handles_zero_seconds_and_past_steps(*st);
    flow_copy_resumes_from_same_point(*st);
    cursor_runs_instant_steps_in_one_call(*st);
    cursor_finishes_and_stays_done(*st);
    cursor_enter_resets_timer(*st);
    cursor_progress_clamps(*st);
    all_ok &= test_summary("core/coroutine", *st);

    // curve
    st = test_begin();
    sample_endpoints_and_midpoints(*st);
    hermite_tangents_and_cardinal(*st);
    vector_sampling_and_constant_invariance(*st);
    all_ok &= test_summary("core/curve", *st);

    // dasset
    st = test_begin();
    dasset_roundtrip_full_model(*st);
    dasset_rejects_bad_input(*st);
    dasset_rejects_corrupt_counts(*st);
    dasset_binary_layout_and_byte_roundtrip(*st);
    dasset_reads_legacy_versions(*st);
    all_ok &= test_summary("core/dasset", *st);

    // devbuild
    st = test_begin();
    source_declarations_ignore_comments_and_literals(*st);
    resource_paths_and_imports_keep_production_baseline(*st);
    unknown_paths_and_unmapped_imports_are_rejected(*st);
    workspace_is_exclusive_private_and_never_writes_back(*st);
    broken_test_source_is_reported_in_discovery(*st);
    all_ok &= test_summary("core/devbuild", *st);

    // debug
    st = test_begin();
    tracking_allocator_records_and_reports(*st);
    debug_default_backing_wrapper(*st);
    tracking_allocator_init_and_helper(*st);
    all_ok &= test_summary("core/debug", *st);

    // encoding
    st = test_begin();
    order_edit_clone_roundtrip(*st);
    strict_tokens_unicode_and_tail(*st);
    comments_are_not_json5(*st);
    container_depth_boundary(*st);
    exact_integer_limits(*st);
    failed_candidates_release_every_allocation(*st);
    mutation_failure_preserves_old_tree(*st);
    csv_manager_loads_tables_and_structs(*st);
    json_value_tree_round_trip(*st);
    json_struct_round_trip(*st);
    xml_parse_and_serialize(*st);
    all_ok &= test_summary("core/encoding", *st);

    // entities
    st = test_begin();
    entities_basic(*st);
    entities_iter_val(*st);
    entities_iter_sub(*st);
    entities_generation_aba(*st);
    entities_capacity_limits(*st);
    entities_clear_invalidation(*st);
    entities_clone(*st);
    entities_get_sub_rejects_invalid_handles(*st);
    entities_clear_free_list_reuse(*st);
    entities_generation_exhaustion(*st);
    entities_reserve_atomic(*st);
    entities_init_validation_and_capacity(*st);
    all_ok &= test_summary("core/entities", *st);

    // messaging
    st = test_begin();
    command_queue_drain_semantics(*st);
    command_queue_clear(*st);
    broadcast_channel_frame_semantics(*st);
    command_queue_dispose_releases_buffer(*st);
    broadcast_channel_clear_and_dispose(*st);
    all_ok &= test_summary("core/messaging", *st);

    // profiler
    st = test_begin();
    profile_scope_accumulates(*st);
    profile_scope_end_records_elapsed(*st);
    profile_guard_carries_name_and_start(*st);
    profile_dump_prints_stats(*st);
    all_ok &= test_summary("core/profiler", *st);

    // tween
    st = test_begin();
    approach_is_frame_rate_independent(*st);
    smooth_damp_settles_without_overshoot(*st);
    spring_settles_and_bounce_controls_overshoot(*st);
    manager_reset_keeps_previous_handles_invalid(*st);
    tween_value_sampling_extension(*st);
    manager_lifecycle_extension(*st);
    sequence_timeline_extension(*st);
    all_ok &= test_summary("core/tween", *st);

    // geometry
    st = test_begin();
    closest_features_and_degenerates(*st);
    signed_distances_and_gradients(*st);
    bounds_and_touching_overlap(*st);
    sweep_ranges_parallel_and_initial_overlap(*st);
    cylinder_and_capsule_endcaps(*st);
    sphere_faces_edges_and_vertices(*st);
    sweeps_agree_with_static_distance(*st);
    all_ok &= test_summary("core/geometry", *st);

    // handle
    st = test_begin();
    soa_zero_handle_is_invalid_and_add_assigns_row(*st);
    soa_remove_clears_row_and_stale_handle_stays_invalid(*st);
    soa_iteration_skips_free_slots_and_columns_round_trip(*st);
    soa_remove_current_element_during_iteration(*st);
    soa_clear_does_not_allocate_and_invalidates_handles(*st);
    soa_reset_and_delete_with_destroy_visit_live_rows_once(*st);
    soa_snapshot_json_round_trip_preserves_generations_and_reuse_order(*st);
    soa_restore_rejects_inconsistent_snapshot_and_keeps_pool(*st);
    soa_restore_into_non_empty_pool_does_not_leak(*st);
    soa_remove_after_restore_does_not_allocate(*st);
    array_clear_preserves_generations_and_reuses_all_slots(*st);
    array_clear_destroys_only_live_values_once(*st);
    array_iterator_skips_free_slots_and_returns_live_values(*st);
    array_allocation_failure_leaves_pool_usable(*st);
    fixed_pool_lifecycle_and_iteration(*st);
    fixed_callbacks_clear_and_delete_preserve_lifecycle(*st);
    growing_pool_lifecycle_and_iteration(*st);
    growing_callbacks_clear_and_delete_preserve_lifecycle(*st);
    growing_allocation_failure_leaves_pool_usable(*st);
    virtual_pool_lifecycle_and_iteration(*st);
    virtual_callbacks_clear_and_delete_preserve_lifecycle(*st);
    virtual_allocation_failure_leaves_pool_usable(*st);
    all_ok &= test_summary("core/handle", *st);

    // hotreload
    st = test_begin();
    source_changes_and_disposal(*st);
    session_rejects_missing_module_without_becoming_live(*st);
    hot_builds_command_and_validates_config(*st);
    hot_mode_selects_scan_and_manual_trigger(*st);
    pre_command_runs_before_build_and_converges(*st);
    simple_api_hands_state_over_and_drops_only_at_exit(*st);
    simple_api_keeps_ownership_when_candidate_is_rejected(*st);
    simple_api_works_with_only_required_hooks(*st);
    simple_store_keeps_one_table_per_combination(*st);
    all_ok &= test_summary("core/hotreload", *st);

    // localization
    st = test_begin();
    table_replace_fallback_and_borrow(*st);
    format_placeholders_and_braces(*st);
    float_rounding_ties_even_and_negative_zero(*st);
    format_errors_are_not_partial_results(*st);
    formatted_result_outlives_table(*st);
    allocation_failure_keeps_table_and_releases_format(*st);
    all_ok &= test_summary("core/localization", *st);

    // meshutil
    st = test_begin();
    stats_cube_seams(*st);
    edges_plane_border(*st);
    edges_non_manifold(*st);
    weld_and_compact(*st);
    remove_degenerate_triangles(*st);
    simplify_flat_plane_keeps_corners(*st);
    simplify_sphere_keeps_seam_closed(*st);
    primitive_positions_bridge(*st);
    all_ok &= test_summary("core/meshutil", *st);

    if !all_ok {
        print("[core] FAILED\n");
        exit(1);
    }
    print("[core] all passed.\n");
}

// Loop scopes adapted.
