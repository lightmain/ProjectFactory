mod support;
use factory_core::{
    belt_placement::Direction,
    factory::Ruleset,
    logistics::Settings,
    runtime::{
        Command, Error, Input, Limits, Outcome, Runtime,
        queries::{Query, QueryKind, QueryPayload, RouteRequest, RouteTarget},
    },
    world::{Block, Bounds, Cell},
};
use support::{page, retry, run, stop};

fn runtime(ruleset: Ruleset, limits: Limits) -> Runtime {
    Runtime::open(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
        ruleset,
        1,
        limits,
    )
    .unwrap()
}
fn payload(
    r: &Runtime,
    request: u64,
    id: u64,
    bytes: usize,
) -> Result<factory_core::runtime::queries::QueryPage, Error> {
    retry(|| r.poll_query(1, request, id, bytes))
}
fn ray(id: u64) -> Command {
    Command::Query(Query {
        query_id: id,
        view_generation: 7,
        kind: QueryKind::Ray {
            origin: [0.25, 2.0, 0.25],
            direction: [0.0, -1.0, 0.0],
            distance: 4.0,
        },
    })
}
fn route() -> RouteRequest {
    RouteRequest {
        start: Cell::new(1, 0, 0),
        direction: Direction::East,
        max_cells: 32,
        targets: vec![RouteTarget {
            cell: Cell::new(4, 0, 0),
            north_south_first: true,
        }],
    }
}
fn query_route(id: u64, route: RouteRequest) -> Command {
    Command::Query(Query {
        query_id: id,
        view_generation: 2,
        kind: QueryKind::Route(route),
    })
}

#[test]
fn ray_payload_survives_completion_and_edits_until_replaced_by_a_new_query() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = runtime(ruleset, Limits::default());
        run(
            &r,
            1,
            1,
            Command::Build(vec![(Cell::new(0, 0, 0), Block::Belt, Direction::East)]),
        );
        run(&r, 1, 2, ray(11));
        let query = payload(&r, 2, 11, 160).unwrap();
        assert_eq!(
            (
                query.world_epoch,
                query.request_id,
                query.query_id,
                query.view_generation,
                query.tick,
                query.revision
            ),
            (1, 2, 11, 7, 0, 1)
        );
        let QueryPayload::Ray(Some(hit)) = &query.payload else {
            panic!("{query:?}")
        };
        assert_eq!(hit.hit.cell, Cell::new(0, 0, 0));
        assert_eq!(hit.block, Block::Belt);
        assert_eq!(hit.direction, Some(Direction::East));
        assert!((hit.hit.position[1] - 0.08).abs() < 1e-9);
        assert_eq!(payload(&r, 2, 12, 160), Err(Error::InvalidArgument));
        assert_eq!(payload(&r, 2, 11, 159), Err(Error::InvalidArgument));
        assert_eq!(r.poll_query(2, 2, 11, 160), Err(Error::StaleEpoch));
        run(&r, 1, 3, Command::Remove(Cell::new(0, 0, 0)));
        assert_eq!(payload(&r, 2, 11, 160).unwrap(), query);
        run(&r, 1, 4, ray(12));
        assert_eq!(payload(&r, 2, 11, 160), Err(Error::InvalidArgument));
        let QueryPayload::Ray(Some(hit)) = payload(&r, 4, 12, 160).unwrap().payload else {
            panic!()
        };
        assert_eq!(hit.hit.cell.y, -1);
        assert_eq!(page(&r, 0).timing.clock.time, 0.0);
        r.close();
        assert_eq!(r.poll_query(1, 4, 12, 160), Err(Error::Closed));
        stop(&r);
    }
}

#[test]
fn query_budget_and_route_length_are_validated_before_acceptance() {
    let r = runtime(
        Ruleset::LegacyDiscreteV1,
        Limits {
            query_bytes: 159,
            ..Limits::default()
        },
    );
    assert_eq!(
        retry(|| r.submit(
            1,
            &Input {
                request_id: 1,
                command: ray(1)
            }
        )),
        Err(Error::InvalidArgument)
    );
    assert_eq!(page(&r, 0).timing.revision, 0);
    let mut bad = route();
    bad.max_cells = 257;
    assert_eq!(
        retry(|| r.submit(
            1,
            &Input {
                request_id: 1,
                command: query_route(1, bad.clone())
            }
        )),
        Err(Error::InvalidArgument)
    );
    stop(&r);
}

