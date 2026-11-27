use factory_core::{
    belt_placement::Direction,
    factory::Ruleset,
    logistics::Settings,
    runtime::{
        Command, Error, Input, Limits, PollLimits, Runtime,
        presentation::{Interest, PAGE_BYTES, Stage},
    },
    world::{Block, Bounds, Cell},
};
use std::{
    thread,
    time::{Duration, Instant},
};

fn runtime(ruleset: Ruleset) -> Runtime {
    Runtime::open(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
        ruleset,
        1,
        Limits::default(),
    )
    .unwrap()
}

fn retry<T>(mut action: impl FnMut() -> Result<T, Error>) -> T {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match action() {
            Ok(value) => return value,
            Err(Error::Busy | Error::NotReady) if Instant::now() < deadline => thread::yield_now(),
            other => panic!("deadline: {:?}", other.err().unwrap()),
        }
    }
}

fn rejected<T>(mut action: impl FnMut() -> Result<T, Error>) -> Error {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match action() {
            Err(Error::Busy) if Instant::now() < deadline => thread::yield_now(),
            Err(error) => return error,
            Ok(_) => panic!("expected rejection"),
        }
    }
}

fn edit(runtime: &Runtime, seq: u64, command: Command) {
    retry(|| {
        runtime.submit(
            1,
            &Input {
                request_id: seq,
                command: command.clone(),
            },
        )
    });
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let page = retry(|| runtime.poll_updates(PollLimits::default()));
        if page.results.iter().any(|r| r.request_id == seq) {
            return;
        }
        assert!(Instant::now() < deadline);
        thread::yield_now();
    }
}

fn fill_paginated_chunk(runtime: &Runtime) {
    let cells = (0..8)
        .flat_map(|x| {
            (0..8).filter_map(move |z| {
                ((x + z) % 2 == 0).then_some((Cell::new(x, 2, z), Block::Stone, Direction::East))
            })
        })
        .collect();
    edit(runtime, 1, Command::Build(cells));
}

fn stopped(runtime: &Runtime) {
    runtime.close();
    let deadline = Instant::now() + Duration::from_secs(3);
    while !runtime.is_stopped() && Instant::now() < deadline {
        thread::yield_now();
    }
    assert!(runtime.is_stopped());
}

fn subscribe(runtime: &Runtime, generation: u64, keys: Vec<Cell>) {
    retry(|| {
        runtime.subscribe_presentation(
            1,
            &Interest {
                generation,
                job_id: 0,
                keys: keys.clone(),
            },
        )
    });
}

fn ready(runtime: &Runtime) -> factory_core::runtime::presentation::Info {
    retry(|| {
        let info = runtime.poll_presentation(1)?;
        if info.stage == Stage::Building {
            return Err(Error::NotReady);
        }
        assert_eq!(info.stage, Stage::Ready);
        Ok(info)
    })
}

#[test]
fn complete_pages_are_bounded_repeatable_and_require_every_page_before_ack() {
    let r = runtime(Ruleset::ConveyorContinuousV1);
    fill_paginated_chunk(&r);
    subscribe(&r, 1, vec![Cell::new(0, 0, 0)]);
    let info = ready(&r);
    assert!(info.total_pages > 1);
    assert!(info.total_bytes <= 8 * 1024 * 1024);
    let first = retry(|| r.poll_presentation_page(1, 1, info.snapshot_id, 0, PAGE_BYTES));
    assert_eq!(first.mesh.world_revision, info.revision);
    assert_eq!(
        first,
        retry(|| r.poll_presentation_page(1, 1, info.snapshot_id, 0, PAGE_BYTES))
    );
    assert!(first.bytes <= PAGE_BYTES);
    assert_eq!(
        rejected(|| r.acknowledge_presentation(1, 1, info.snapshot_id)),
        Error::InvalidAck
    );
    let mut triangle_vertices = first.mesh.indices.len();
    for index in 1..info.total_pages {
        let page = retry(|| r.poll_presentation_page(1, 1, info.snapshot_id, index, PAGE_BYTES));
        assert_eq!(page.mesh.world_revision, info.revision);
        assert_eq!(page.page_index, index);
        assert_eq!(page.revision, info.revision);
        assert_eq!(page.tick, info.tick);
        assert!(
            page.mesh
                .indices
                .iter()
                .all(|i| (*i as usize) < page.mesh.positions.len())
        );
        assert_eq!(page.mesh.collision.len(), page.mesh.indices.len());
        for (point, index) in page.mesh.collision.iter().zip(&page.mesh.indices) {
            assert_eq!(*point, page.mesh.positions[*index as usize]);
        }
        triangle_vertices += page.mesh.indices.len();
    }
    assert_eq!(
        triangle_vertices,
        32 * 36,
        "all isolated cube faces must survive paging"
    );
    retry(|| r.acknowledge_presentation(1, 1, info.snapshot_id));
    retry(|| r.acknowledge_presentation(1, 1, info.snapshot_id));
    stopped(&r);
}

#[test]
fn small_page_budget_rejects_before_copy_without_marking_delivery() {
    let r = runtime(Ruleset::LegacyDiscreteV1);
    fill_paginated_chunk(&r);
    subscribe(&r, 1, vec![Cell::new(0, 0, 0)]);
    let info = ready(&r);
    let p = retry(|| r.poll_presentation_page(1, 1, info.snapshot_id, 0, PAGE_BYTES));
    assert_eq!(
        rejected(|| r.poll_presentation_page(1, 1, info.snapshot_id, 0, p.bytes - 1)),
        Error::InvalidArgument
    );
    assert_eq!(
        rejected(|| r.poll_presentation_page(1, 1, info.snapshot_id, 1, 1023)),
        Error::InvalidArgument
    );
    assert_eq!(
        rejected(|| r.acknowledge_presentation(1, 1, info.snapshot_id)),
        Error::InvalidAck
    );
    stopped(&r);
}

