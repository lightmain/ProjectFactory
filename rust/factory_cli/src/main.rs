use factory_core::{build_info::BUILD_INFO, protocol::implemented_capabilities};
use std::process::ExitCode;

fn validate_save(path: &str, ticks: &str) -> Result<(), String> {
    use factory_core::{logistics::STEP, persistence};
    let ticks: u32 = ticks.parse().map_err(|_| "ticks must be an integer")?;
    if ticks > 36_000 {
        return Err("ticks must be between 0 and 36000".into());
    }
    let bytes = persistence::store::read_file(std::path::Path::new(path), persistence::MAX_BYTES)
        .map_err(|error| error.to_string())?;
    let (mut factory, session) = persistence::decode(&bytes)
        .and_then(|snapshot| snapshot.restore())
        .map_err(|error| error.to_string())?;
    factory
        .advance(f64::from(ticks) * STEP)
        .map_err(|error| format!("{error:?}"))?;
    let state = factory.observe().map_err(|error| format!("{error:?}"))?;
    println!(
        "{{\"valid\":true,\"version\":5,\"world_id\":\"{}\",\"ruleset\":\"{}\",\"tick\":{},\"produced\":{}}}",
        persistence::store::hex(&session.world_id),
        factory.ruleset().name(),
        state.tick,
        factory.ledger().produced
    );
    Ok(())
}

fn simulate(ruleset: &str, ticks: &str) -> Result<(), String> {
    use factory_core::{
        belt_placement::Direction,
        factory::{Factory, Ruleset},
        logistics::{STEP, Settings},
        world::{Block, Bounds, Cell},
    };
    let ruleset = Ruleset::parse(ruleset).map_err(|error| format!("{error:?}"))?;
    let ticks: u32 = ticks.parse().map_err(|_| "ticks must be an integer")?;
    if !(1..=36_000).contains(&ticks) {
        return Err("ticks must be between 1 and 36000".into());
    }
    let mut factory = Factory::new(
        Bounds::default(),
        Settings {
            interval: 0.1,
            amount: 1,
        },
        ruleset,
    )
    .map_err(|error| format!("{error:?}"))?;
    let additions = [Block::Miner, Block::Belt, Block::Chest]
        .into_iter()
        .enumerate()
        .map(|(x, block)| (Cell::new(x as i32, 0, 0), block, Direction::East))
        .collect::<Vec<_>>();
    let preview = factory
        .preview(&additions)
        .map_err(|error| format!("{error:?}"))?;
    factory
        .commit(&preview)
        .map_err(|error| format!("{error:?}"))?;
    for _ in 0..ticks {
        factory
            .advance(STEP)
            .map_err(|error| format!("{error:?}"))?;
    }
    let state = factory.observe().map_err(|error| format!("{error:?}"))?;
    let total: i64 = state.machines.iter().map(|row| row.quantity).sum();
    let chest = state
        .machines
        .iter()
        .find(|row| row.block == Block::Chest)
        .unwrap()
        .quantity;
    let ledger = factory.ledger();
    println!(
        "{{\"ruleset\":\"{}\",\"tick\":{},\"total\":{},\"chest\":{},\"produced\":{},\"removed\":{},\"next_id\":{}}}",
        ruleset.name(),
        state.tick,
        total,
        chest,
        ledger.produced,
        ledger.removed,
        state.next_id
    );
    Ok(())
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments.as_slice() {
        [operation] if operation == "capabilities" => {
            let capabilities = implemented_capabilities();
            println!(
                "{{\"api_version\":{},\"features\":[\"{}\"],\"rulesets\":[\"{}\"],\"background\":{},\"persistence\":{}}}",
                capabilities.api_version,
                capabilities.features.join("\",\""),
                capabilities.rulesets.join("\",\""),
                capabilities.background,
                capabilities.persistence
            );
        }
        [operation] if operation == "build-info" => println!("{}", BUILD_INFO.to_json()),
        [operation, ruleset, ticks] if operation == "simulate" => {
            if let Err(error) = simulate(ruleset, ticks) {
                eprintln!("{error}");
                return ExitCode::from(2);
            }
        }
        [operation, path] if operation == "validate-save" => {
            if let Err(error) = validate_save(path, "0") {
                eprintln!("{error}");
                return ExitCode::from(2);
            }
        }
        [operation, path, ticks] if operation == "validate-save" => {
            if let Err(error) = validate_save(path, ticks) {
                eprintln!("{error}");
                return ExitCode::from(2);
            }
        }
        _ => {
            eprintln!(
                "Usage: factory_cli capabilities | build-info | simulate <ruleset> <ticks> | validate-save <file.pfs> [ticks]"
            );
            return ExitCode::from(2);
        }
    }
    ExitCode::SUCCESS
}
