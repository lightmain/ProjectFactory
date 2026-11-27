// Only player/session values cross the engine boundary. Complete worlds stay Rust-owned.
use factory_core::persistence::{
    self as saves, Session, Player, jobs::{Service, Request as IoRequest, Output},
    store::{Kind, SaveRequest, Entry, Directory, parse_id, hex, new_id},
};

fn save_error(error: impl std::fmt::Display) -> VarDictionary {
    vdict! {"ok"=>false,"error"=>error.to_string().as_str()}
}
fn player_dictionary(p: &Player) -> VarDictionary {
    let v=|a:[f64;3]|Vector3::new(a[0] as f32,a[1] as f32,a[2] as f32);
    vdict! {"frame"=>p.frame as i64,"position"=>v(p.position),"velocity"=>v(p.velocity),
        "spawn"=>v(p.spawn),"body_rotation"=>v(p.body_rotation),"rotation"=>v(p.view_rotation),
        "tool"=>i64::from(p.tool),"build_rotation"=>i64::from(p.build_rotation),
        "free_view"=>p.free_view,"free_position"=>v(p.free_position),"free_rotation"=>v(p.free_rotation)}
}
fn session_dictionary(s: &Session) -> VarDictionary {
    vdict! {"world_id"=>hex(&s.world_id).as_str(),"world_name"=>s.world_name.as_str(),
        "autosave_minutes"=>s.autosave_minutes,"autosave_retention"=>i64::from(s.autosave_retention),
        "player"=>&player_dictionary(&s.player)}
}
fn entry_dictionary(e: &Entry) -> VarDictionary {
    vdict! {"id"=>e.id.as_str(),"name"=>e.name.as_str(),"world_id"=>hex(&e.world_id).as_str(),
        "world_name"=>e.world_name.as_str(),"ruleset"=>e.ruleset.name(),
        "saved_at"=>e.saved_at,"kind"=>e.kind.name(),"version"=>5i64}
}
fn directory_dictionary(d: Directory) -> VarDictionary {
    let records=Array::<VarDictionary>::from_iter(d.entries.iter().map(entry_dictionary));
    vdict! {"sequence"=>d.sequence as i64,"records"=>&records}
}
fn input<T: FromGodot>(dictionary:&VarDictionary,key:&str) -> Result<T,String> {
    dictionary.get(key).ok_or_else(||format!("missing_{key}"))?
        .try_to::<T>().map_err(|_|format!("invalid_{key}"))
}
fn player_input(d:&VarDictionary) -> Result<Player,String> {
    let v=|key| -> Result<[f64;3],String> {
        let v:Vector3=input(d,key)?; Ok([f64::from(v.x),f64::from(v.y),f64::from(v.z)])
    };
    Ok(Player {frame:u64::try_from(input::<i64>(d,"frame")?).map_err(|_|"invalid_frame")?,
        position:v("position")?,velocity:v("velocity")?,spawn:v("spawn")?,
        body_rotation:v("body_rotation")?,view_rotation:v("rotation")?,
        tool:u8::try_from(input::<i64>(d,"tool")?).map_err(|_|"invalid_tool")?,
        build_rotation:u8::try_from(input::<i64>(d,"build_rotation")?).map_err(|_|"invalid_rotation")?,
        free_view:input(d,"free_view")?,free_position:v("free_position")?,free_rotation:v("free_rotation")?})
}
fn session_input(d:&VarDictionary) -> Result<Session,String> {
    let world_id:GString=input(d,"world_id")?; let name:GString=input(d,"world_name")?;
    let s=Session {world_id:parse_id(&world_id.to_string()).map_err(|e|e.to_string())?,
        world_name:name.to_string(),autosave_minutes:input(d,"autosave_minutes")?,
        autosave_retention:u32::try_from(input::<i64>(d,"autosave_retention")?).map_err(|_|"invalid_retention")?,
        player:player_input(&input::<VarDictionary>(d,"player")?)?};
    s.validate().map_err(|e|e.to_string())?; Ok(s)
}
