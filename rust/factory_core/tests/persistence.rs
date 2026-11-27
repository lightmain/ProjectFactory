use factory_core::{
    belt_placement::{Builder, Direction},
    factory::{Factory, Ruleset},
    logistics::Settings,
    persistence::{self, Player, Session},
    world::{Block, Bounds, Cell},
};

fn session() -> Session {
    Session {
        world_id: [7; 16],
        world_name: "转弯工厂".into(),
        autosave_minutes: 5.0,
        autosave_retention: 3,
        player: Player {
            frame: 42,
            ..Player::default()
        },
    }
}

fn route(factory: &mut Factory, start: Cell, end: Cell) {
    let directions = factory
        .observe()
        .unwrap()
        .machines
        .into_iter()
        .map(|r| (r.cell, r.direction))
        .collect::<std::collections::BTreeMap<_, _>>();
    let mut route = Builder::new(128).unwrap();
    route
        .begin(
            factory.world(),
            &|at| directions.get(&at).copied(),
            start,
            Direction::East,
        )
        .unwrap();
    route
        .preview(
            factory.world(),
            &|at| directions.get(&at).copied(),
            Some(end),
            Direction::East,
        )
        .unwrap();
    let preview = factory.preview_route(&route).unwrap();
    factory.commit(&preview).unwrap();
}

#[test]
fn disk_roundtrip_preserves_partial_ticks_dirty_directions_and_exact_continuation() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let mut factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.1,
                amount: 1,
            },
            ruleset,
        )
        .unwrap();
        factory
            .place(Cell::new(-1, 0, 0), Block::Miner, Direction::East)
            .unwrap();
        route(&mut factory, Cell::new(0, 0, 0), Cell::new(3, 0, 0));
        if ruleset == Ruleset::ConveyorContinuousV1 {
            route(&mut factory, Cell::new(1, 0, 0), Cell::new(1, 0, 2));
            route(&mut factory, Cell::new(1, 0, 0), Cell::new(1, 0, -2));
        }
        factory.advance(5.003).unwrap();
        factory
            .place(Cell::new(4, 0, 3), Block::Miner, Direction::East)
            .unwrap();
        if ruleset == Ruleset::LegacyDiscreteV1 {
            factory
                .set_direction(Cell::new(1, 0, 0), Direction::South)
                .unwrap();
        }
        let bytes = persistence::capture(&factory, &session())
            .unwrap()
            .encode()
            .unwrap();
        let (mut restored, loaded) = persistence::decode(&bytes).unwrap().restore().unwrap();
        assert_eq!(loaded, session());
        assert_eq!(factory.observe().unwrap(), restored.observe().unwrap());
        assert_eq!(
            factory.world().chunk_deltas(),
            restored.world().chunk_deltas()
        );
        assert_eq!(factory.revision(), restored.revision());
        for z in [-3, 3] {
            for target in [&mut factory, &mut restored] {
                target
                    .place(
                        Cell::new(1, 0, z),
                        Block::Chest,
                        if z > 0 {
                            Direction::South
                        } else {
                            Direction::North
                        },
                    )
                    .unwrap();
            }
        }
        for delta in [0.0003, 0.013, 0.4, 3.0] {
            factory.advance(delta).unwrap();
            restored.advance(delta).unwrap();
            assert_eq!(factory.observe().unwrap(), restored.observe().unwrap());
            assert_eq!(factory.ledger(), restored.ledger());
        }
    }
}

#[test]
fn malformed_container_is_rejected_without_touching_live_factory() {
    let factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.6,
            amount: 1,
        },
        Ruleset::LegacyDiscreteV1,
    )
    .unwrap();
    let bytes = persistence::capture(&factory, &session())
        .unwrap()
        .encode()
        .unwrap();
    for length in [0, 8, 127, bytes.len() - 1] {
        assert!(persistence::decode(&bytes[..length]).is_err());
    }
    let mut corrupt = bytes.clone();
    *corrupt.last_mut().unwrap() ^= 1;
    assert!(persistence::decode(&corrupt).is_err());
    let mut trailing = bytes;
    trailing.push(0);
    assert!(persistence::decode(&trailing).is_err());
    assert_eq!(factory.observe().unwrap().time, 0.0);
}

#[test]
fn real_floating_point_production_stop_survives_later_checkpoints() {
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.001,
            amount: 1,
        },
        Ruleset::LegacyDiscreteV1,
    )
    .unwrap();
    // Move an empty world cheaply to a clock where tick/deadline rounding matters.
    factory.advance(2f64.powi(42)).unwrap();
    factory
        .place(Cell::new(0, 0, 0), Block::Miner, Direction::East)
        .unwrap();
    factory.advance(0.1).unwrap();
    assert_eq!(factory.observe().unwrap().machines[0].next, f64::INFINITY);
    factory.advance(2.0).unwrap();
    let bytes = persistence::capture(&factory, &session())
        .unwrap()
        .encode()
        .unwrap();
    let (mut restored, _) = persistence::decode(&bytes).unwrap().restore().unwrap();
    assert_eq!(factory.observe().unwrap(), restored.observe().unwrap());
    factory.advance(1.0).unwrap();
    restored.advance(1.0).unwrap();
    assert_eq!(factory.observe().unwrap(), restored.observe().unwrap());
}

#[test]
fn removed_structure_watermark_survives_a_disk_checkpoint() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let mut factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.6,
                amount: 1,
            },
            ruleset,
        )
        .unwrap();
        factory
            .place(Cell::new(0, 0, 0), Block::Structure, Direction::East)
            .unwrap();
        let removed = factory.world().structure_rows()[0].id;
        factory.remove(Cell::new(0, 0, 0)).unwrap();
        let bytes = persistence::capture(&factory, &session())
            .unwrap()
            .encode()
            .unwrap();
        let (mut restored, _) = persistence::decode(&bytes).unwrap().restore().unwrap();
        assert_eq!(factory.revision(), restored.revision());
        restored
            .place(Cell::new(0, 0, 0), Block::Structure, Direction::South)
            .unwrap();
        assert!(restored.world().structure_rows()[0].id.value() > removed.value());
        assert!(restored.world().structure(removed).is_none());
    }
}

#[test]
fn fixed_empty_checkpoint_has_a_frozen_container_digest_and_header() {
    use sha2::{Digest, Sha256};
    let factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.6,
            amount: 1,
        },
        Ruleset::LegacyDiscreteV1,
    )
    .unwrap();
    let bytes = persistence::capture(&factory, &session())
        .unwrap()
        .encode()
        .unwrap();
    assert_eq!(&bytes[..8], b"PFSAVE5\0");
    assert_eq!(
        &bytes[8..24],
        &[5, 0, 0, 0, 192, 2, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0]
    );
    assert_eq!(&bytes[32..48], &[7; 16]);
    assert_eq!(&bytes[80..88], &42u64.to_le_bytes());
    assert_eq!(&bytes[88..96], &[0; 8]);
    assert_eq!(
        persistence::store::hex(&Sha256::digest(bytes)),
        "18f7bad9acdc7bb764edd8f67bebf4be397e152c318a96dea8cec9d76aa0c877"
    );
}
