//! One worker, one outstanding request and one reliable terminal result.
use super::{
    Error, Result, Snapshot,
    store::{Directory, Entry, SaveRequest, Store},
};
use std::{
    path::PathBuf,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicU8, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError, TrySendError},
    },
};

pub enum Request {
    List,
    Save(Box<Snapshot>, SaveRequest),
    Load(String),
    Delete(String, u64),
}
pub enum Output {
    Listed(Directory),
    Saved(Entry),
    Loaded(Box<Snapshot>),
    Deleted,
}
struct Control {
    state: AtomicU8,
    progress: Mutex<String>,
}
/// Shared by an accepted world event and its later I/O request. Cancellation
/// and entering commit compete on the same atomic state even before capture.
#[derive(Clone)]
pub(crate) struct Cancellation(Arc<Control>);
impl Default for Cancellation {
    fn default() -> Self {
        Self(Arc::new(Control {
            state: AtomicU8::new(0),
            progress: Mutex::new("Queued".into()),
        }))
    }
}
impl Cancellation {
    pub(crate) fn cancel(&self) -> bool {
        matches!(
            self.0
                .state
                .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst),
            Ok(_) | Err(1)
        )
    }
    pub(crate) fn is_cancelled(&self) -> bool {
        self.0.state.load(Ordering::SeqCst) == 1
    }
    /// The world owner closes the load cancellation window at its decision.
    pub(crate) fn decide_commit(&self) -> bool {
        self.0
            .state
            .compare_exchange(0, 2, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
    }
}
impl Control {
    fn stage(&self, stage: &str) -> Result<()> {
        if stage == "Committing" {
            self.state
                .compare_exchange(0, 2, Ordering::SeqCst, Ordering::SeqCst)
                .map_err(|_| Error::Cancelled)?;
        } else if self.state.load(Ordering::SeqCst) == 1 {
            return Err(Error::Cancelled);
        }
        *self.progress.lock().map_err(|_| Error::WorkerFault)? = stage.into();
        Ok(())
    }
}
struct Work {
    id: u64,
    request: Request,
    control: Arc<Control>,
}
struct Terminal {
    id: u64,
    result: Result<Output>,
}
pub struct Update {
    pub id: u64,
    pub state: String,
    pub result: Option<Result<Output>>,
}
pub struct Service {
    sender: Option<SyncSender<Work>>,
    receiver: Receiver<Terminal>,
    next: u64,
    active: Option<(u64, Arc<Control>)>,
    stopped: Arc<AtomicBool>,
    exit: Arc<(Mutex<()>, Condvar)>,
}
impl Service {
    pub fn new(root: PathBuf) -> Result<Self> {
        Self::with_observer(root, |_| {})
    }
    // The observer is internal; tests block actual disk stages, not a simulated
    // transaction. It runs after the stage's cancellation/commit transition.
    pub(crate) fn with_observer(
        root: PathBuf,
        observer: impl Fn(&str) + Send + 'static,
    ) -> Result<Self> {
        Self::with_open(root, observer, |root| Store::open(root))
    }
    #[cfg(test)]
    pub(crate) fn with_observer_and_fault(
        root: PathBuf,
        observer: impl Fn(&str) + Send + 'static,
        fault: Option<super::store::Fault>,
    ) -> Result<Self> {
        Self::with_open(root, observer, move |root| {
            let mut store = Store::open(root)?;
            store.inject_fault(fault);
            Ok(store)
        })
    }
    fn with_open(
        root: PathBuf,
        observer: impl Fn(&str) + Send + 'static,
        open: impl Fn(&PathBuf) -> Result<Store> + Send + 'static,
    ) -> Result<Self> {
        let (sender, requests) = mpsc::sync_channel::<Work>(1);
        let (results, receiver) = mpsc::sync_channel(1);
        let stopped = Arc::new(AtomicBool::new(false));
        let done = stopped.clone();
        let exit = Arc::new((Mutex::new(()), Condvar::new()));
        let completed = exit.clone();
        crate::thread_lifecycle::spawn(
            "factory-save-io",
            move || {
                let mut store: Option<Store> = None;
                while let Ok(work) = requests.recv() {
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        let stage = |name: &str| {
                            work.control.stage(name)?;
                            observer(name);
                            Ok(())
                        };
                        stage("Queued")?;
                        // Initialization failure (including a competing writer) is
                        // per-request; the next request gets a fresh recovery attempt.
                        if store.is_none() {
                            store = Some(open(&root)?);
                        }
                        let store = store.as_mut().unwrap();
                        let output = match work.request {
                            Request::List => {
                                stage("Reading")?;
                                Output::Listed(store.list()?)
                            }
                            Request::Save(snapshot, request) => {
                                Output::Saved(
                                    store.save(*snapshot, request, &mut |name| stage(name))?,
                                )
                            }
                            Request::Load(id) => {
                                stage("Reading")?;
                                let snapshot = store.load(&id)?;
                                stage("Validating")?;
                                Output::Loaded(Box::new(snapshot))
                            }
                            Request::Delete(id, sequence) => {
                                // Delete has a short, indivisible directory transaction.
                                stage("Committing")?;
                                store.delete(&id, sequence)?;
                                Output::Deleted
                            }
                        };
                        if work.control.state.load(Ordering::SeqCst) == 1 {
                            return Err(Error::Cancelled);
                        }
                        Ok(output)
                    }))
                    .unwrap_or(Err(Error::WorkerFault));
                    if results
                        .send(Terminal {
                            id: work.id,
                            result,
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            },
            move |_| {
                let _guard = completed.0.lock().unwrap_or_else(|e| e.into_inner());
                done.store(true, Ordering::Release);
                completed.1.notify_all();
            },
        )?;
        Ok(Self {
            sender: Some(sender),
            receiver,
            next: 1,
            active: None,
            stopped,
            exit,
        })
    }
    pub fn busy(&self) -> bool {
        self.active.is_some()
    }
    pub fn submit(&mut self, request: Request) -> Result<u64> {
        self.submit_with_cancellation(request, Cancellation::default())
    }
    pub(crate) fn submit_with_cancellation(
        &mut self,
        request: Request,
        cancellation: Cancellation,
    ) -> Result<u64> {
        let sender = self.sender.as_ref().ok_or(Error::Closed)?;
        if self.is_stopped() {
            return Err(Error::WorkerFault);
        }
        if self.busy() {
            return Err(Error::Busy);
        }
        let id = self.next;
        self.next = self
            .next
            .checked_add(1)
            .ok_or(Error::Invalid("job identity"))?;
        let control = cancellation.0;
        sender
            .try_send(Work {
                id,
                request,
                control: control.clone(),
            })
            .map_err(|error| match error {
                TrySendError::Full(_) => Error::Busy,
                TrySendError::Disconnected(_) => Error::WorkerFault,
            })?;
        self.active = Some((id, control));
        Ok(id)
    }
    pub fn cancel(&mut self, id: u64) -> Result<bool> {
        let (active, control) = self.active.as_ref().ok_or(Error::Invalid("job missing"))?;
        if *active != id {
            return Err(Error::Invalid("job identity"));
        }
        match control
            .state
            .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
        {
            Ok(_) => Ok(true),
            Err(1) => Ok(true),
            Err(_) => Ok(false),
        }
    }
    pub fn poll(&mut self) -> Option<Update> {
        let (id, control) = self.active.as_ref()?;
        let id = *id;
        let state = control
            .progress
            .lock()
            .map_or_else(|_| "Fault".into(), |s| s.clone());
        match self.receiver.try_recv() {
            Ok(terminal) => {
                // Cancellation stays effective until the caller claims the
                // terminal. Committing writes already hold state 2.
                let result = if control.state.load(Ordering::SeqCst) == 1 {
                    Err(Error::Cancelled)
                } else {
                    terminal.result
                };
                self.active = None;
                let state = match &result {
                    Ok(_) => "Completed",
                    Err(Error::Cancelled) => "Cancelled",
                    Err(Error::CommitUncertain) => "CommitUncertain",
                    Err(_) => "Failed",
                }
                .into();
                Some(Update {
                    id: terminal.id,
                    state,
                    result: Some(result),
                })
            }
            Err(TryRecvError::Empty) => Some(Update {
                id,
                state,
                result: None,
            }),
            Err(TryRecvError::Disconnected) => {
                self.active = None;
                Some(Update {
                    id,
                    state: "Failed".into(),
                    result: Some(Err(Error::WorkerFault)),
                })
            }
        }
    }
    /// Cancel pre-commit work and disconnect new input without waiting for I/O.
    /// Retain an active result so a committed save still reports its true outcome.
    pub fn close(&mut self) {
        if let Some((_, control)) = &self.active {
            let _ = control
                .state
                .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst);
        }
        self.sender.take();
    }
    /// True only after the I/O worker has been joined by its owner thread.
    pub fn is_stopped(&self) -> bool {
        self.stopped.load(Ordering::Acquire)
    }
    /// Only the owning world worker may wait here; host close/drop never wait.
    pub(crate) fn wait_stopped(&self) {
        let mut guard = self.exit.0.lock().unwrap_or_else(|e| e.into_inner());
        while !self.is_stopped() {
            guard = self.exit.1.wait(guard).unwrap_or_else(|e| e.into_inner());
        }
    }
}
impl Drop for Service {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        factory::{Factory, Ruleset},
        logistics::Settings,
        persistence::{Player, Session, capture},
        world::Bounds,
    };
    use std::time::{Duration, Instant};

    #[test]
    fn disconnected_io_delivers_one_worker_fault_terminal() {
        let (sender, _requests) = mpsc::sync_channel(1);
        let (results, receiver) = mpsc::sync_channel(1);
        let mut service = Service {
            sender: Some(sender),
            receiver,
            next: 1,
            active: None,
            stopped: Arc::new(AtomicBool::new(false)),
            exit: Arc::new((Mutex::new(()), Condvar::new())),
        };
        let id = service.submit(Request::List).unwrap();
        drop(results);
        let terminal = service.poll().unwrap();
        assert_eq!(terminal.id, id);
        assert_eq!(terminal.state, "Failed");
        assert!(matches!(terminal.result, Some(Err(Error::WorkerFault))));
        assert!(service.poll().is_none());
    }

    #[test]
    fn disconnected_request_receiver_reports_fault_before_the_join_receipt() {
        let (sender, requests) = mpsc::sync_channel(1);
        let (_results, receiver) = mpsc::sync_channel(1);
        let mut service = Service {
            sender: Some(sender),
            receiver,
            next: 1,
            active: None,
            stopped: Arc::new(AtomicBool::new(false)),
            exit: Arc::new((Mutex::new(()), Condvar::new())),
        };
        drop(requests);
        assert!(!service.is_stopped());
        assert_eq!(
            service.submit(Request::List),
            Err(Error::WorkerFault),
            "a dead request receiver is not a capacity shortage"
        );
        assert!(!service.busy());
        assert!(service.poll().is_none());
    }

    #[test]
    fn close_never_waits_for_the_progress_lock() {
        let (sender, _requests) = mpsc::sync_channel(1);
        let (_results, receiver) = mpsc::sync_channel(1);
        let mut service = Service {
            sender: Some(sender),
            receiver,
            next: 1,
            active: None,
            stopped: Arc::new(AtomicBool::new(false)),
            exit: Arc::new((Mutex::new(()), Condvar::new())),
        };
        service.submit(Request::List).unwrap();
        let control = service.active.as_ref().unwrap().1.clone();
        let _guard = control.progress.lock().unwrap();
        service.close();
        assert_eq!(control.state.load(Ordering::SeqCst), 1);
        assert_eq!(service.submit(Request::List), Err(Error::Closed));
    }

    #[test]
    fn close_after_commit_begins_keeps_the_real_save_and_its_terminal() {
        let root =
            std::env::temp_dir().join(format!("factory-close-{}", super::super::store::new_id()));
        let factory = Factory::new(
            Bounds::default(),
            Settings {
                interval: 0.6,
                amount: 1,
            },
            Ruleset::LegacyDiscreteV1,
        )
        .unwrap();
        let snapshot = capture(
            &factory,
            &Session {
                world_id: [7; 16],
                world_name: "关闭保存".into(),
                autosave_minutes: 5.0,
                autosave_retention: 3,
                player: Player::default(),
            },
        )
        .unwrap();
        let expected_bytes = snapshot.encode().unwrap();
        let mut service = Service::new(root.clone()).unwrap();
        let id = service
            .submit(Request::Save(
                Box::new(snapshot),
                SaveRequest {
                    name: "提交后关闭".into(),
                    overwrite: false,
                    kind: super::super::store::Kind::Manual,
                    retention: 3,
                    expected_sequence: 0,
                },
            ))
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let control = &service.active.as_ref().unwrap().1;
        while control.state.load(Ordering::SeqCst) != 2 && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert_eq!(control.state.load(Ordering::SeqCst), 2, "must reach commit");
        service.close();
        assert!(!service.cancel(id).unwrap());
        while !service.is_stopped() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(
            service.is_stopped(),
            "unclaimed terminal must not block exit"
        );
        let update = service.poll().unwrap();
        assert_eq!(update.id, id);
        assert_eq!(update.state, "Completed");
        let entry = match update.result.unwrap().unwrap() {
            Output::Saved(entry) => entry,
            _ => panic!("wrong terminal"),
        };
        assert!(service.poll().is_none());
        let mut store = Store::open(&root).unwrap();
        assert_eq!(store.list().unwrap().entries, vec![entry.clone()]);
        assert_eq!(
            store.load(&entry.id).unwrap().encode().unwrap(),
            expected_bytes
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn close_does_not_hide_an_uncertain_commit_as_cancellation() {
        let (sender, _requests) = mpsc::sync_channel(1);
        let (results, receiver) = mpsc::sync_channel(1);
        let mut service = Service {
            sender: Some(sender),
            receiver,
            next: 1,
            active: None,
            stopped: Arc::new(AtomicBool::new(false)),
            exit: Arc::new((Mutex::new(()), Condvar::new())),
        };
        let id = service.submit(Request::List).unwrap();
        service
            .active
            .as_ref()
            .unwrap()
            .1
            .stage("Committing")
            .unwrap();
        results
            .send(Terminal {
                id,
                result: Err(Error::CommitUncertain),
            })
            .unwrap();
        service.close();
        let update = service.poll().unwrap();
        assert_eq!(update.state, "CommitUncertain");
        assert!(matches!(update.result, Some(Err(Error::CommitUncertain))));
        assert!(service.poll().is_none());
    }
    #[test]
    fn cancelling_an_enqueued_terminal_discards_its_output() {
        let (sender, _requests) = mpsc::sync_channel(1);
        let (results, receiver) = mpsc::sync_channel(1);
        let mut service = Service {
            sender: Some(sender),
            receiver,
            next: 1,
            active: None,
            stopped: Arc::new(AtomicBool::new(false)),
            exit: Arc::new((Mutex::new(()), Condvar::new())),
        };
        let id = service.submit(Request::List).unwrap();
        results
            .send(Terminal {
                id,
                result: Ok(Output::Listed(Directory::default())),
            })
            .unwrap();
        assert!(service.cancel(id).unwrap());
        assert!(matches!(
            service.poll().unwrap().result,
            Some(Err(Error::Cancelled))
        ));
    }
}
