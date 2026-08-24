// Chat tool-name allocation: keep the Responses identity recoverable while satisfying the
// OpenAI Chat name grammar (<=64 chars, alphanumeric/_/-), aliasing collisions deterministically.

use super::tools::{
    CodexToolContext, CodexToolKind, CodexToolSpec, CHAT_TOOL_NAME_HASH_LEN, CHAT_TOOL_NAME_MAX_LEN,
};
use sha1::{Digest, Sha1};

impl CodexToolContext {
    pub(super) fn reserve_chat_name(&mut self, spec: &CodexToolSpec) -> String {
        let preferred = preferred_chat_tool_name(spec);
        let chat_name = if is_valid_chat_tool_name(&preferred)
            && !self.colliding_preferred_names.contains(&preferred)
        {
            if let Some(existing_spec) = self.chat_name_to_spec.get(&preferred).cloned() {
                self.colliding_preferred_names.insert(preferred.clone());
                if preferred_chat_tool_name(&existing_spec) == preferred {
                    self.move_identity_to_hashed_alias(&existing_spec, &preferred);
                }
                self.allocate_hashed_chat_name(spec)
            } else {
                preferred
            }
        } else {
            self.allocate_hashed_chat_name(spec)
        };
        self.seen_chat_names.insert(chat_name.clone());
        self.chat_name_to_spec
            .insert(chat_name.clone(), spec.clone());
        self.spec_to_chat_name
            .insert(spec.clone(), chat_name.clone());
        chat_name
    }

    fn move_identity_to_hashed_alias(&mut self, spec: &CodexToolSpec, old_name: &str) {
        self.seen_chat_names.remove(old_name);
        self.chat_name_to_spec.remove(old_name);
        let new_name = self.allocate_hashed_chat_name(spec);
        self.seen_chat_names.insert(new_name.clone());
        self.chat_name_to_spec
            .insert(new_name.clone(), spec.clone());
        self.spec_to_chat_name
            .insert(spec.clone(), new_name.clone());
        if let Some(tool) = self
            .ir_tools
            .iter_mut()
            .find(|tool| tool.function.name == old_name)
        {
            tool.function.name = new_name;
        }
    }

    pub(super) fn allocate_chat_name(&self, spec: &CodexToolSpec) -> String {
        let preferred = preferred_chat_tool_name(spec);
        if is_valid_chat_tool_name(&preferred)
            && !self.colliding_preferred_names.contains(&preferred)
            && !self.seen_chat_names.contains(&preferred)
        {
            return preferred;
        }

        self.allocate_hashed_chat_name(spec)
    }

    fn allocate_hashed_chat_name(&self, spec: &CodexToolSpec) -> String {
        let preferred = preferred_chat_tool_name(spec);
        let digest = tool_identity_digest(spec);
        for attempt in 0_u64.. {
            let candidate = hashed_chat_tool_name(&preferred, &digest, attempt);
            if !self.seen_chat_names.contains(&candidate) {
                return candidate;
            }
        }
        unreachable!("the finite request cannot exhaust all valid Chat tool aliases")
    }
}

fn preferred_chat_tool_name(spec: &CodexToolSpec) -> String {
    match spec.namespace.as_deref() {
        Some(namespace) if !namespace.is_empty() => format!("{namespace}__{}", spec.name),
        _ => spec.name.clone(),
    }
}

pub(super) fn is_valid_chat_tool_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= CHAT_TOOL_NAME_MAX_LEN
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn sanitized_chat_tool_name(name: &str) -> String {
    let mut sanitized = String::with_capacity(name.len().min(CHAT_TOOL_NAME_MAX_LEN));
    for ch in name.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-') {
            sanitized.push(ch);
        } else {
            sanitized.push('_');
        }
    }
    if sanitized.is_empty() {
        sanitized.push_str("tool");
    }
    sanitized
}

fn tool_identity_digest(spec: &CodexToolSpec) -> String {
    let mut digest = Sha1::new();
    digest.update([match spec.kind {
        CodexToolKind::Function => 0,
        CodexToolKind::Namespace => 1,
        CodexToolKind::Custom => 2,
        CodexToolKind::ToolSearch => 3,
    }]);
    match spec.namespace.as_deref() {
        Some(namespace) => {
            digest.update([1]);
            digest.update((namespace.len() as u64).to_be_bytes());
            digest.update(namespace.as_bytes());
        }
        None => digest.update([0]),
    }
    digest.update((spec.name.len() as u64).to_be_bytes());
    digest.update(spec.name.as_bytes());
    format!("{:x}", digest.finalize())
}

fn hashed_chat_tool_name(preferred: &str, digest: &str, attempt: u64) -> String {
    let suffix = if attempt == 0 {
        format!("__{}", &digest[..CHAT_TOOL_NAME_HASH_LEN])
    } else {
        format!("__{}_{attempt}", &digest[..CHAT_TOOL_NAME_HASH_LEN])
    };
    let prefix_len = CHAT_TOOL_NAME_MAX_LEN.saturating_sub(suffix.len());
    let mut prefix = sanitized_chat_tool_name(preferred);
    prefix.truncate(prefix_len);
    format!("{prefix}{suffix}")
}
