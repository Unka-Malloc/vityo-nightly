use std::process::ExitCode;

use vityo_coding_agent::protocol::types::ACP_PROTOCOL_VERSION;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> ExitCode {
    let mut arguments = std::env::args_os();
    let _program = arguments.next();
    match (arguments.next(), arguments.next()) {
        (None, None) => {
            println!("vityo-coding-agent {VERSION} (ACP v{ACP_PROTOCOL_VERSION})");
            ExitCode::SUCCESS
        }
        (Some(argument), None) if argument == "--version" => {
            println!("vityo-coding-agent {VERSION} (ACP v{ACP_PROTOCOL_VERSION})");
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("the Agent runtime is not composed yet");
            ExitCode::from(69)
        }
    }
}