#[test]
fn interest_preflight_and_generation_replay_do_not_change_valid_subscription() {
    let r = runtime(Ruleset::LegacyDiscreteV1);
    let interest = Interest {
        generation: 1,
        job_id: 0,
        keys: vec![Cell::new(0, 0, 0)],
    };
    retry(|| r.subscribe_presentation(1, &interest));
    retry(|| r.subscribe_presentation(1, &interest));
    for keys in [
        vec![],
        vec![Cell::new(0, 0, 0); 65],
        vec![Cell::new(i32::MAX, 0, 0)],
        vec![Cell::new(0, 0, 0); 2],
    ] {
        assert!(
            r.subscribe_presentation(
                1,
                &Interest {
                    generation: 2,
                    job_id: 0,
                    keys
                }
            )
            .is_err()
        );
    }
    assert_eq!(
        rejected(|| r.subscribe_presentation(
            1,
            &Interest {
                generation: 1,
                job_id: 0,
                keys: vec![Cell::new(1, 0, 0)]
            }
        )),
        Error::ConflictingReplay
    );
    let old = ready(&r);
    subscribe(&r, 2, vec![Cell::new(1, 0, 0)]);
    assert!(
        r.poll_presentation_page(1, 1, old.snapshot_id, 0, PAGE_BYTES)
            .is_err()
    );
    assert_eq!(ready(&r).generation, 2);
    assert_eq!(rejected(|| r.poll_presentation(2)), Error::StaleEpoch);
    retry(|| r.unsubscribe_presentation(1, 2));
    assert_eq!(rejected(|| r.poll_presentation(1)), Error::NotReady);
    assert_eq!(
        rejected(|| r.subscribe_presentation(
            1,
            &Interest {
                generation: 2,
                job_id: 0,
                keys: vec![Cell::new(1, 0, 0)]
            }
        )),
        Error::AlreadyFinalized
    );
    stopped(&r);
}

#[test]
fn neighbor_edits_invalidate_old_collision_and_rebuild_only_subscribed_chunks() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = runtime(ruleset);
        edit(
            &r,
            1,
            Command::Build(vec![(Cell::new(7, 2, 2), Block::Stone, Direction::East)]),
        );
        subscribe(&r, 1, vec![Cell::new(0, 0, 0)]);
        let before = ready(&r);
        let p = retry(|| r.poll_presentation_page(1, 1, before.snapshot_id, 0, PAGE_BYTES));
        assert_eq!(p.mesh.indices.len(), 36);
        edit(
            &r,
            2,
            Command::Build(vec![(Cell::new(8, 2, 2), Block::Stone, Direction::East)]),
        );
        assert!(
            r.acknowledge_presentation(1, 1, before.snapshot_id)
                .is_err()
        );
        let after = ready(&r);
        assert!(after.snapshot_id > before.snapshot_id);
        assert!(after.revision > before.revision);
        let p = retry(|| r.poll_presentation_page(1, 1, after.snapshot_id, 0, PAGE_BYTES));
        assert_eq!(p.keys, vec![Cell::new(0, 0, 0)]);
        assert_eq!(p.mesh.indices.len(), 30);
        assert_eq!(after.tick, 0);
        stopped(&r);
    }
}

#[test]
fn direction_changes_refresh_machine_marks_without_advancing_the_clock() {
    for ruleset in [Ruleset::LegacyDiscreteV1, Ruleset::ConveyorContinuousV1] {
        let r = runtime(ruleset);
        edit(
            &r,
            1,
            Command::Build(vec![(Cell::new(2, 2, 2), Block::Miner, Direction::East)]),
        );
        subscribe(&r, 1, vec![Cell::new(0, 0, 0)]);
        let before = ready(&r);
        edit(
            &r,
            2,
            Command::SetDirection(Cell::new(2, 2, 2), Direction::North),
        );
        let after = ready(&r);
        let p = retry(|| r.poll_presentation_page(1, 1, after.snapshot_id, 0, PAGE_BYTES));
        assert!(after.revision > before.revision);
        assert_eq!(p.mesh.world_revision, after.revision);
        for (normal, custom) in p.mesh.normals.iter().zip(&p.mesh.custom) {
            if custom[3] == 2.0 {
                assert_eq!(*normal, [0.0, 0.0, -1.0]);
            }
        }
        assert_eq!(after.tick, 0);
        stopped(&r);
    }
}

#[test]
fn empty_chunks_still_have_a_complete_retirement_page() {
    let r = runtime(Ruleset::LegacyDiscreteV1);
    subscribe(&r, 1, vec![Cell::new(0, 2, 0)]);
    let info = ready(&r);
    assert_eq!(info.total_pages, 1);
    let p = retry(|| r.poll_presentation_page(1, 1, info.snapshot_id, 0, PAGE_BYTES));
    assert!(p.mesh.positions.is_empty());
    assert_eq!(p.chunk_pages, 1);
    retry(|| r.acknowledge_presentation(1, 1, info.snapshot_id));
    stopped(&r);
}
