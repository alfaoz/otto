mod audit;
mod cli;
mod client;
mod connect;
mod daemon;
mod host;
mod import;
mod mcp;
mod paths;
mod peer;
mod proto;
mod remote;
mod shell;
mod totp;
mod vault;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    // Chrome starts native messaging hosts with the extension origin as the first argument
    if let Some(origin) = args.get(1).filter(|a| a.starts_with("chrome-extension://")) {
        if let Err(e) = host::run(origin) {
            eprintln!("otto bridge: {e:#}");
            std::process::exit(1);
        }
        return;
    }
    // `otto sudo` makes otto sudo's askpass helper: sudo starts it with the prompt as its only argument
    if std::env::var_os("OTTO_ASKPASS").is_some() && peer::parent_is_sudo() {
        std::process::exit(cli::askpass());
    }
    std::process::exit(cli::main(args));
}
