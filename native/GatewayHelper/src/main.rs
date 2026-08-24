use ccbud_gateway::{run, GatewayConfig};
use std::path::PathBuf;

fn usage() -> &'static str {
    "usage: ccbud-gateway --config <private-json-file> [--check-config] | --version"
}

fn parse_args() -> Result<(PathBuf, bool), String> {
    let mut args = std::env::args_os().skip(1);
    let mut config = None;
    let mut check = false;
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--config") => {
                let value = args.next().ok_or_else(|| usage().to_string())?;
                config = Some(PathBuf::from(value));
            }
            Some("--check-config") => check = true,
            Some("--help" | "-h") => {
                println!("{}", usage());
                std::process::exit(0);
            }
            Some("--version" | "-V") => {
                println!("ccbud-gateway {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            _ => return Err(usage().to_string()),
        }
    }
    Ok((config.ok_or_else(|| usage().to_string())?, check))
}

#[tokio::main]
async fn main() {
    let (path, check) = match parse_args() {
        Ok(value) => value,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };
    let config = match GatewayConfig::load_private(&path) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("gateway configuration rejected: {error}");
            std::process::exit(2);
        }
    };
    if check {
        println!("{{\"status\":\"ok\"}}");
        return;
    }
    if let Err(error) = run(config).await {
        eprintln!("gateway stopped with error: {error}");
        std::process::exit(1);
    }
}
