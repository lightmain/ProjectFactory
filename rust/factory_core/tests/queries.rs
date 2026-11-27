//! M03a user-visible ray acceptance; metre units and logical world data only.
use factory_core::{
    queries::cast,
    world::{Block, Bounds, Cell, World},
};
use std::collections::BTreeMap;

fn empty_world() -> World {
    World::from_deltas(Bounds::default(), false, &BTreeMap::new(), &[]).unwrap()
}

#[test]
fn ground_face_and_inclusive_distance_endpoint_match_the_current_raycast() {
    let world = World::flat(Bounds::default());
    let hit = cast(&world, [0.25, 2.0, 0.25], [0.0, -1.0, 0.0], 2.0).unwrap();
    assert_eq!(hit.cell, Cell::new(0, -1, 0));
    assert_eq!(hit.normal, Cell::new(0, 1, 0));
    assert_eq!(hit.distance, 2.0);
    assert_eq!(hit.position, [0.25, 0.0, 0.25]);
    assert_eq!(hit.adjacent_cell(), Some(Cell::new(0, 0, 0)));
    assert!(cast(&world, [0.25, 2.0, 0.25], [0.0, -1.0, 0.0], 1.9).is_none());
    assert!(cast(&world, [0.25, 2.0, 0.25], [0.0, 1.0, 0.0], 5.0).is_none());
}

#[test]
fn invalid_vectors_and_distances_are_rejected_before_traversal() {
    let world = empty_world();
    assert!(cast(&world, [0.0; 3], [0.0; 3], 5.0).is_none());
    assert!(cast(&world, [0.0; 3], [1e-8; 3], 5.0).is_none());
    for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert!(cast(&world, [invalid, 0.0, 0.0], [1.0, 0.0, 0.0], 5.0).is_none());
        assert!(cast(&world, [0.0; 3], [invalid, 0.0, 0.0], 5.0).is_none());
        assert!(cast(&world, [0.0; 3], [1.0, 0.0, 0.0], invalid).is_none());
    }
    assert!(cast(&world, [0.0; 3], [1.0, 0.0, 0.0], -1.0).is_none());
}

#[test]
fn negative_axis_boundary_and_non_unit_direction_preserve_face_and_distance() {
    let mut world = empty_world();
    world.place(Cell::new(-2, 0, 0), Block::Stone).unwrap();
    let hit = cast(&world, [0.0, 0.25, 0.25], [-4.0, 0.0, 0.0], 5.0).unwrap();
    assert_eq!(hit.cell, Cell::new(-2, 0, 0));
    assert_eq!(hit.normal, Cell::new(1, 0, 0));
    assert_eq!(hit.distance, 0.5);
}

#[test]
fn interior_origins_and_corner_ties_keep_existing_face_semantics() {
    let mut world = empty_world();
    world.place(Cell::new(0, 0, 0), Block::Stone).unwrap();
    let interior = cast(&world, [0.25; 3], [1.0, 0.0, 0.0], 1.0).unwrap();
    assert_eq!(interior.distance, 0.0);
    assert_eq!(interior.normal, Cell::new(0, 0, 0));
    let corner = cast(&world, [-0.5, -0.5, 0.25], [1.0, 1.0, 0.0], 3.0).unwrap();
    assert_eq!(corner.cell, Cell::new(0, 0, 0));
    assert_eq!(corner.normal, Cell::new(0, -1, 0));
    assert!((corner.distance - 0.5_f64.sqrt()).abs() < 1e-10);
}

#[test]
fn a_ray_tangent_to_the_exit_corner_still_visits_the_entry_cell() {
    let mut world = empty_world();
    world.place(Cell::new(-2, 1, 2), Block::Stone).unwrap();
    let hit = cast(&world, [-1.25, 1.25, 0.75], [1.0, -2.0, 3.0], 5.0).unwrap();
    assert_eq!(hit.cell, Cell::new(-2, 1, 2));
    assert_eq!(hit.normal, Cell::new(-1, 0, 0));
    // At this Y/Z exit-entry tie, Y is stepped first, so the block is skipped.
    // Godot's f32 accumulation can invert this exact tie for a 3:1 direction.
    assert!(cast(&world, [-0.25, 0.25, 1.75], [-2.0, 3.0, -1.0], 5.0).is_none());
}

