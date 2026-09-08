use crate::Result;

#[allow(dead_code)]
pub fn classify(paths: &[String], full: bool) -> (bool, bool, bool, bool, bool, String) {
    sky_ci_classifier::classify(paths, full)
}

pub fn run(
    full: bool,
    base: Option<&str>,
    head: Option<&str>,
    paths_file: Option<&str>,
) -> Result<()> {
    sky_ci_classifier::run(full, base, head, paths_file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn values(paths: &[&str]) -> (bool, bool, bool, bool, bool, String) {
        classify(
            &paths.iter().map(|p| (*p).into()).collect::<Vec<_>>(),
            false,
        )
    }

    #[test]
    fn classifies_docs_without_expensive_jobs() {
        assert_eq!(
            values(&["docs/guide.md"]),
            (false, false, false, false, false, "docs/site only".into())
        );
    }

    #[test]
    fn classifies_native_and_package_changes() {
        let result = values(&["rust/crates/sky_player/src/lib.rs"]);
        assert!(result.0 && !result.1 && !result.2 && !result.3 && !result.4);
        assert!(values(&["rust/xtask/src/main.rs"]).0);
        assert!(!values(&["rust/xtask/src/main.rs"]).1);
    }

    #[test]
    fn package_sensitive_changes_require_code_validation() {
        let result = values(&[".github/workflows/ci.yml"]);
        assert!(result.0);
        assert!(!result.1);
        assert!(!result.3);
        assert!(result.4);
    }

    #[test]
    fn full_and_empty_modes_are_stable() {
        assert_eq!(
            classify(&[], true),
            (
                true,
                true,
                true,
                true,
                true,
                "full validation requested".into()
            )
        );
        assert_eq!(
            values(&[]),
            (false, false, false, false, false, "no changed paths".into())
        );
    }
}
