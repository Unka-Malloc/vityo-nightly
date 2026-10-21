use std::{path::PathBuf, process::ExitCode};

use vityo_coding_agent::{application::AgentApplication, hosts::AcpHost};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const USAGE: &str = "Usage: vityo-coding-agent --stdio-agent --provider-config ABSOLUTE_PATH --session-dir ABSOLUTE_PATH\n       vityo-coding-agent --version\n       vityo-coding-agent --help";

enum Command {
    Version,
    Help,
    StdioAgent {
        provider_config: PathBuf,
        session_directory: PathBuf,
    },
}

#[tokio::main]
async fn main() -> ExitCode {
    match parse_command(std::env::args_os().skip(1)) {
        Ok(Command::Version) => {
            println!("vityo-coding-agent {VERSION} (ACP v1)");
            ExitCode::SUCCESS
        }
        Ok(Command::Help) => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        Ok(Command::StdioAgent {
            provider_config,
            session_directory,
        }) => match AgentApplication::from_paths(provider_config, session_directory) {
            Ok(application) => match AcpHost::new(application).run_stdio().await {
                Ok(()) => ExitCode::SUCCESS,
                Err(_) => {
                    eprintln!("ACP transport failed.");
                    ExitCode::from(70)
                }
            },
            Err(error) => {
                eprintln!("Agent initialization failed: {}.", error.safe_message());
                ExitCode::from(78)
            }
        },
        Err(()) => {
            eprintln!("{USAGE}");
            ExitCode::from(64)
        }
    }
}

fn parse_command(arguments: impl IntoIterator<Item = std::ffi::OsString>) -> Result<Command, ()> {
    let mut arguments = arguments.into_iter();
    let first = arguments.next().ok_or(())?;
    if first == "--version" {
        return arguments
            .next()
            .is_none()
            .then_some(Command::Version)
            .ok_or(());
    }
    if first == "--help" {
        return arguments
            .next()
            .is_none()
            .then_some(Command::Help)
            .ok_or(());
    }
    if first != "--stdio-agent" {
        return Err(());
    }

    let mut provider_config = None;
    let mut session_directory = None;
    while let Some(argument) = arguments.next() {
        match argument.to_str() {
            Some("--provider-config") if provider_config.is_none() => {
                provider_config = Some(PathBuf::from(arguments.next().ok_or(())?));
            }
            Some("--session-dir") if session_directory.is_none() => {
                session_directory = Some(PathBuf::from(arguments.next().ok_or(())?));
            }
            _ => return Err(()),
        }
    }

    let provider_config = provider_config.ok_or(())?;
    let session_directory = session_directory.ok_or(())?;
    if !provider_config.is_absolute() || !session_directory.is_absolute() {
        return Err(());
    }
    Ok(Command::StdioAgent {
        provider_config,
        session_directory,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn cli_requires_explicit_absolute_runtime_paths() {
        let root = tempdir().unwrap();
        let provider_config = root.path().join("provider.json").into_os_string();
        let session_directory = root.path().join("sessions").into_os_string();
        assert!(matches!(
            parse_command([
                "--stdio-agent".into(),
                "--provider-config".into(),
                provider_config.clone(),
                "--session-dir".into(),
                session_directory.clone()
            ]),
            Ok(Command::StdioAgent { .. })
        ));
        assert!(
            parse_command([
                "--stdio-agent".into(),
                "--provider-config".into(),
                "provider.json".into(),
                "--session-dir".into(),
                session_directory.clone()
            ])
            .is_err()
        );
        assert!(
            parse_command([
                "--stdio-agent".into(),
                "--session-dir".into(),
                session_directory
            ])
            .is_err()
        );
        assert!(parse_command(["--version".into(), "--stdio-agent".into()]).is_err());
    }
}
