//! Exhaustive small-height inputs from the current Godot implementation.
use factory_core::{
    route::{Error, fit_heights, footprint},
    world::Cell,
};
use std::collections::BTreeSet;

#[test]
fn godot_footprints_and_small_height_profiles_match() {
    let path = std::env::var("FACTORY_ROUTE_ORACLE").expect("fresh Godot routes required");
    let observations = std::fs::read_to_string(path).unwrap();
    let mut expected = BTreeSet::new();
    for x in -3..=3 {
        for z in -3..=3 {
            for north in [0, 1] {
                expected.insert(format!("footprint {x} {z} {north}"));
            }
        }
    }
    expected.insert("footprint 1000 0 1".to_owned());
    expected.extend((0..4).map(|index| format!("invalid {index}")));
    for length in 1..=5_u32 {
        for code in 0..3_u32.pow(length) {
            for mask in 0..1 << (length - 1) {
                for start in -1..=1 {
                    for end in -1..=1 {
                        expected.insert(format!("fit {length} {code} {mask} {start} {end}"));
                    }
                }
            }
        }
    }
    let mut seen = BTreeSet::new();
    for line in observations.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        assert!(
            fields.len() == 3 || fields.len() == 5 || fields.len() == 7,
            "invalid route record"
        );
        let key = fields[..fields.len() - 1].join(" ");
        assert!(expected.contains(&key), "unknown route input: {line}");
        assert!(seen.insert(key), "duplicate route input: {line}");
        let number = |index: usize| fields[index].parse::<i32>().unwrap();
        match fields[0] {
            "invalid" => {
                assert_eq!(fields.len(), 3);
                assert_eq!(fields[2], "none");
                let (floors, capacities): (&[i32], &[u8]) = match number(1) {
                    0 => (&[], &[]),
                    1 => (&[0, 0], &[]),
                    // Negative signed capacities are rejected at the typed
                    // boundary; their unsigned encoding is also invalid.
                    2 => (&[0, 0], &[u8::MAX]),
                    3 => (&[0, 0], &[2]),
                    _ => unreachable!(),
                };
                assert_eq!(
                    fit_heights(floors, capacities, 0, 0),
                    Err(Error::InvalidHeights)
                );
            }
            "footprint" => {
                assert_eq!(fields.len(), 5);
                let actual = footprint(
                    Cell::new(-5, 7, -6),
                    Cell::new(-5 + number(1), 17, -6 + number(2)),
                    number(3) == 1,
                    1001,
                )
                .unwrap();
                let reference: Vec<Cell> = fields[4]
                    .split(';')
                    .map(|value| {
                        let axes: Vec<i32> =
                            value.split(',').map(|axis| axis.parse().unwrap()).collect();
                        assert_eq!(axes.len(), 3);
                        Cell::new(axes[0], axes[1], axes[2])
                    })
                    .collect();
                assert_eq!(actual, reference, "{line}");
            }
            "fit" => {
                assert_eq!(fields.len(), 7);
                let mut code = number(2);
                let floors: Vec<i32> = (0..number(1))
                    .map(|_| {
                        let floor = code % 3 - 1;
                        code /= 3;
                        floor
                    })
                    .collect();
                let capacities: Vec<u8> = (0..number(1) - 1)
                    .map(|index| ((number(3) >> index) & 1) as u8)
                    .collect();
                let actual = fit_heights(&floors, &capacities, number(4), number(5));
                if fields[6] == "none" {
                    assert_eq!(actual, Err(Error::NoRoute), "{line}");
                } else {
                    let reference: Vec<i32> = fields[6]
                        .split(',')
                        .map(|height| height.parse().unwrap())
                        .collect();
                    assert_eq!(actual.unwrap(), reference, "{line}");
                }
            }
            _ => panic!("unknown route record"),
        }
    }
    assert_eq!(seen, expected, "missing route samples");
    assert_eq!(seen.len(), 42088);
}
