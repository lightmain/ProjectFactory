mod support;
use factory_core::{
    belt_placement::Direction,
    factory::Ruleset,
    logistics::Settings,
    runtime::{
        Command, Limits, Outcome, Runtime,
        safety::{Aabb, Intent, Pose, Request},
    },
    world::{Block, Bounds, Cell},
};
use support::{run, stop};

fn pose() -> Pose {
    Pose {
        frame: 10,
        player: Aabb {
            low: [0.1, 0.05, 0.1],
            high: [0.4, 1.99, 0.4],
        },
        camera: None,
        margin: 0.001,
    }
}
#[test]
fn prepared_build_checks_pose_revision_engine_and_installs_only_after_confirmation() {
    for rules in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = Runtime::open(
            Bounds::default(),
            Settings {
                interval: 1.0,
                amount: 1,
            },
            rules,
            1,
            Limits::default(),
        )
        .unwrap();
        let request = Request {
            pose: pose(),
            intent: Intent::Cells(vec![(Cell::new(0, 0, 0), Block::Stone, Direction::East)]),
        };
        assert!(matches!(
            run(&r, 1, 1, Command::PrepareBuild(request)).outcome,
            Outcome::Rejected(_)
        ));
        let request = Request {
            pose: pose(),
            intent: Intent::Route(factory_core::runtime::queries::RouteRequest {
                start: Cell::new(0, 0, 0),
                direction: Direction::East,
                max_cells: 32,
                targets: vec![factory_core::runtime::queries::RouteTarget {
                    cell: Cell::new(2, 0, 0),
                    north_south_first: true,
                }],
            }),
        };
        assert!(
            matches!(run(&r,1,2,Command::PrepareBuild(request.clone())).outcome,
            Outcome::BuildPrepared { token: 2, lift, .. } if (lift - 0.08).abs() < 1e-9)
        );
        assert!(matches!(
            run(
                &r,
                1,
                3,
                Command::ConfirmBuild {
                    token: 2,
                    pose: pose(),
                    engine_clear: false
                }
            )
            .outcome,
            Outcome::Rejected(_)
        ));
        assert_eq!(
            run(&r, 1, 4, Command::Cell(Cell::new(0, 0, 0))).outcome,
            Outcome::Cell(Block::Air)
        );
        run(&r, 1, 5, Command::PrepareBuild(request.clone()));
        let mut moved = pose();
        moved.player.low[0] += 0.01;
        assert!(matches!(
            run(
                &r,
                1,
                6,
                Command::ConfirmBuild {
                    token: 5,
                    pose: moved,
                    engine_clear: true
                }
            )
            .outcome,
            Outcome::Rejected(_)
        ));
        run(&r, 1, 7, Command::PrepareBuild(request.clone()));
        run(
            &r,
            1,
            8,
            Command::Build(vec![(Cell::new(2, 0, 0), Block::Chest, Direction::East)]),
        );
        assert!(matches!(
            run(
                &r,
                1,
                9,
                Command::ConfirmBuild {
                    token: 7,
                    pose: pose(),
                    engine_clear: true
                }
            )
            .outcome,
            Outcome::Rejected(_)
        ));
        run(&r, 1, 10, Command::Remove(Cell::new(2, 0, 0)));
        run(&r, 1, 11, Command::PrepareBuild(request));
        assert!(
            matches!(run(&r,1,12,Command::ConfirmBuild { token: 11, pose: pose(), engine_clear: true }).outcome,
            Outcome::BuildCommitted { lift } if (lift - 0.08).abs() < 1e-9)
        );
        assert_eq!(
            run(&r, 1, 13, Command::Cell(Cell::new(0, 0, 0))).outcome,
            Outcome::Cell(Block::Belt)
        );
        stop(&r);
    }
}

#[test]
fn same_batch_ceiling_and_camera_overlap_reject_before_mutation() {
    let mut factory = factory_core::factory::Factory::new(
        Bounds::default(),
        Settings {
            interval: 1.0,
            amount: 1,
        },
        Ruleset::LegacyDiscreteV1,
    )
    .unwrap();
    let additions = vec![
        (Cell::new(0, 0, 0), Block::Belt, Direction::East),
        (Cell::new(0, 4, 0), Block::Belt, Direction::East),
    ];
    assert!(factory_core::runtime::safety::validate(&factory, &pose(), &additions, true).is_err());
    let mut camera_pose = pose();
    camera_pose.player.low[0] = 2.;
    camera_pose.player.high[0] = 2.3;
    camera_pose.camera = Some(Aabb {
        low: [0.1, 0.01, 0.1],
        high: [0.4, 0.1, 0.4],
    });
    assert!(
        factory_core::runtime::safety::validate(&factory, &camera_pose, &additions[..1], true)
            .is_err()
    );
    let preview = factory
        .preview(&[(Cell::new(0, 4, 0), Block::Stone, Direction::East)])
        .unwrap();
    factory.commit(&preview).unwrap();
    assert!(
        factory_core::runtime::safety::validate(&factory, &pose(), &additions[..1], true).is_err()
    );
}

#[test]
fn ramp_lift_uses_overlap_surface_and_keeps_authoritative_headroom() {
    for rules in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let mut factory = factory_core::factory::Factory::new(
            Bounds::default(),
            Settings {
                interval: 1.,
                amount: 1,
            },
            rules,
        )
        .unwrap();
        let slope = [(Cell::new(0, 0, 0), Block::BeltUp, Direction::South)];
        let lift =
            factory_core::runtime::safety::validate(&factory, &pose(), &slope, true).unwrap();
        assert!((lift - 0.48).abs() < 1e-9);
        assert!(factory_core::runtime::safety::validate(&factory, &pose(), &slope, false).is_err());
        factory
            .place(Cell::new(0, 4, 0), Block::Stone, Direction::South)
            .unwrap();
        assert!(factory_core::runtime::safety::validate(&factory, &pose(), &slope, true).is_err());
    }
}

#[test]
fn ceiling_added_after_prepare_rejects_confirm_without_lifting_or_partial_route() {
    for rules in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = Runtime::open(
            Bounds::default(),
            Settings {
                interval: 1.,
                amount: 1,
            },
            rules,
            1,
            Limits::default(),
        )
        .unwrap();
        let request = Request {
            pose: pose(),
            intent: Intent::Route(factory_core::runtime::queries::RouteRequest {
                start: Cell::new(0, 0, 0),
                direction: Direction::East,
                max_cells: 32,
                targets: vec![factory_core::runtime::queries::RouteTarget {
                    cell: Cell::new(2, 0, 0),
                    north_south_first: true,
                }],
            }),
        };
        assert!(matches!(
            run(&r, 1, 1, Command::PrepareBuild(request)).outcome,
            Outcome::BuildPrepared { .. }
        ));
        run(
            &r,
            1,
            2,
            Command::Build(vec![(Cell::new(0, 4, 0), Block::Stone, Direction::East)]),
        );
        assert!(matches!(
            run(
                &r,
                1,
                3,
                Command::ConfirmBuild {
                    token: 1,
                    pose: pose(),
                    engine_clear: true
                }
            )
            .outcome,
            Outcome::Rejected(_)
        ));
        assert_eq!(
            run(&r, 1, 4, Command::Cell(Cell::new(0, 0, 0))).outcome,
            Outcome::Cell(Block::Air)
        );
        stop(&r);
    }
}