#[test]
fn thin_belts_leave_air_above_the_plate() {
    let mut world = empty_world();
    world.place(Cell::new(0, 0, 0), Block::Belt).unwrap();
    assert!(cast(&world, [0.25, 0.25, -0.25], [0.0, 0.0, 1.0], 1.0).is_none());
    let top = cast(&world, [0.25, 1.0, 0.25], [0.0, -1.0, 0.0], 2.0).unwrap();
    assert!((top.position[1] - 0.08).abs() < 1e-10);
    assert_eq!(top.normal, Cell::new(0, 1, 0));
}

#[test]
fn all_eight_slope_surfaces_are_hit_in_their_absolute_direction() {
    for raw in 9..=16 {
        let mut world = empty_world();
        let block = Block::try_from(raw).unwrap();
        world.place(Cell::new(0, 0, 0), block).unwrap();
        let hit = cast(&world, [0.0625, 1.0, 0.1875], [0.0, -1.0, 0.0], 2.0).unwrap();
        assert_eq!(hit.cell, Cell::new(0, 0, 0));
        let expected = block.slope_elevation(0.125, 0.375).unwrap() * 0.5 + 0.08;
        assert!((hit.position[1] - expected).abs() < 1e-10, "slope {raw}");
        assert_eq!(hit.normal, Cell::new(0, 1, 0));
    }
}

#[test]
fn slope_air_is_skipped_but_the_upper_lip_is_queryable() {
    let mut world = empty_world();
    world.place(Cell::new(0, 0, 0), Block::BeltUpEast).unwrap();
    assert!(cast(&world, [0.4, 0.1, -0.2], [0.0, 0.0, 1.0], 1.0).is_none());
    let lip = cast(&world, [0.48, 0.55, -0.2], [0.0, 0.0, 1.0], 1.0).unwrap();
    assert_eq!(lip.cell, Cell::new(0, 0, 0));
    assert!((lip.position[1] - 0.55).abs() < 1e-10);
    world.place(Cell::new(0, 0, 2), Block::Stone).unwrap();
    let next = cast(&world, [0.4, 0.1, -0.2], [0.0, 0.0, 1.0], 2.0).unwrap();
    assert_eq!(next.cell, Cell::new(0, 0, 2));
}

#[test]
fn distant_origins_clip_to_the_finite_world_without_distance_proportional_work() {
    let mut world = empty_world();
    world.place(Cell::new(0, 0, 0), Block::Stone).unwrap();
    let hit = cast(&world, [1000.0, 0.25, 0.25], [-1.0, 0.0, 0.0], 1010.0).unwrap();
    assert_eq!(hit.cell, Cell::new(0, 0, 0));
    assert_eq!(hit.normal, Cell::new(1, 0, 0));
    assert!((hit.distance - 999.5).abs() < 1e-10);
    assert!(cast(&world, [1000.0, 0.25, 0.25], [1.0, 0.0, 0.0], 2000.0).is_none());
}

#[test]
fn an_unadvanced_world_boundary_origin_keeps_the_zero_entry_normal() {
    let mut world = empty_world();
    world.place(Cell::new(-32, 0, 0), Block::Stone).unwrap();
    let hit = cast(&world, [-16.0, 0.25, 0.25], [1.0, 0.0, 0.0], 5.0).unwrap();
    assert_eq!(hit.distance, 0.0);
    assert_eq!(hit.normal, Cell::new(0, 0, 0));
    assert_eq!(hit.adjacent_cell(), Some(Cell::new(-32, 0, 0)));
}

#[test]
fn clipping_retains_intermediate_cells_at_world_entry_corner_ties() {
    let mut world = empty_world();
    world.place(Cell::new(-32, 0, 0), Block::Stone).unwrap();
    let hit = cast(&world, [-16.5, 0.0, 0.25], [1.0, 1.0, 0.0], 5.0).unwrap();
    assert_eq!(hit.cell, Cell::new(-32, 0, 0));
    assert_eq!(hit.normal, Cell::new(-1, 0, 0));
    assert!((hit.distance - 0.5_f64.sqrt()).abs() < 1e-10);
    assert_eq!(hit.position, [-16.0, 0.5, 0.25]);
}
