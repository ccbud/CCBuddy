use std::path::Path;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Claim {
    External,
    Leased,
}

pub fn claim(id: &str, path: &Path) -> Result<Option<Claim>, String> {
    let mut store = lock_store()?;
    let Some(pin) = store.pins.iter_mut().find(|pin| pin.id == id) else {
        return Ok(None);
    };
    if !super::target_pin_open::handle_matches(&pin.handle, path)? {
        return Ok(None);
    }
    match pin.state {
        super::target_pin::PinState::External => {
            pin.state = super::target_pin::PinState::Claimed;
            Ok(Some(Claim::External))
        }
        super::target_pin::PinState::Claimed => Err(format!(
            "pinned target is already being relocated: {}",
            path.display()
        )),
        super::target_pin::PinState::Leased => Ok(Some(Claim::Leased)),
    }
}

pub fn active(id: &str, path: &Path) -> Result<bool, String> {
    let store = lock_store()?;
    let Some(pin) = store.pins.iter().find(|pin| pin.id == id) else {
        return Ok(false);
    };
    if pin.state == super::target_pin::PinState::External {
        return Ok(false);
    }
    super::target_pin_open::handle_matches(&pin.handle, path)
}

pub fn release(id: &str) {
    if let Ok(mut store) = super::target_pin::store().lock() {
        if let Some(index) = store.pins.iter().position(|pin| pin.id == id) {
            let pin = &mut store.pins[index];
            if pin.state == super::target_pin::PinState::Claimed && pin.revoke_pending {
                store.pins.remove(index);
            } else if pin.state == super::target_pin::PinState::Claimed {
                pin.state = super::target_pin::PinState::External;
            }
        }
        super::target_pin::prune_external(&mut store);
    }
}

pub fn rotate(id: &str, path: &Path, signature: &str) -> Result<Option<String>, String> {
    let mut store = lock_store()?;
    let Some(index) = store.pins.iter().position(|pin| pin.id == id) else {
        return Ok(None);
    };
    if store.pins[index].state != super::target_pin::PinState::Claimed {
        return Ok(None);
    }
    if !super::target_pin_open::handle_matches(&store.pins[index].handle, path)? {
        return Ok(None);
    }
    #[cfg(test)]
    if super::target_pin_rotate_test_hook::take_failure() {
        return Err("injected target pin rotation failure".into());
    }
    let replacement = unused_random_id(&store)?;
    let pin = &mut store.pins[index];
    pin.id = replacement.clone();
    pin.signature = signature.into();
    pin.state = super::target_pin::PinState::Leased;
    pin.revoke_pending = false;
    Ok(Some(replacement))
}

fn lock_store() -> Result<std::sync::MutexGuard<'static, super::target_pin::PinStore>, String> {
    let store = super::target_pin::store()
        .lock()
        .map_err(|_| "Skills target pin lock failed")?;
    Ok(store)
}

fn unused_random_id(store: &super::target_pin::PinStore) -> Result<String, String> {
    loop {
        let id = super::target_pin::random_id()?;
        if store.pins.iter().all(|pin| pin.id != id) {
            return Ok(id);
        }
    }
}