#[test]
fn route_preview_is_read_only_and_commit_rechecks_late_obstacles_atomically() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = runtime(ruleset, Limits::default());
        run(&r, 1, 1, query_route(9, route()));
        assert_eq!(
            run(&r, 1, 2, Command::Cell(Cell::new(2, 0, 0))).outcome,
            Outcome::Cell(Block::Air)
        );
        let QueryPayload::Preview(segments) = payload(&r, 1, 9, 8192).unwrap().payload else {
            panic!()
        };
        assert_eq!(segments.len(), 4);
        assert!(
            segments
                .iter()
                .all(|s| s.cell.y == 0 && s.direction == Direction::East)
        );
        run(
            &r,
            1,
            3,
            Command::Build(
                (0..3)
                    .map(|y| (Cell::new(3, y, 0), Block::Stone, Direction::West))
                    .collect(),
            ),
        );
        assert!(matches!(
            run(&r, 1, 4, Command::BuildRoute(route())).outcome,
            Outcome::Rejected(_)
        ));
        let cell = run(&r, 1, 5, Command::Cell(Cell::new(1, 0, 0)));
        assert_eq!(cell.outcome, Outcome::Cell(Block::Air));
        assert_eq!(cell.revision, 1);
        for y in 0..3 {
            run(&r, 1, y as u64 + 6, Command::Remove(Cell::new(3, y, 0)));
        }
        assert_eq!(
            run(&r, 1, 9, Command::BuildRoute(route())).outcome,
            Outcome::Committed
        );
        assert_eq!(
            run(&r, 1, 10, Command::Cell(Cell::new(4, 0, 0))).outcome,
            Outcome::Cell(Block::Belt)
        );
        stop(&r);
    }
}

#[test]
fn late_low_obstacle_is_replanned_as_slopes_instead_of_reusing_flat_preview() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = runtime(ruleset, Limits::default());
        run(&r, 1, 1, query_route(1, route()));
        let QueryPayload::Preview(preview) = payload(&r, 1, 1, 8192).unwrap().payload else {
            panic!()
        };
        assert!(preview.iter().all(|row| row.block == Block::Belt));
        run(
            &r,
            1,
            2,
            Command::Build(vec![(Cell::new(3, 0, 0), Block::Chest, Direction::West)]),
        );
        assert_eq!(
            run(&r, 1, 3, Command::BuildRoute(route())).outcome,
            Outcome::Committed
        );
        assert_eq!(
            run(&r, 1, 4, Command::Cell(Cell::new(3, 0, 0))).outcome,
            Outcome::Cell(Block::Chest)
        );
        assert!(
            matches!(run(&r, 1, 5, Command::Cell(Cell::new(3, 1, 0))).outcome,
            Outcome::Cell(block) if block.is_belt())
        );
        stop(&r);
    }
}

#[test]
fn route_reconstructs_locked_turns_and_checks_complete_length_before_publication() {
    let r = runtime(Ruleset::LegacyDiscreteV1, Limits::default());
    let route = RouteRequest {
        start: Cell::new(1, 0, 0),
        direction: Direction::East,
        max_cells: 32,
        targets: vec![
            RouteTarget {
                cell: Cell::new(3, 0, 2),
                north_south_first: false,
            },
            RouteTarget {
                cell: Cell::new(5, 0, 3),
                north_south_first: true,
            },
        ],
    };
    run(&r, 1, 1, query_route(1, route.clone()));
    let QueryPayload::Preview(rows) = payload(&r, 1, 1, 8192).unwrap().payload else {
        panic!()
    };
    assert_eq!(
        rows.iter().map(|r| r.cell).collect::<Vec<_>>(),
        [
            (1, 0, 0),
            (2, 0, 0),
            (3, 0, 0),
            (3, 0, 1),
            (3, 0, 2),
            (3, 0, 3),
            (4, 0, 3),
            (5, 0, 3)
        ]
        .map(|(x, y, z)| Cell::new(x, y, z))
    );
    let mut short = route;
    short.max_cells = 7;
    let result = run(&r, 1, 2, query_route(2, short));
    assert!(matches!(result.outcome, Outcome::QueryFailed { .. }));
    assert_eq!(result.revision, 0);
    stop(&r);
}

#[test]
fn build_preview_failure_never_places_partial_blocks_and_next_query_can_replace_it() {
    let r = runtime(Ruleset::LegacyDiscreteV1, Limits::default());
    let query = Query {
        query_id: 3,
        view_generation: 4,
        kind: QueryKind::Build(vec![
            (Cell::new(0, 0, 0), Block::Belt, Direction::East),
            (Cell::new(0, -1, 0), Block::Chest, Direction::East),
        ]),
    };
    assert!(matches!(
        run(&r, 1, 1, Command::Query(query)).outcome,
        Outcome::QueryFailed {
            query_id: 3,
            view_generation: 4,
            ..
        }
    ));
    assert_eq!(
        run(&r, 1, 2, Command::Cell(Cell::new(0, 0, 0))).outcome,
        Outcome::Cell(Block::Air)
    );
    assert!(matches!(
        run(&r, 1, 3, ray(4)).outcome,
        Outcome::QueryReady { query_id: 4, .. }
    ));
    stop(&r);
}
