use factory_world_probe::{Cell, World};
use std::{
    collections::BTreeSet,
    env,
    fs::OpenOptions,
    io::{BufReader, BufWriter},
    time::Instant,
};

mod audit;
mod probe;

fn option<'a>(arguments: &'a [String], name: &str) -> Result<&'a str, String> {
    arguments
        .windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].as_str())
        .ok_or_else(|| format!("missing {name}"))
}

fn seed(arguments: &[String]) -> Result<u32, Box<dyn std::error::Error>> {
    Ok(arguments
        .windows(2)
        .find(|pair| pair[0] == "--seed")
        .map_or(Ok(20_261_125), |pair| pair[1].parse())?)
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    let allowed: &[&str] = match arguments.first().map(String::as_str) {
        Some("generate") => &["--size", "--seed", "--output"],
        Some("probe") => &["--input", "--seed", "--warmup", "--samples"],
        _ => return Err("usage: factory_world_probe generate|probe [options]".into()),
    };
    // Command plus key/value pairs always has odd length.
    if arguments.len().is_multiple_of(2) {
        return Err("options require key/value pairs".into());
    }
    let mut seen = BTreeSet::new();
    for pair in arguments[1..].as_chunks::<2>().0 {
        if !allowed.contains(&pair[0].as_str()) || !seen.insert(&pair[0]) {
            return Err(format!("unknown or duplicate option {}", pair[0]).into());
        }
    }
    match arguments.first().map(String::as_str) {
        Some("generate") => {
            let dimensions: Vec<u32> = option(&arguments, "--size")?
                .split(',')
                .map(str::parse)
                .collect::<Result<_, _>>()?;
            let [x, y, z] = dimensions.as_slice() else {
                return Err("size requires x,y,z".into());
            };
            let started = Instant::now();
            let world = World::generate(
                Cell {
                    x: *x,
                    y: *y,
                    z: *z,
                },
                seed(&arguments)?,
            )?;
            let generate_ns = started.elapsed().as_nanos();
            let started = Instant::now();
            let file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(option(&arguments, "--output")?)?;
            world.save(BufWriter::new(&file))?;
            file.sync_all()?;
            let save_ns = started.elapsed().as_nanos();
            println!(
                "{{\"event\":\"generated\",\"generate_ns\":{generate_ns},\"save_ns\":{save_ns},\"population\":{},\"revision\":{},\"size\":[{x},{y},{z}]}}",
                world.stats().non_empty,
                world.stats().revision
            );
        }
        Some("probe") => {
            let number =
                |name: &str, default: usize| -> Result<usize, Box<dyn std::error::Error>> {
                    let value = arguments
                        .windows(2)
                        .find(|pair| pair[0] == name)
                        .map_or(Ok(default), |pair| pair[1].parse())?;
                    if value > 1_000 || (name == "--samples" && value == 0) {
                        return Err(format!(
                            "{name} must be bounded by 1000; samples must be positive"
                        )
                        .into());
                    }
                    Ok(value)
                };
            let warmup = number("--warmup", 100)?;
            let samples = number("--samples", 1_000)?;
            let started = Instant::now();
            let world = World::load(BufReader::new(std::fs::File::open(option(
                &arguments, "--input",
            )?)?))?;
            let load_ns = started.elapsed().as_nanos();
            probe::run(world, load_ns, seed(&arguments)?, warmup, samples)?;
        }
        _ => return Err("usage: factory_world_probe generate|probe [options]".into()),
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
