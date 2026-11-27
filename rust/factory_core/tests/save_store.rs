use factory_core::{
    factory::{Factory, Ruleset},
    logistics::Settings,
    persistence::{
        self, Error, Player, Session,
        store::{Fault, Kind, SaveRequest, Store, new_id},
    },
    world::Bounds,
};
use std::{fs, path::PathBuf};

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("factory-save-test-{}", new_id()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn capture() -> persistence::Snapshot {
    let f = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.6,
            amount: 1,
        },
        Ruleset::ConveyorContinuousV1,
    )
    .unwrap();
    persistence::capture(
        &f,
        &Session {
            world_id: [7; 16],
            world_name: "我的世界".into(),
            autosave_minutes: 5.0,
            autosave_retention: 3,
            player: Player::default(),
        },
    )
    .unwrap()
}
fn request(name: &str, sequence: u64) -> SaveRequest {
    SaveRequest {
        name: name.into(),
        overwrite: false,
        kind: Kind::Manual,
        retention: 3,
        expected_sequence: sequence,
    }
}
#[test]
fn named_overwrite_delete_rotation_and_reopening_preserve_identity() {
    let directory = Directory::new();
    let mut store = Store::open(&directory.0).unwrap();
    let first = store
        .save(capture(), request("中文档", 0), &mut |_| Ok(()))
        .unwrap();
    assert!(
        store
            .save(capture(), request("中文档", 1), &mut |_| Ok(()))
            .is_err()
    );
    let mut overwrite = request("中文档", 1);
    overwrite.overwrite = true;
    let replaced = store.save(capture(), overwrite, &mut |_| Ok(())).unwrap();
    assert_eq!(first.id, replaced.id);
    assert_ne!(first.payload, replaced.payload);
    assert_eq!(
        store.load(&first.id).unwrap().session.world_name,
        "我的世界"
    );
    for n in 0..5 {
        let mut r = request(&format!("自动{n}"), store.list().unwrap().sequence);
        r.kind = Kind::Auto;
        r.retention = 3;
        store.save(capture(), r, &mut |_| Ok(())).unwrap();
    }
    assert_eq!(store.list().unwrap().entries.len(), 4);
    drop(store);
    let mut reopened = Store::open(&directory.0).unwrap();
    assert_eq!(reopened.list().unwrap().entries.len(), 4);
    let seq = reopened.list().unwrap().sequence;
    assert_eq!(
        reopened.delete(&first.id, seq - 1),
        Err(Error::StaleDirectory)
    );
    reopened.delete(&first.id, seq).unwrap();
    assert_eq!(reopened.list().unwrap().entries.len(), 3);
    assert!(reopened.load("../../arbitrary").is_err());
}
#[test]
fn failed_payload_or_index_commit_keeps_previous_save_and_corrupt_index_falls_back() {
    let directory = Directory::new();
    let mut store = Store::open(&directory.0).unwrap();
    let first = store
        .save(capture(), request("有效", 0), &mut |_| Ok(()))
        .unwrap();
    store.inject_fault(Some(Fault::BeforeIndexRename));
    assert!(
        store
            .save(capture(), request("失败", 1), &mut |_| Ok(()))
            .is_err()
    );
    assert_eq!(store.list().unwrap().entries.len(), 1);
    assert_eq!(store.list().unwrap().entries[0].id, first.id);
    store.inject_fault(None);
    store
        .save(capture(), request("新档", 1), &mut |_| Ok(()))
        .unwrap();
    fs::write(directory.0.join("index_0.bin"), b"broken").unwrap();
    let mut recovered = Store::open(&directory.0).unwrap();
    assert_eq!(recovered.list().unwrap().sequence, 1);
    assert_eq!(recovered.list().unwrap().entries[0].id, first.id);
}
#[test]
fn cancellation_before_commit_and_uncertain_commit_have_distinct_outcomes() {
    let directory = Directory::new();
    let mut store = Store::open(&directory.0).unwrap();
    assert_eq!(
        store
            .save(capture(), request("取消", 0), &mut |stage| {
                if stage == "Writing" {
                    Err(Error::Cancelled)
                } else {
                    Ok(())
                }
            })
            .map(|_| ()),
        Err(Error::Cancelled)
    );
    assert!(store.list().unwrap().entries.is_empty());
    store.inject_fault(Some(Fault::AfterIndexRename));
    assert_eq!(
        store
            .save(capture(), request("不确定", 0), &mut |_| Ok(()))
            .map(|_| ()),
        Err(Error::CommitUncertain)
    );
    assert_eq!(store.delete(&new_id(), 1), Err(Error::CommitUncertain));
    drop(store);
    let mut recovered = Store::open(&directory.0).unwrap();
    assert_eq!(recovered.list().unwrap().entries.len(), 1);
}

#[test]
fn corrupted_latest_payload_keeps_the_verified_fallback_for_listing_loading_and_new_saves() {
    let directory = Directory::new();
    let mut store = Store::open(&directory.0).unwrap();
    let first = store
        .save(capture(), request("同档", 0), &mut |_| Ok(()))
        .unwrap();
    let mut replace = request("同档", 1);
    replace.overwrite = true;
    let latest = store.save(capture(), replace, &mut |_| Ok(())).unwrap();
    fs::write(
        directory.0.join(format!("{}.pfs", latest.payload)),
        b"corrupt",
    )
    .unwrap();
    drop(store);
    let mut recovered = Store::open(&directory.0).unwrap();
    assert_eq!(recovered.list().unwrap().sequence, 1);
    assert_eq!(recovered.load(&first.id).unwrap().session.world_id, [7; 16]);
    recovered
        .save(capture(), request("回退后的新档", 1), &mut |_| Ok(()))
        .unwrap();
    assert_eq!(recovered.load(&first.id).unwrap().session.world_id, [7; 16]);
}

#[test]
fn oversized_latest_index_falls_back_and_other_instances_confirm_visible_commits() {
    let directory = Directory::new();
    let mut first = Store::open(&directory.0).unwrap();
    first
        .save(capture(), request("旧档", 0), &mut |_| Ok(()))
        .unwrap();
    let mut second = Store::open(&directory.0).unwrap();
    first.inject_fault(Some(Fault::AfterIndexRename));
    assert_eq!(
        first
            .save(capture(), request("新档", 1), &mut |_| Ok(()))
            .map(|_| ()),
        Err(Error::CommitUncertain)
    );
    // A different instance must validate/re-sync the visible index before writing.
    assert_eq!(second.list().unwrap().sequence, 2);
    second
        .save(capture(), request("已确认", 2), &mut |_| Ok(()))
        .unwrap();
    fs::write(directory.0.join("index_1.bin"), vec![0; 1024 * 1024 + 1]).unwrap();
    assert_eq!(
        Store::open(&directory.0).unwrap().list().unwrap().sequence,
        2
    );
}
