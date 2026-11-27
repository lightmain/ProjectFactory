#![allow(dead_code)]
use factory_core::runtime::{Command, Completion, Error, Input, Page, PollLimits, Runtime};
use std::time::{Duration, Instant};

pub fn retry<T>(mut call: impl FnMut() -> Result<T, Error>) -> Result<T, Error> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match call() {
            Err(Error::Busy) if Instant::now() < deadline => std::thread::yield_now(),
            result => return result,
        }
    }
}
pub fn take(runtime: &Runtime) -> Completion {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let mut page = page(runtime, 96);
        if !page.results.is_empty() {
            return page.results.remove(0);
        }
        assert!(Instant::now() < deadline, "{page:?}");
        std::thread::yield_now();
    }
}
pub fn page(runtime: &Runtime, bytes: usize) -> Page {
    retry(|| {
        runtime.poll_updates(PollLimits {
            result_bytes: bytes,
        })
    })
    .unwrap()
}
pub fn run(runtime: &Runtime, epoch: u64, request_id: u64, command: Command) -> Completion {
    retry(|| {
        runtime.submit(
            epoch,
            &Input {
                request_id,
                command: command.clone(),
            },
        )
    })
    .unwrap();
    let result = take(runtime);
    assert_eq!(result.request_id, request_id);
    result
}
pub fn stop(runtime: &Runtime) {
    runtime.close();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !runtime.is_stopped() && Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(runtime.is_stopped());
}
