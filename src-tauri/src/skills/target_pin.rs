use std::collections::VecDeque;
use std::fs::File;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

const MAX_EXTERNAL_PINS: usize = 64;
const MAX_TOTAL_PINS: usize = 128;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum PinState {
    External,
    Claimed,
    Leased,
}

pub(super) struct Pin {
    pub(super) id: String,
    pub(super) signature: String,
    pub(super) handle: File,
    pub(super) state: PinState,
    pub(super) revoke_pending: bool,
}

pub struct PendingPin {
    handle: Option<File>,
    reserved: bool,
}

#[derive(Default)]
pub(super) struct PinStore {
    pub(super) pins: VecDeque<Pin>,
    pending: usize,
}

pub fn begin(path: &Path) -> Result<PendingPin, String> {
    reserve_pending()?;
    let handle = match super::target_pin_open::open_entry(path) {
        Ok(handle) => handle,
        Err(error) => {
            release_pending();
            return Err(format!("pin {}: {error}", path.display()));
        }
    };
    match super::target_pin_open::handle_matches(&handle, path) {
        Ok(true) => {}
        Ok(false) => {
            release_pending();
            return Err(format!("target changed while pinning: {}", path.display()));
        }
        Err(error) => {
            release_pending();
            return Err(error);
        }
    }
    Ok(PendingPin {
        handle: Some(handle),
        reserved: true,
    })
}

impl PendingPin {
    pub fn finish(mut self, path: &Path, signature: &str, leased: bool) -> Result<String, String> {
        let handle = self.handle.as_ref().expect("pending pin handle");
        if !super::target_pin_open::handle_matches(handle, path)? {
            return Err(format!("target changed while pinning: {}", path.display()));
        }
        let result = issue_or_reuse(
            self.handle.take().expect("pending pin handle"),
            path,
            signature,
            leased,
        );
        self.reserved = false;
        result
    }
}

impl Drop for PendingPin {
    fn drop(&mut self) {
        if self.reserved {
            release_pending();
        }
    }
}

fn issue_or_reuse(
    handle: File,
    path: &Path,
    signature: &str,
    leased: bool,
) -> Result<String, String> {
    let mut store = store()
        .lock()
        .map_err(|_| "Skills target pin lock failed")?;
    store.pending = store.pending.saturating_sub(1);
    for pin in store.pins.iter_mut() {
        let reusable = if leased {
            pin.state != PinState::Claimed
        } else {
            pin.state == PinState::External
        };
        if pin.signature == signature
            && reusable
            && super::target_pin_open::handle_matches(&pin.handle, path)?
        {
            if leased {
                pin.state = PinState::Leased;
            }
            return Ok(pin.id.clone());
        }
    }
    let id = random_id()?;
    store.pins.push_back(Pin {
        id: id.clone(),
        signature: signature.into(),
        handle,
        state: if leased {
            PinState::Leased
        } else {
            PinState::External
        },
        revoke_pending: false,
    });
    prune_external(&mut store);
    Ok(id)
}

pub fn matches(id: &str, path: &Path) -> Result<bool, String> {
    let store = store()
        .lock()
        .map_err(|_| "Skills target pin lock failed")?;
    let Some(pin) = store.pins.iter().find(|pin| pin.id == id) else {
        return Ok(false);
    };
    super::target_pin_open::handle_matches(&pin.handle, path)
}

pub fn revoke(id: &str) {
    if let Ok(mut store) = store().lock() {
        if let Some(pin) = store.pins.iter_mut().find(|pin| pin.id == id) {
            if pin.state == PinState::Claimed {
                pin.revoke_pending = true;
                return;
            }
        }
        store.pins.retain(|pin| pin.id != id);
    }
}

fn reserve_pending() -> Result<(), String> {
    let mut store = store()
        .lock()
        .map_err(|_| "Skills target pin lock failed")?;
    while external_count(&store) + store.pending >= MAX_EXTERNAL_PINS
        || store.pins.len() + store.pending >= MAX_TOTAL_PINS
    {
        let Some(index) = store
            .pins
            .iter()
            .position(|pin| pin.state == PinState::External)
        else {
            return Err("too many active Skills target confirmations".into());
        };
        store.pins.remove(index);
    }
    store.pending += 1;
    Ok(())
}

fn release_pending() {
    if let Ok(mut store) = store().lock() {
        store.pending = store.pending.saturating_sub(1);
    }
}

pub(super) fn prune_external(store: &mut PinStore) {
    while external_count(store) > MAX_EXTERNAL_PINS || store.pins.len() > MAX_TOTAL_PINS {
        let Some(index) = store
            .pins
            .iter()
            .position(|pin| pin.state == PinState::External)
        else {
            break;
        };
        store.pins.remove(index);
    }
}

fn external_count(store: &PinStore) -> usize {
    store
        .pins
        .iter()
        .filter(|pin| pin.state == PinState::External)
        .count()
}

pub(super) fn store() -> &'static Mutex<PinStore> {
    static PINS: OnceLock<Mutex<PinStore>> = OnceLock::new();
    PINS.get_or_init(|| Mutex::new(PinStore::default()))
}

pub(super) fn random_id() -> Result<String, String> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| format!("create target pin: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}
