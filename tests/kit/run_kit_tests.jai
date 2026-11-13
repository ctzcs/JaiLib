// kit 层回归入口：与 olib tests/kit 对位。
// 构建：jaic -import_dir "D:/MySpace/Github" -import_dir . -import_dir Tests \
//        -exe bin/kit_tests -output_path bin Tests/kit/run_kit_tests.jai
#import "Basic" ;
#import "test_support" ;
#import "kit/world/world_test" ;
#import "kit/audio/audio_test" ;
#import "kit/storage/storage_test" ;
#import "kit/app/app_test" ;
#import "kit/animation/animation_test" ;
#import "kit/asset/asset_test" ;
#import "kit/rendering/shader_test" ;
#import "kit/rendering/material_test" ;
#import "kit/rendering/twod_test" ;
#import "kit/rendering/threed_test" ;
#import "kit/gizmo/gizmo_test" ;
#import "kit/ui/ui_test" ;
#import "kit/tools/tools_test" ;
#import "thirdparty/imgui/input_test" ;

 main :: ( ) {
all_ok := true ;

 // world
st := test_begin ( ) ;
camera2d_identity_centering ( * st ) ;
camera2d_roundtrip ( * st ) ;
camera2d_dirty_tracking ( * st ) ;
camera2d_singular_rejected ( * st ) ;
scene_router_transitions ( * st ) ;
matrix4_inverse_roundtrip ( * st ) ;
matrix4_look_at_maps_eye_to_origin ( * st ) ;
matrix4_perspective_depth_range ( * st ) ;
matrix4_orthographic_boundaries_and_axis_flip ( * st ) ;
matrix4_orthographic_large_world_and_height_roundtrip ( * st ) ;
matrix4_orthographic_rejects_invalid_ranges ( * st ) ;
camera3d_frustum_culling ( * st ) ;
camera3d_screen_point_to_ray_center ( * st ) ;
ray3d_intersections ( * st ) ;
all_ok &= test_summary ( "kit/world" , * st ) ;

 // audio（olib tests/kit/audio 第一批：WAV 解码与所有权）
st = test_begin ( ) ;
sound_load_wav_preserves_format_and_releases ( * st ) ;
wav_bytes_integer_depths_and_f32_clipping ( * st ) ;
wav_chunk_bounds_padding_duplicates_and_trailing_bytes ( * st ) ;
wav_bytes_targets_preserve_duration_pitch_and_channels ( * st ) ;
wav_bytes_failures_preserve_previous_sound ( * st ) ;
wav_bytes_nonfinite_rejected_before_conversion ( * st ) ;
wav_bytes_allocator_pairing_replacement_and_failure_cleanup ( * st ) ;
wav_path_and_independent_byte_sources_match ( * st ) ;
all_ok &= test_summary ( "kit/audio" , * st ) ;

 // animation
st = test_begin ( ) ;
sample_pose_bind_and_override ( * st ) ;
sample_channel_interpolations ( * st ) ;
compute_palette_identity_when_pose_matches_bind ( * st ) ;
advance_time_loop_and_clamp ( * st ) ;
blend_poses_and_bounds ( * st ) ;
all_ok &= test_summary ( "kit/animation" , * st ) ;

 // app
st = test_begin ( ) ;
has_arg_matches_flags ( * st ) ;
cli_parse_line_splits ( * st ) ;
cli_enqueue_and_update_roundtrip ( * st ) ;
cli_lines_from_another_thread_free_cleanly_under_tracking ( * st ) ;
cli_quit_exits_foster_app ( * st ) ;
cli_zero_value_lifecycle ( * st ) ;
cli_open_without_stdin_cleans_up ( * st ) ;
cli_builtin_commands_registered ( * st ) ;
cli_history_records_executed_lines ( * st ) ;
cli_order_and_deferred_enqueue ( * st ) ;
all_ok &= test_summary ( "kit/app" , * st ) ;

 // storage
st = test_begin ( ) ;
storage_container_replace_and_failure_preserve_previous ( * st ) ;
user_root_creates_platform_dir ( * st ) ;
with_user_storage_roundtrip ( * st ) ;
resources_roots_resolve ( * st ) ;
invalid_namespace_does_not_fall_back_to_working_directory ( * st ) ;
all_ok &= test_summary ( "kit/storage" , * st ) ;

 // asset
st = test_begin ( ) ;
asset_guid_roundtrip_and_uniqueness ( * st ) ;
asset_blob_roundtrip ( * st ) ;
asset_meta_identity ( * st ) ;
asset_import_and_load ( * st ) ;
asset_importer_version_invalidates ( * st ) ;
asset_map_storage_load ( * st ) ;
asset_orphan_meta_warns ( * st ) ;
asset_manifest_packaged_load ( * st ) ;
all_ok &= test_summary ( "kit/asset" , * st ) ;

 // rendering/shader
st = test_begin ( ) ;
shader_pass_graph_orders_current_dependencies_and_owns_nested_data ( * st ) ;
shader_migrate_ids_and_pack_independent_gpu_slots ( * st ) ;
shader_changed_type_uses_defaults ( * st ) ;
shader_resource_roundtrip_isolation_and_validation ( * st ) ;
shader_sprite_sampler_uses_only_declared_parts ( * st ) ;
shader_sprite_material_contract_and_roundtrip ( * st ) ;
shader_model_passes_share_depth_target_without_relaxing_image_graph ( * st ) ;
shader_model_instance_roundtrip_groups_and_reject_partial_decode ( * st ) ;
shader_shader_validate_accepts_baseline ( * st ) ;
shader_shader_validate_rejects_bad_shader_header ( * st ) ;
shader_shader_validate_rejects_bad_pass_declarations ( * st ) ;
shader_shader_validate_rejects_bad_targets ( * st ) ;
shader_shader_validate_rejects_bad_inputs_and_values ( * st ) ;
shader_shader_sort_detects_current_frame_cycle ( * st ) ;
shader_shader_validate_limits_uniform_bytes ( * st ) ;
shader_skinned_model_validation_and_clone ( * st ) ;
shader_properties_passes_and_original_hlsl_locations ( * st ) ;
shader_invalid_declarations_fail_without_partial_document ( * st ) ;
shader_model_depth_compare_names ( * st ) ;
shader_model_render_states_and_previous_frame_graph ( * st ) ;
shader_instance_properties_and_instanced_directive ( * st ) ;
shader_generator_includes_provide_sprite_and_instance_interfaces ( * st ) ;
shader_d3d12_rules_point_at_the_offending_line ( * st ) ;
shader_explicit_skinned_model_and_illegal_combinations ( * st ) ;
shader_skinning_include_abi_and_helpers ( * st ) ;
shader_commands_preserve_both_stages_and_other_backends ( * st ) ;
shader_missing_compiler_is_an_error_without_fallback ( * st ) ;
shader_sparse_signatures_and_portable_outputs ( * st ) ;
shader_tool_identity_covers_executable_and_sibling_libraries ( * st ) ;
shader_failed_compile_has_no_success_provenance ( * st ) ;
shader_dev_sparse_pair_and_resource_reflection ( * st ) ;
shader_session_owns_compiler_path_options ( * st ) ;
shader_source_changes_include_same_length_and_deletion ( * st ) ;
shader_reject_stale_candidate_without_touching_live_state ( * st ) ;
shader_safe_creation_reports_errors_without_gpu ( * st ) ;
shader_apply_requires_graphics_device ( * st ) ;
shader_single_file_build_snapshot_and_stale_watch_result ( * st ) ;
shader_snapshot_includes_copies_standard_include ( * st ) ;
all_ok &= test_summary ( "kit/rendering/shader" , * st ) ;

 // rendering/material
st = test_begin ( ) ;
std140_writes_little_endian_and_skips_out_of_range ( * st ) ;
instance_fields_leave_uniform_layout_and_define_olib_instance ( * st ) ;
instanced_shader_rules ( * st ) ;
instance_slot_resolves_once_and_rejects_bad_names ( * st ) ;
instance_values_set_marks_slots_and_apply_overrides_only_those ( * st ) ;
instance_values_take_only_needed_components ( * st ) ;
draw_collects_instance_values_in_field_order ( * st ) ;
model_instancing_hlsl_declares_input_world_and_varyings ( * st ) ;
instance_slot_count_requires_consistent_groups ( * st ) ;
material_select_reports_why_it_refused ( * st ) ;
view_globals_padding_and_slot_counts ( * st ) ;
pass_depth_maps_every_compare ( * st ) ;
draw_error_text_covers_every_error ( * st ) ;
shader_pick_follows_driver ( * st ) ;
material_register_manifest_selects_backend_and_validates ( * st ) ;
material_register_directory_finds_compiled_files ( * st ) ;
material_register_directory_names_what_is_missing ( * st ) ;
instance_table_matches_pass_values ( * st ) ;
material_pass_selection_preserves_order_and_disabled_flags ( * st ) ;
material_library_resolves_shader_and_preserves_failed_reload ( * st ) ;
material_set_texture_binds_runtime_texture_with_field_sampler ( * st ) ;
material_texture_paths_are_relative_and_canonical ( * st ) ;
material_from_bindings_borrows_tool_bindings ( * st ) ;
builtin_shaders_register_once_with_foster_uniforms ( * st ) ;
material_create_reports_unknown_shaders ( * st ) ;
web_check_rejects_unsupported_shaders ( * st ) ;
all_ok &= test_summary ( "kit/rendering/material" , * st ) ;

 // rendering/2d
st = test_begin ( ) ;
frame_corners_preserve_trim_atlas_and_origin ( * st ) ;
grid_build_rects_cells ( * st ) ;
kenney_build_rects_parse ( * st ) ;
builtin_icons_assets_decode ( * st ) ;
atlas_subtexture_uses_local_origin ( * st ) ;
atlas_pages_pick_texture_and_keep_trim ( * st ) ;
animation_set_get_frame_at_walks ( * st ) ;
aseprite_slug_cleans_names ( * st ) ;
aseprite_expand_tag_variants ( * st ) ;
aseprite_clips_own_their_strings ( * st ) ;
sprite_item_matches_gpu_record_layout ( * st ) ;
sprite_buffer_guards_and_draw_errors ( * st ) ;
render2d_stacks_follow_batcher_semantics ( * st ) ;
render2d_record_reports_errors ( * st ) ;
render2d_runs_split_on_state_and_parameters ( * st ) ;
render2d_instance_values_preserve_each_pass ( * st ) ;
all_ok &= test_summary ( "kit/rendering/2d" , * st ) ;

 // rendering/3d
st = test_begin ( ) ;
mesh_format_strides ( * st ) ;
queue_sort_buckets_and_depth ( * st ) ;
queue_view_depth_uses_object_position ( * st ) ;
vertex_matrix_block_pack_layout ( * st ) ;
joint_palette_fills_identity_beyond_count ( * st ) ;
shader_blobs_embedded ( * st ) ;
debug_draw_geometry_counts ( * st ) ;
debug_draw_expand_builds_quads ( * st ) ;
lod_selector_thresholds_and_hysteresis ( * st ) ;
lod_screen_height_estimates ( * st ) ;
lod_world_sphere_is_conservative ( * st ) ;
render3d_views_preserve_records ( * st ) ;
instance_buffer_layout_and_guards ( * st ) ;
render3d_instances_snapshots_and_order ( * st ) ;
render3d_prepared_follows_revision ( * st ) ;
render3d_reports_errors_before_gpu ( * st ) ;
render3d_skin_palette_snapshot_and_validation ( * st ) ;
joint_palette_split_boundary_and_overflow ( * st ) ;
render3d_plan_packs_every_batch_once ( * st ) ;
render3d_debug_lines_follow_pass_selection ( * st ) ;
render3d_records_survive_material_reload ( * st ) ;
camera_position_and_material_blocks ( * st ) ;
material_blocks_follow_model_include_layout ( * st ) ;
world_bounds_affine_matches_corners ( * st ) ;
all_ok &= test_summary ( "kit/rendering/3d" , * st ) ;

 // gizmo
st = test_begin ( ) ;
translation_viewport_and_projection ( * st ) ;
translation_drag_all_axes ( * st ) ;
translation_cancel_and_reacquire ( * st ) ;
translation_camera_resize_and_invalid_pointer ( * st ) ;
rotation_world_composition ( * st ) ;
rotation_drag_wrap_and_capture ( * st ) ;
scale_local_axes_uniform_and_bounds ( * st ) ;
transform_cancel_mode_focus_resize ( * st ) ;
transform2d_move_and_projection ( * st ) ;
transform2d_rotation_and_scale ( * st ) ;
transform2d_cancel_and_input_contract ( * st ) ;
transform_mesh_world_geometry ( * st ) ;
wireframe_mesh_pixel_width_and_kinds ( * st ) ;
wireframe_edges_and_uniforms ( * st ) ;
translation_hit_thresholds ( * st ) ;
gizmo_ring_angle_and_wrap ( * st ) ;
transform_hit_rings_and_scale_center ( * st ) ;
wireframe_uniform_layout ( * st ) ;
gizmo_gpu_diagnostics ( * st ) ;
all_ok &= test_summary ( "kit/gizmo" , * st ) ;

 // ui
st = test_begin ( ) ;
visual_subtree_render_and_pointer_follow_last_display ( * st ) ;
visual_nested_text_image_clip_and_offscreen_entry ( * st ) ;
visual_tween_interrupt_and_singular_input ( * st ) ;
visual_slider_drag_uses_inverse_transform ( * st ) ;
visual_floating_ancestry_and_nested_clip_match_input ( * st ) ;
element_rect_reports_last_layout_without_visual ( * st ) ;
font_bake_ascii_atlas ( * st ) ;
font_bake_default_and_explicit_ascii_have_codepoint_kerning ( * st ) ;
font_bake_custom_charset_grows_atlas ( * st ) ;
font_bake_rejects_unusable_inputs ( * st ) ;
measure_text_advances_and_kerning ( * st ) ;
glyph_quads_advance_and_uv ( * st ) ;
layout_translate_roundtrip ( * st ) ;
button_release_capture_cancel_and_disabled ( * st ) ;
toggle_flips_only_after_confirmation ( * st ) ;
unicode_spacing_and_glyph_positions_agree ( * st ) ;
image_uv_and_trimmed_atlas_frame ( * st ) ;
nine_slice_preserves_corners_and_draws_behind_children ( * st ) ;
focus_navigation_and_modal_isolation ( * st ) ;
slider_capture_scale_and_keyboard ( * st ) ;
context_reinitialization_and_pool_diagnostics ( * st ) ;
scroll_layout_starts_at_top_and_clips_after_wheel ( * st ) ;
contexts_switch_without_stealing_layout_or_lifetime ( * st ) ;
cancel_and_disappearing_widget_release_capture ( * st ) ;
pointer_edges_legacy_and_short_click ( * st ) ;
pointer_edges_hold_release_and_cancel ( * st ) ;
pointer_edges_disabled_and_modal ( * st ) ;
pointer_edges_repress_keeps_owner ( * st ) ;
pointer_edges_drag_release_and_cancel ( * st ) ;
focus_change_scrolls_container_to_show_widget ( * st ) ;
dropdown_opens_selects_and_closes ( * st ) ;
virtual_list_declares_only_visible_rows ( * st ) ;
drag_threshold_click_and_drop ( * st ) ;
text_input_edits_utf8_and_reports_ime_area ( * st ) ;
text_input_scrolls_long_text_to_follow_caret ( * st ) ;
focus_ring_follows_theme_style ( * st ) ;
focus_ring_on_clipped_text_input_is_outside_its_own_clip ( * st ) ;
motion_follows_target_and_keeps_velocity_when_interrupted ( * st ) ;
motion_kick_springs_back_and_undeclared_state_is_dropped ( * st ) ;
presence_progress_and_exit_isolates_input ( * st ) ;
ui_translate_translates_command_fields ( * st ) ;
ui_ops_insert_splices_in_the_middle ( * st ) ;
focus_ring_insert_position_between_siblings ( * st ) ;
ui_visual_lerp_interpolates_every_field ( * st ) ;
utf8_scan_and_buffer_splicing ( * st ) ;
all_ok &= test_summary ( "kit/ui" , * st ) ;

 // tools
st = test_begin ( ) ;
color_hsv_to_rgb_sectors_and_boundaries ( * st ) ;
color_rgb_to_hsv_primaries_and_edges ( * st ) ;
color_hsv_rgb_roundtrip ( * st ) ;
color_normalize_maps_range_and_clamps ( * st ) ;
color_rgba_and_presets_stay_in_gamut ( * st ) ;
sl_is_absolute_drive_and_leading_separators ( * st ) ;
sl_relative_path_shares_prefix_and_rejects_cousins ( * st ) ;
sl_replace_first_only_touches_first_match ( * st ) ;
make_cube_counts_normals_uv_and_bounds ( * st ) ;
make_cube_faces_are_ccw_and_indices_match_vertices ( * st ) ;
make_sphere_mesh_counts_and_attributes ( * st ) ;
display_name_prefers_label_falls_back_to_id ( * st ) ;
shader_target_format_downgrades_to_8bit_color ( * st ) ;
summarize_frame_times ( * st ) ;
scopes_report_deltas ( * st ) ;
scopes_keep_slowest ( * st ) ;
status_message_covers_every_status ( * st ) ;
stored_id_roundtrip_and_validation ( * st ) ;
target_id_helpers_and_step_quantization ( * st ) ;
all_ok &= test_summary ( "kit/tools" , * st ) ;

 // thirdparty/imgui（ImGui -> jfoster 后端的输入层；移植自 olib
// tests/thirdparty/imgui/imgui_impl_ofoster/input_test.odin）。放在最后：这些用例会自己
// SDL_Init / SDL_Quit 一个隐藏窗口，不依赖也不干扰前面各组的纯逻辑测试。
// scancode -> ImGui Key 映射表
st = test_begin ( ) ;
keymap_maps_letters_digits_and_punctuation ( * st ) ;
keymap_maps_control_navigation_and_editing_keys ( * st ) ;
keymap_maps_function_keys_and_keypad ( * st ) ;
keymap_maps_modifiers_to_both_sides ( * st ) ;
keymap_leaves_unmapped_scancodes_none ( * st ) ;
keymap_table_is_scancode_indexed_and_within_bounds ( * st ) ;
all_ok &= test_summary ( "thirdparty/imgui/keymap" , * st ) ;

 // 后端接线 + 帧推进
st = test_begin ( ) ;
backend_setup_wires_platform_name_flags_and_clipboard ( * st ) ;
new_frame_mirrors_window_pixel_size_and_delta_time ( * st ) ;
all_ok &= test_summary ( "thirdparty/imgui/frame" , * st ) ;

 // 键盘事件（按下 / 保持 / 松开 / 一步内按下又松开）
st = test_begin ( ) ;
key_events_report_down_pressed_and_released ( * st ) ;
press_and_release_in_one_step_does_not_stick ( * st ) ;
all_ok &= test_summary ( "thirdparty/imgui/keyboard" , * st ) ;

 // 修饰键两侧 + Ctrl+S 快捷键构造
st = test_begin ( ) ;
modifier_events_feed_left_right_and_aggregate_flags ( * st ) ;
ctrl_plus_key_builds_a_shortcut ( * st ) ;
all_ok &= test_summary ( "thirdparty/imgui/modifiers" , * st ) ;

 // 文本输入（UTF-8 码点投递 + utf8_decode）
st = test_begin ( ) ;
text_input_becomes_utf8_codepoints ( * st ) ;
invalid_utf8_queues_no_character ( * st ) ;
utf8_decode_ascii_and_two_byte ( * st ) ;
utf8_decode_three_and_four_byte ( * st ) ;
utf8_decode_rejects_invalid_and_truncated ( * st ) ;
all_ok &= test_summary ( "thirdparty/imgui/text" , * st ) ;

 // 鼠标（按键索引换算 / 位置 / 滚轮）
st = test_begin ( ) ;
mouse_buttons_position_and_wheel_reach_imgui ( * st ) ;
all_ok &= test_summary ( "thirdparty/imgui/mouse" , * st ) ;

 // 生命周期与其它入口
st = test_begin ( ) ;
shutdown_stops_input_forwarding ( * st ) ;
register_texture_wraps_pointer ( * st ) ;
all_ok &= test_summary ( "thirdparty/imgui/lifecycle" , * st ) ;

 if ! all_ok {
print ( "[kit] FAILED\n" ) ;
exit ( 1 ) ;
}
print ( "[kit] all passed.\n" ) ;
} 

// Loop scopes adapted.
