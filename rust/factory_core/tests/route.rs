//! M03b route geometry acceptance inherited from OrthogonalRoute.
use factory_core::{
    route::{Error, MAX_ROUTE_CELLS, fit_heights, footprint},
    world::Cell,
};

#[test]
fn axis_orders_cover_every_quadrant_without_changing_height() {
    for x in [-2, 2] {
        for z in [-3, 3] {
            for north_first in [true, false] {
                let start = Cell::new(-5, 7, -6);
                let end = Cell::new(start.x + x, 17, start.z + z);
                let path = footprint(start, end, north_first, 6).unwrap();
                assert_eq!(path.len(), 6);
                assert_eq!(path[0], start);
                assert_eq!(path[5], Cell::new(end.x, 7, end.z));
                let corner = if north_first {
                    z.unsigned_abs()
                } else {
                    x.unsigned_abs()
                } as usize;
                assert_eq!(
                    path[corner],
                    if north_first {
                        Cell::new(start.x, 7, end.z)
                    } else {
                        Cell::new(end.x, 7, start.z)
                    }
                );
                for pair in path.windows(2) {
                    assert_eq!(
                        (pair[1].x - pair[0].x).abs() + (pair[1].z - pair[0].z).abs(),
                        1
                    );
                }
            }
        }
    }
}

#[test]
fn a_single_column_ignores_target_height_and_long_straights_are_preserved() {
    assert_eq!(
        footprint(Cell::new(0, 0, 0), Cell::new(0, 9, 0), true, 1).unwrap(),
        [Cell::new(0, 0, 0)]
    );
    let route = footprint(Cell::new(0, 0, 0), Cell::new(1000, 0, 0), true, 1001).unwrap();
    assert_eq!(route.len(), 1001);
    assert_eq!(route[1000], Cell::new(1000, 0, 0));
}

#[test]
fn length_limits_fail_before_route_allocation() {
    let start = Cell::new(0, 0, 0);
    let end = Cell::new(MAX_ROUTE_CELLS as i32, 0, 0);
    assert_eq!(
        footprint(start, end, true, MAX_ROUTE_CELLS),
        Err(Error::TooLong)
    );
    assert_eq!(footprint(start, start, true, 0), Err(Error::InvalidLimit));
    assert_eq!(
        footprint(start, start, true, MAX_ROUTE_CELLS + 1),
        Err(Error::InvalidLimit)
    );
    assert_eq!(
        footprint(Cell::new(0, 0, 0), Cell::new(1000, 0, 0), true, 1000),
        Err(Error::TooLong)
    );
}

#[test]
fn lowest_ground_and_obstacle_routes_keep_the_current_heights() {
    assert_eq!(
        fit_heights(&[0, 0, 0, 0], &[1, 1, 1], 0, 0).unwrap(),
        [0, 0, 0, 0]
    );
    assert_eq!(
        fit_heights(&[0, 1, 0, 0], &[1, 1, 1], 0, 0).unwrap(),
        [0, 1, 1, 0]
    );
}

#[test]
fn corners_move_ramps_to_straights_and_use_all_available_capacity() {
    assert_eq!(
        fit_heights(&[0, 0, 2, 0, 0, 0], &[1, 1, 0, 1, 1], 0, 0).unwrap(),
        [0, 1, 2, 2, 1, 0]
    );
    assert_eq!(
        fit_heights(&[0, 0, 0, 3], &[1, 1, 1], 0, 3).unwrap(),
        [0, 1, 2, 3]
    );
    assert_eq!(
        fit_heights(&[0, 0, 0, 0], &[1, 1, 1], 3, 0).unwrap(),
        [3, 2, 1, 0]
    );
}

#[test]
fn impossible_endpoints_and_fixed_start_return_no_route() {
    assert_eq!(
        fit_heights(&[0, 0, 3, 0, 0, 0], &[1, 1, 0, 1, 1], 0, 0),
        Err(Error::NoRoute)
    );
    assert_eq!(
        fit_heights(&[0, 0, 0, 4], &[1, 1, 1], 0, 4),
        Err(Error::NoRoute)
    );
    assert_eq!(
        fit_heights(&[0, 1, 0, 0], &[0, 1, 1], 0, 0),
        Err(Error::NoRoute)
    );
    assert_eq!(fit_heights(&[0], &[], 0, 1), Err(Error::NoRoute));
}

#[test]
fn invalid_height_arrays_are_rejected() {
    for (floors, capacities) in [
        (vec![], vec![]),
        (vec![0, 0], vec![]),
        (vec![0, 0], vec![2]),
    ] {
        assert_eq!(
            fit_heights(&floors, &capacities, 0, 0),
            Err(Error::InvalidHeights)
        );
    }
    let floors = vec![0; MAX_ROUTE_CELLS + 1];
    assert_eq!(fit_heights(&floors, &[], 0, 0), Err(Error::TooLong));
}
