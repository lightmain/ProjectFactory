use factory_core::{
    belt_placement::Direction,
    factory::{Factory, Ruleset},
    logistics::{STEP, Settings},
    world::{Block, Bounds, Cell},
};

fn factory(ruleset: Ruleset) -> Factory {
    Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
        ruleset,
    )
    .unwrap()
}
fn chain() -> Vec<(Cell, Block, Direction)> {
    [Block::Miner, Block::Belt, Block::Chest]
        .into_iter()
        .enumerate()
        .map(|(x, block)| (Cell::new(x as i32, 0, 0), block, Direction::East))
        .collect()
}

#[test]
fn both_rulesets_commit_complete_builds_and_reconcile_production_and_removed_inventory() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let mut factory = factory(ruleset);
        let preview = factory.preview(&chain()).unwrap();
        assert!(factory.observe().unwrap().machines.is_empty());
        factory.commit(&preview).unwrap();
        for _ in 0..180 {
            factory.advance(STEP).unwrap();
        }
        let before = factory.observe().unwrap();
        let lost = before
            .machines
            .iter()
            .find(|row| row.cell == Cell::new(1, 0, 0))
            .unwrap()
            .quantity;
        factory.remove(Cell::new(1, 0, 0)).unwrap();
        let state = factory.observe().unwrap();
        let ledger = factory.ledger();
        assert_eq!(ledger.produced, 30);
        assert_eq!(ledger.removed, lost);
        assert_eq!(
            state.machines.iter().map(|row| row.quantity).sum::<i64>(),
            ledger.initial + ledger.produced - ledger.removed
        );
        assert_eq!(ledger.initial as u64 + ledger.created - ledger.retired, 0);
        let mut restored = Factory::from_checkpoint(factory.checkpoint().unwrap()).unwrap();
        for _ in 0..120 {
            factory.advance(STEP).unwrap();
            restored.advance(STEP).unwrap();
        }
        assert_eq!(factory.observe().unwrap(), restored.observe().unwrap());
        assert_eq!(factory.ledger(), restored.ledger());
    }
}

#[test]
fn collision_cancel_new_request_and_edits_reject_stale_builds_without_partial_publication() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let mut factory = factory(ruleset);
        let mut invalid = chain();
        invalid.push((Cell::new(1, 0, 0), Block::Belt, Direction::East));
        let before = factory.observe().unwrap();
        assert!(factory.preview(&invalid).is_err());
        assert_eq!(factory.observe().unwrap(), before);
        let previous = factory.preview(&chain()).unwrap();
        let inactive = factory_core::belt_placement::Builder::new(128).unwrap();
        assert!(factory.preview_route(&inactive).is_err());
        assert!(factory.commit(&previous).is_err());
        let old = factory.preview(&chain()).unwrap();
        let mut other = self::factory(ruleset);
        let _other_preview = other.preview(&chain()).unwrap();
        assert!(other.commit(&old).is_err());
        factory.cancel_preview();
        assert!(factory.commit(&old).is_err());
        let old = factory.preview(&chain()).unwrap();
        let new = factory.preview(&chain()).unwrap();
        assert!(factory.commit(&old).is_err());
        factory.commit(&new).unwrap();
        let preview = factory
            .preview(&[(Cell::new(4, 0, 0), Block::Belt, Direction::East)])
            .unwrap();
        factory
            .set_direction(Cell::new(0, 0, 0), Direction::North)
            .unwrap();
        let before = factory.observe().unwrap();
        assert!(factory.commit(&preview).is_err());
        assert_eq!(factory.observe().unwrap(), before);
        assert_eq!(factory.world().block(Cell::new(4, 0, 0)), Block::Air);
    }
}

#[test]
fn route_commit_redirects_existing_start_and_preserves_terminal_and_ledger() {
    use factory_core::belt_placement::Builder;
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let mut factory = factory(ruleset);
        let start = Cell::new(2, 0, 0);
        let end = Cell::new(4, 0, 0);
        factory.place(start, Block::Belt, Direction::South).unwrap();
        factory.place(end, Block::Belt, Direction::North).unwrap();
        let directions = |cell| {
            if cell == start {
                Some(Direction::South)
            } else {
                Some(Direction::North)
            }
        };
        let mut builder = Builder::new(128).unwrap();
        builder
            .begin(factory.world(), &directions, start, Direction::South)
            .unwrap();
        builder
            .preview(factory.world(), &directions, Some(end), Direction::South)
            .unwrap();
        let before = factory.observe().unwrap();
        let ledger = factory.ledger();
        let preview = factory.preview_route(&builder).unwrap();
        assert_eq!(factory.observe().unwrap(), before);
        factory.commit(&preview).unwrap();
        let after = factory.observe().unwrap();
        assert_eq!(
            after
                .machines
                .iter()
                .find(|row| row.cell == start)
                .unwrap()
                .direction,
            Direction::East
        );
        assert_eq!(
            after
                .machines
                .iter()
                .find(|row| row.cell == end)
                .unwrap()
                .direction,
            Direction::North
        );
        assert_eq!(factory.world().block(Cell::new(3, 0, 0)), Block::Belt);
        assert_eq!(factory.ledger(), ledger);
        // An existing-only route remains valid and retains the terminal direction.
        builder.cancel();
        let directions = |_| Some(Direction::East);
        builder
            .begin(factory.world(), &directions, start, Direction::West)
            .unwrap();
        builder
            .preview(factory.world(), &directions, Some(start), Direction::West)
            .unwrap();
        let preview = factory.preview_route(&builder).unwrap();
        factory.commit(&preview).unwrap();
        assert_eq!(
            factory
                .observe()
                .unwrap()
                .machines
                .iter()
                .find(|row| row.cell == start)
                .unwrap()
                .direction,
            Direction::East
        );
    }
}
