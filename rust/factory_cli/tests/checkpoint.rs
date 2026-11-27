use factory_core::{
    belt_placement::Direction,
    factory::{Factory, Ruleset},
    logistics::{STEP, Settings},
    persistence::{
        self, Player, Session,
        store::{Kind, SaveRequest, Store, new_id},
    },
    world::{Block, Bounds, Cell},
};
use std::{fs, process::Command};

#[test]
fn a_fresh_cli_process_validates_a_disk_checkpoint_and_continues_it() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let root = std::env::temp_dir().join(format!("factory-cli-save-{}", new_id()));
        let mut factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.6,
                amount: 1,
            },
            ruleset,
        )
        .unwrap();
        for (x, block) in [Block::Miner, Block::Belt, Block::Chest]
            .into_iter()
            .enumerate()
        {
            factory
                .place(Cell::new(x as i32, 0, 0), block, Direction::East)
                .unwrap();
        }
        factory.advance(2.15).unwrap();
        let snapshot = persistence::capture(
            &factory,
            &Session {
                world_id: [7; 16],
                world_name: "跨进程".into(),
                autosave_minutes: 5.0,
                autosave_retention: 3,
                player: Player::default(),
            },
        )
        .unwrap();
        let mut store = Store::open(&root).unwrap();
        let entry = store
            .save(
                snapshot,
                SaveRequest {
                    name: "重启".into(),
                    overwrite: false,
                    kind: Kind::Manual,
                    retention: 3,
                    expected_sequence: 0,
                },
                &mut |_| Ok(()),
            )
            .unwrap();
        drop(store);
        factory.advance(STEP * 60.0).unwrap();
        let expected = factory.observe().unwrap();
        let path = root.join(format!("{}.pfs", entry.payload));
        let output = Command::new(env!("CARGO_BIN_EXE_factory_cli"))
            .args(["validate-save", path.to_str().unwrap(), "60"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(
            text.contains(&format!("\"tick\":{}", expected.tick)),
            "{text}"
        );
        assert!(
            text.contains(&format!("\"produced\":{}", factory.ledger().produced)),
            "{text}"
        );
        let mut store = Store::open(&root).unwrap();
        let (mut restored, _) = store.load(&entry.id).unwrap().restore().unwrap();
        restored.advance(STEP * 60.0).unwrap();
        assert_eq!(restored.observe().unwrap(), expected);
        fs::write(&path, b"corrupt").unwrap();
        assert!(
            !Command::new(env!("CARGO_BIN_EXE_factory_cli"))
                .args(["validate-save", path.to_str().unwrap()])
                .status()
                .unwrap()
                .success()
        );
        let _ = fs::remove_dir_all(root);
    }
}
