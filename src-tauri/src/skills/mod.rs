mod catalog;
mod git;
mod index;
mod install;
mod model;
mod ops;
mod paths;
mod remove;
mod resync;
mod scan;
mod sync;
mod target_tx;
mod tool_specs_a;
mod tool_specs_b;
mod tools;
mod transfer;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_safety;
#[cfg(test)]
mod tests_tx;
#[cfg(test)]
mod tests_tx_commit;
#[cfg(test)]
mod tests_validation;

pub use model::{LocalCandidateDto, SkillDetailDto, SkillDto, SkillsStatusDto, ToolDto};

pub fn root() -> Result<std::path::PathBuf, String> {
    paths::root()
}

pub fn list() -> Result<Vec<SkillDto>, String> {
    catalog::list(&root()?)
}

pub fn status() -> Result<SkillsStatusDto, String> {
    catalog::status(&root()?)
}

pub fn detail(id: &str) -> Result<SkillDetailDto, String> {
    catalog::detail(&root()?, id)
}

pub fn read_file(id: &str, file: &str) -> Result<String, String> {
    catalog::read_file(&root()?, id, file)
}

pub fn scan_local(path: &str) -> Result<Vec<LocalCandidateDto>, String> {
    scan::local_candidates(std::path::Path::new(path))
}

pub fn import_local(path: &str) -> Result<SkillDto, String> {
    install::import_local(&root()?, std::path::Path::new(path))
}

pub fn import_git(url: &str) -> Result<Vec<SkillDto>, String> {
    install::import_git(&root()?, url)
}

pub fn refresh(id: Option<&str>) -> Result<Vec<SkillDto>, String> {
    catalog::refresh(&root()?, id)
}

pub fn update(id: &str) -> Result<SkillDto, String> {
    install::update_source(&root()?, &paths::home_dir()?, id)
}

pub fn delete(id: &str) -> Result<bool, String> {
    remove::delete(&root()?, &paths::home_dir()?, id)
}

pub fn sync(id: &str, keys: Vec<String>, mode: Option<&str>) -> Result<SkillDto, String> {
    ops::sync(&root()?, &paths::home_dir()?, id, keys, mode)
}

pub fn unsync(id: &str, keys: Vec<String>) -> Result<SkillDto, String> {
    ops::unsync(&root()?, &paths::home_dir()?, id, keys)
}

pub fn set_tags(id: &str, tags: Vec<String>) -> Result<SkillDto, String> {
    catalog::set_tags(&root()?, id, tags)
}

pub fn tools() -> Result<Vec<ToolDto>, String> {
    Ok(tools::list(&paths::home_dir()?))
}
