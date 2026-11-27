//! Join workers on a dedicated owner thread, never on the engine thread.
use std::{io, thread};

/// `finished` runs after join, including thread-local destruction. A failed
/// child spawn or an uncaught child panic is reported as an unsuccessful exit.
/// The bounded extra owner thread exits after this callback.
pub(crate) fn spawn(
    name: &'static str,
    operation: impl FnOnce() + Send + 'static,
    finished: impl FnOnce(bool) + Send + 'static,
) -> io::Result<()> {
    thread::Builder::new()
        .name(format!("{name}-owner"))
        .spawn(move || {
            let clean = thread::Builder::new()
                .name(name.into())
                .spawn(operation)
                .is_ok_and(|worker| worker.join().is_ok());
            finished(clean);
        })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::RefCell,
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
            mpsc::{self, Receiver, SyncSender},
        },
        time::{Duration, Instant},
    };

    struct Cleanup {
        entered: SyncSender<()>,
        release: Receiver<()>,
    }
    impl Drop for Cleanup {
        fn drop(&mut self) {
            self.entered.send(()).unwrap();
            self.release.recv_timeout(Duration::from_secs(5)).unwrap();
        }
    }
    thread_local! {
        static CLEANUP: RefCell<Option<Cleanup>> = const { RefCell::new(None) };
    }

    #[test]
    fn exit_is_reported_only_after_thread_local_cleanup_and_join() {
        let (entered, cleanup) = mpsc::sync_channel(1);
        let (release, wait) = mpsc::sync_channel(1);
        let stopped = Arc::new(AtomicBool::new(false));
        let done = stopped.clone();
        spawn(
            "factory-lifecycle-test",
            move || {
                CLEANUP.with(|slot| {
                    *slot.borrow_mut() = Some(Cleanup {
                        entered,
                        release: wait,
                    });
                });
            },
            move |clean| {
                assert!(clean);
                done.store(true, Ordering::Release);
            },
        )
        .unwrap();
        cleanup.recv_timeout(Duration::from_secs(5)).unwrap();
        let prematurely_stopped = stopped.load(Ordering::Acquire);
        release.send(()).unwrap();
        assert!(!prematurely_stopped);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !stopped.load(Ordering::Acquire) && Instant::now() < deadline {
            thread::yield_now();
        }
        assert!(stopped.load(Ordering::Acquire));
    }
}
