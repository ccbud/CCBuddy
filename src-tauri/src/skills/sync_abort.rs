use super::model::{SkillsSyncErrorDto, TargetMeta};
use std::path::Path;

pub fn abort(
    transaction: super::target_tx::SyncTransaction,
    error: SkillsSyncErrorDto,
) -> Result<super::target_tx::SyncTransaction, SkillsSyncErrorDto> {
    match error {
        SkillsSyncErrorDto::ConfirmationRequired { conflicts } => match transaction.rollback() {
            Ok(()) => Err(SkillsSyncErrorDto::ConfirmationRequired { conflicts }),
            Err(message) => Err(SkillsSyncErrorDto::Failed { message }),
        },
        SkillsSyncErrorDto::Failed { message } => Err(SkillsSyncErrorDto::Failed {
            message: super::target_tx::rollback_error(transaction, message),
        }),
    }
}

pub fn abort_confirmation(
    transaction: super::target_tx::SyncTransaction,
    id: &str,
    keys: &[String],
    home: &Path,
    original_targets: &[TargetMeta],
) -> Result<super::target_tx::SyncTransaction, SkillsSyncErrorDto> {
    match transaction.rollback() {
        Ok(()) => Err(super::sync_plan::confirmation_required(
            id,
            keys,
            home,
            original_targets,
        )),
        Err(message) => Err(SkillsSyncErrorDto::Failed { message }),
    }
}
