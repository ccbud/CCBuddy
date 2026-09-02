thread_local! {
    static FAIL_ROTATION: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static CLAIM_PAUSE: std::cell::RefCell<Option<ClaimPause>> = const {
        std::cell::RefCell::new(None)
    };
}

type ClaimPause = (std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>);

pub fn fail_next() {
    FAIL_ROTATION.with(|value| value.set(true));
}

pub(super) fn take_failure() -> bool {
    FAIL_ROTATION.with(|value| value.replace(false))
}

pub fn pause_after_claim(
    entered: std::sync::mpsc::Sender<()>,
    resume: std::sync::mpsc::Receiver<()>,
) {
    CLAIM_PAUSE.with(|value| value.replace(Some((entered, resume))));
}

pub(super) fn after_claim() {
    let pause = CLAIM_PAUSE.with(|value| value.borrow_mut().take());
    if let Some((entered, resume)) = pause {
        entered.send(()).unwrap();
        resume.recv().unwrap();
    }
}
