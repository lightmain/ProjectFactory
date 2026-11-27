use factory_core::persistence::{
    Error,
    jobs::{Output, Request, Service},
    store::new_id,
};
fn finish(service: &mut Service) -> Result<Output, Error> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        if let Some(result) = service.poll().unwrap().result {
            return result;
        }
        assert!(std::time::Instant::now() < deadline);
        std::thread::yield_now();
    }
}
#[test]
fn transient_initial_directory_lock_failure_can_be_retried() {
    let directory = std::env::temp_dir().join(format!("factory-jobs-{}", new_id()));
    std::fs::create_dir(&directory).unwrap();
    let lock = std::fs::File::create(directory.join("directory.lock")).unwrap();
    lock.try_lock().unwrap();
    let mut service = Service::new(directory.clone()).unwrap();
    service.submit(Request::List).unwrap();
    assert!(matches!(finish(&mut service), Err(Error::Busy)));
    drop(lock);
    service.submit(Request::List).unwrap();
    assert!(matches!(finish(&mut service), Ok(Output::Listed(_))));
    drop(service);
    let _ = std::fs::remove_dir_all(directory);
}
#[test]
fn a_single_pending_job_reports_busy_and_delivers_its_terminal_result() {
    let directory = std::env::temp_dir().join(format!("factory-jobs-{}", new_id()));
    let mut service = Service::new(directory.clone()).unwrap();
    let id = service.submit(Request::List).unwrap();
    assert_eq!(service.submit(Request::List), Err(Error::Busy));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let update = service.poll().unwrap();
        assert_eq!(update.id, id);
        if let Some(result) = update.result {
            match result.unwrap() {
                Output::Listed(d) => assert!(d.entries.is_empty()),
                _ => panic!("wrong job output"),
            }
            break;
        }
        assert!(std::time::Instant::now() < deadline);
        std::thread::yield_now();
    }
    drop(service);
    let _ = std::fs::remove_dir_all(directory);
}

fn stopped(service: &Service) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !service.is_stopped() && std::time::Instant::now() < deadline {
        std::thread::yield_now();
    }
    assert!(service.is_stopped(), "I/O thread must be reaped");
}

#[test]
fn idle_close_is_repeatable_and_rejects_jobs_before_and_after_exit() {
    let directory = std::env::temp_dir().join(format!("factory-jobs-{}", new_id()));
    let mut service = Service::new(directory.clone()).unwrap();
    service.close();
    service.close();
    assert_eq!(service.submit(Request::List), Err(Error::Closed));
    stopped(&service);
    assert_eq!(service.submit(Request::List), Err(Error::Closed));
    assert!(service.poll().is_none());
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn close_with_an_unclaimed_job_keeps_one_terminal_and_releases_the_directory() {
    let directory = std::env::temp_dir().join(format!("factory-jobs-{}", new_id()));
    let mut service = Service::new(directory.clone()).unwrap();
    service.submit(Request::List).unwrap();
    service.close();
    stopped(&service); // Exit must not depend on claiming the terminal.
    assert!(matches!(finish(&mut service), Err(Error::Cancelled)));
    assert!(service.poll().is_none());
    let mut reopened = Service::new(directory.clone()).unwrap();
    reopened.submit(Request::List).unwrap();
    assert!(matches!(finish(&mut reopened), Ok(Output::Listed(_))));
    reopened.close();
    stopped(&reopened);
    std::fs::remove_dir_all(directory).unwrap();
}
