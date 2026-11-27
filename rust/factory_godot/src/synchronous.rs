// Small synchronous proof of the factory boundary. All returned data is owned.
use factory_core::{
    belt_placement::{Builder, Direction},
    factory::{Factory, Ruleset},
    logistics::Settings,
    queries,
    world::{Block, Bounds, Cell},
};

fn cell(value: Vector3i) -> Cell {
    Cell::new(value.x, value.y, value.z)
}
fn vector(value: Cell) -> Vector3i {
    Vector3i::new(value.x, value.y, value.z)
}
fn direction(value: i64) -> Result<Direction, String> {
    match value {
        0 => Ok(Direction::South),
        1 => Ok(Direction::West),
        2 => Ok(Direction::North),
        3 => Ok(Direction::East),
        _ => Err("invalid_direction".into()),
    }
}
fn response(result: Result<(), String>) -> VarDictionary {
    match result {
        Ok(()) => vdict! { "ok" => true },
        Err(error) => vdict! { "ok" => false, "error" => error.as_str() },
    }
}

#[godot_api]
impl FactoryBackend {
    #[func]
    fn new_world_id(&self) -> GString { GString::from(&new_id()) }

    #[func]
    fn configure_persistence(&mut self, root:GString) -> VarDictionary {
        if self.runtime.as_ref().is_some_and(|r| !r.is_stopped()) {return save_error("runtime_busy");}
        if !self.backend.is_open() {return save_error("backend_closed");}
        if self.persistence.is_some() {return save_error("persistence_already_configured");}
        let path=std::path::PathBuf::from(root.to_string());
        if !path.is_absolute() {return save_error("save_root_must_be_absolute");}
        match Service::new(path) {
            Ok(service)=>{self.persistence=Some(service); vdict!{"ok"=>true}}
            Err(error)=>save_error(error),
        }
    }
    fn _io(&mut self, request:IoRequest) -> VarDictionary {
        if self.candidate.is_some() {return save_error("load_prepared");}
        match self.persistence.as_mut().ok_or(saves::Error::Invalid("persistence not configured"))
            .and_then(|s|s.submit(request)) {
            Ok(id)=>vdict!{"ok"=>true,"job_id"=>id as i64},
            Err(error)=>save_error(error),
        }
    }
    #[func]
    fn request_save_list(&mut self) -> VarDictionary {self._io(IoRequest::List)}

    #[func]
    fn request_save(&mut self, session:VarDictionary, options:VarDictionary) -> VarDictionary {
        if self.persistence.as_ref().is_none_or(|s|s.busy()) || self.candidate.is_some() {return save_error("persistence_busy");}
        let result=(|| -> Result<IoRequest,String> {
            let session=session_input(&session)?;
            let name:GString=input(&options,"name")?; let kind:GString=input(&options,"kind")?;
            let snapshot=saves::capture(self._factory()?,&session).map_err(|e|e.to_string())?;
            Ok(IoRequest::Save(Box::new(snapshot),SaveRequest {name:name.to_string(),
                overwrite:input(&options,"overwrite")?,kind:Kind::parse(&kind.to_string()).map_err(|e|e.to_string())?,
                retention:session.autosave_retention,
                expected_sequence:u64::try_from(input::<i64>(&options,"sequence")?).map_err(|_|"invalid_sequence")?}))
        })();
        match result {Ok(request)=>self._io(request),Err(error)=>save_error(error)}
    }
    #[func]
    fn request_load(&mut self, id:GString) -> VarDictionary {
        if parse_id(&id.to_string()).is_err() {return save_error("invalid_save_id");}
        self._io(IoRequest::Load(id.to_string()))
    }
    #[func]
    fn request_delete_save(&mut self, id:GString, sequence:i64) -> VarDictionary {
        if parse_id(&id.to_string()).is_err() || sequence<0 {return save_error("invalid_save_id_or_sequence");}
        self._io(IoRequest::Delete(id.to_string(),sequence as u64))
    }
    #[func]
    fn cancel_save_job(&mut self, id:i64) -> VarDictionary {
        if id<0 {return save_error("invalid_job_id");}
        if self.candidate.as_ref().is_some_and(|(job,_,_)|*job==id as u64) {
            self.candidate=None; return vdict!{"ok"=>true,"cancelled"=>true};
        }
        match self.persistence.as_mut().ok_or(saves::Error::Invalid("persistence not configured"))
            .and_then(|s|s.cancel(id as u64)) {
            Ok(cancelled)=>vdict!{"ok"=>true,"cancelled"=>cancelled},
            Err(error)=>save_error(error),
        }
    }
    #[func]
    fn poll_save_job(&mut self) -> VarDictionary {
        let Some(update)=self.persistence.as_mut().and_then(Service::poll) else {
            return vdict!{"ok"=>true,"active"=>false};
        };
        let Some(result)=update.result else {
            return vdict!{"ok"=>true,"active"=>true,"job_id"=>update.id as i64,"state"=>update.state.as_str()};
        };
        match result {
            Err(error)=>vdict!{"ok"=>false,"active"=>false,"job_id"=>update.id as i64,
                "state"=>update.state.as_str(),"error"=>error.to_string().as_str()},
            Ok(Output::Listed(directory))=>vdict!{"ok"=>true,"active"=>false,"job_id"=>update.id as i64,
                "state"=>"Completed","directory"=>&directory_dictionary(directory)},
            Ok(Output::Saved(entry))=>vdict!{"ok"=>true,"active"=>false,"job_id"=>update.id as i64,
                "state"=>"Completed","entry"=>&entry_dictionary(&entry)},
            Ok(Output::Deleted)=>vdict!{"ok"=>true,"active"=>false,"job_id"=>update.id as i64,"state"=>"Completed"},
            Ok(Output::Loaded(snapshot))=>match snapshot.restore() {
                Ok((factory,session))=>{
                    let observation=Self::_observe(&factory);
                    if !observation.get("ok").is_some_and(|v|v.try_to::<bool>().unwrap_or(false)) {
                        return vdict!{"ok"=>false,"active"=>false,"job_id"=>update.id as i64,
                            "state"=>"Failed","error"=>"candidate_observation_failed"};
                    }
                    let result=vdict!{"ok"=>true,"active"=>false,"job_id"=>update.id as i64,
                        "state"=>"Prepared","session"=>&session_dictionary(&session),"world"=>&observation};
                    self.candidate=Some((update.id,factory,session)); result
                }
                Err(error)=>vdict!{"ok"=>false,"active"=>false,"job_id"=>update.id as i64,"state"=>"Failed",
                    "error"=>error.to_string().as_str()},
            }
        }
    }
    #[func]
    fn commit_prepared_load(&mut self, id:i64) -> VarDictionary {
        if !self.candidate.as_ref().is_some_and(|(job,_,_)|*job==id as u64) {return save_error("invalid_prepared_load");}
        let (_,factory,session)=self.candidate.take().unwrap();
        self.route=None; self.factory=Some(factory);
        vdict!{"ok"=>true,"state"=>"Completed","session"=>&session_dictionary(&session)}
    }

    #[func]
    fn open_backend(&mut self, options: VarDictionary) -> VarDictionary {
        let result = (|| {
            if options.len() != 1 {
                return Err(Error::InvalidArgument);
            }
            let version = options.get("api_version").ok_or(Error::InvalidArgument)?
                .try_to::<i64>().map_err(|_| Error::InvalidArgument)?;
            self.backend.open(u32::try_from(version).map_err(|_| Error::InvalidArgument)?)
        })();
        match result {
            Ok(capabilities) => vdict! {
                "ok" => true, "is_open" => true,
                "capabilities" => &capabilities_dictionary(capabilities),
                "build" => &build_dictionary(),
            },
            Err(error) => vdict! {
                "ok" => false, "is_open" => self.backend.is_open(), "error" => error.code(),
            },
        }
    }

    #[func]
    fn close_backend(&mut self) -> VarDictionary {
        if let Some(runtime) = &self.runtime {
            runtime.close();
        }
        self.candidate = None;
        self.persistence = None;
        self.route = None;
        self.factory = None;
        self.backend.close();
        vdict! { "ok" => true, "is_open" => false }
    }

    fn _factory(&self) -> Result<&Factory, String> {
        self.factory.as_ref().ok_or("factory_not_created".into())
    }
    fn _factory_mut(&mut self) -> Result<&mut Factory, String> {
        self.factory.as_mut().ok_or("factory_not_created".into())
    }

    #[func]
    fn create_factory(&mut self, ruleset: GString) -> VarDictionary {
        response((|| {
            if self.runtime.as_ref().is_some_and(|r| !r.is_stopped()) {
                return Err("runtime_busy".into());
            }
            if self.candidate.is_some() || self.persistence.as_ref().is_some_and(|s|s.busy()) {
                return Err("persistence_busy".into());
            }
            if !self.backend.is_open() {
                return Err("backend_closed".into());
            }
            let ruleset = Ruleset::parse(&ruleset.to_string()).map_err(|e| format!("{e:?}"))?;
            let bounds = Bounds::new(Cell::new(-8, -3, -8), Cell::new(9, 12, 9), 3)
                .map_err(|e| format!("{e:?}"))?;
            let mut factory = Factory::new(
                bounds,
                Settings {
                    interval: 0.6,
                    amount: 1,
                },
                ruleset,
            )
            .map_err(|e| format!("{e:?}"))?;
            let additions = (0..6)
                .map(|z| {
                    let block = match z {
                        0 => Block::Miner,
                        5 => Block::Chest,
                        _ => Block::Belt,
                    };
                    (Cell::new(0, 0, z), block, Direction::South)
                })
                .collect::<Vec<_>>();
            let preview = factory.preview(&additions).map_err(|e| format!("{e:?}"))?;
            factory.commit(&preview).map_err(|e| format!("{e:?}"))?;
            self.factory = Some(factory);
            self.route = None;
            Ok(())
        })())
    }

    #[func]
    fn advance_factory(&mut self, delta: f64) -> VarDictionary {
        response(
            self._factory_mut()
                .and_then(|f| f.advance(delta).map_err(|e| format!("{e:?}"))),
        )
    }

    #[func]
    fn place_block(&mut self, at: Vector3i, block: i64, facing: i64) -> VarDictionary {
        response((|| {
            let block = u8::try_from(block).map_err(|_| "invalid_block")?;
            let block = Block::try_from(block).map_err(|e| format!("{e:?}"))?;
            if matches!(block, Block::Air | Block::Bedrock | Block::Structure) {
                return Err("unsupported_build_tool".into());
            }
            self._factory_mut()?
                .place(cell(at), block, direction(facing)?)
                .map_err(|e| format!("{e:?}"))
        })())
    }

    #[func]
    fn remove_block(&mut self, at: Vector3i) -> VarDictionary {
        response(
            self._factory_mut()
                .and_then(|f| f.remove(cell(at)).map_err(|e| format!("{e:?}"))),
        )
    }

    #[func]
    fn rotate_block(&mut self, at: Vector3i, facing: i64) -> VarDictionary {
        response((|| {
            self._factory_mut()?
                .set_direction(cell(at), direction(facing)?)
                .map_err(|e| format!("{e:?}"))
        })())
    }

    fn _route_response(&self, error: Option<String>) -> VarDictionary {
        let mut cells = PackedVector3Array::new();
        let mut blocks = PackedInt32Array::new();
        let mut directions = PackedInt32Array::new();
        let mut existing = PackedInt32Array::new();
        let mut locked_points = PackedVector3Array::new();
        let mut active = false;
        let mut north_south_first = true;
        if let Some(route) = &self.route {
            active = route.active();
            north_south_first = route.north_south_first();
            for segment in route.path() {
                let at = segment.cell;
                cells.push(Vector3::new(at.x as f32, at.y as f32, at.z as f32));
                blocks.push(i32::from(segment.block as u8));
                directions.push(i32::from(segment.direction as u8));
                existing.push(self.factory.as_ref().map_or(0, |f| i32::from(f.world().block(at) as u8)));
            }
            for at in route.locked_points() {
                locked_points.push(Vector3::new(at.x as f32, at.y as f32, at.z as f32));
            }
        }
        vdict! {
            "ok" => error.is_none(), "error" => error.as_deref().unwrap_or(""),
            "active" => active, "north_south_first" => north_south_first,
            "cells" => &cells, "blocks" => &blocks, "directions" => &directions,
            "existing" => &existing, "locked_points" => &locked_points,
        }
    }

    #[func]
    fn begin_belt_route(&mut self, at: Vector3i, facing: i64) -> VarDictionary {
        let result: Result<(), String> = (|| {
            let preferred = direction(facing)?;
            let factory = self._factory()?;
            let directions = factory.observe().map_err(|e| format!("{e:?}"))?.machines
                .into_iter().map(|row| (row.cell, row.direction))
                .collect::<std::collections::BTreeMap<_, _>>();
            let mut builder = Builder::new(factory_core::route::MAX_ROUTE_CELLS)
                .map_err(|e| format!("{e:?}"))?;
            builder.begin(factory.world(), &|cell| directions.get(&cell).copied(), cell(at), preferred)
                .map_err(|e| format!("{e:?}"))?;
            self.route = Some(builder);
            Ok(())
        })();
        self._route_response(result.err())
    }

    #[func]
    fn preview_belt_route(&mut self, target: Variant, facing: i64) -> VarDictionary {
        let result: Result<(), String> = (|| {
            let preferred = direction(facing)?;
            let target = if target.is_nil() { None } else {
                Some(cell(target.try_to::<Vector3i>().map_err(|_| "invalid_target")?))
            };
            let factory = self.factory.as_ref().ok_or("factory_not_created")?;
            let directions = factory.observe().map_err(|e| format!("{e:?}"))?.machines
                .into_iter().map(|row| (row.cell, row.direction))
                .collect::<std::collections::BTreeMap<_, _>>();
            self.route.as_mut().ok_or("route_inactive")?
                .preview(factory.world(), &|cell| directions.get(&cell).copied(), target, preferred)
                .map_err(|e| format!("{e:?}"))
        })();
        self._route_response(result.err())
    }

    #[func]
    fn lock_belt_route(&mut self) -> VarDictionary {
        let result: Result<(), String> = (|| {
            let factory = self.factory.as_ref().ok_or("factory_not_created")?;
            let directions = factory.observe().map_err(|e| format!("{e:?}"))?.machines
                .into_iter().map(|row| (row.cell, row.direction))
                .collect::<std::collections::BTreeMap<_, _>>();
            self.route.as_mut().ok_or("route_inactive")?
                .lock(factory.world(), &|cell| directions.get(&cell).copied())
                .map_err(|e| format!("{e:?}"))
        })();
        self._route_response(result.err())
    }

    #[func]
    fn toggle_belt_route_order(&mut self) -> VarDictionary {
        let error = match self.route.as_mut() {
            Some(route) if route.active() => { route.toggle_order(); None }
            _ => Some("route_inactive".into()),
        };
        self._route_response(error)
    }

    #[func]
    fn commit_belt_route(&mut self) -> VarDictionary {
        let result: Result<(), String> = (|| {
            let factory = self.factory.as_mut().ok_or("factory_not_created")?;
            let route = self.route.as_ref().ok_or("route_inactive")?;
            let preview = factory.preview_route(route).map_err(|e| format!("{e:?}"))?;
            factory.commit(&preview).map_err(|e| format!("{e:?}"))?;
            self.route = None;
            Ok(())
        })();
        self._route_response(result.err())
    }

    #[func]
    fn cancel_belt_route(&mut self) -> VarDictionary {
        self.route = None;
        if let Some(factory) = self.factory.as_mut() {
            factory.cancel_preview();
        }
        self._route_response(None)
    }

    #[func]
    fn cast_ray(&self, origin: Vector3, ray: Vector3, distance: f64) -> VarDictionary {
        let factory = match self._factory() {
            Ok(factory) => factory,
            Err(error) => return vdict! { "ok" => false, "error" => error.as_str() },
        };
        let hit = queries::cast(
            factory.world(),
            [
                f64::from(origin.x),
                f64::from(origin.y),
                f64::from(origin.z),
            ],
            [f64::from(ray.x), f64::from(ray.y), f64::from(ray.z)],
            distance,
        );
        match hit {
            Some(hit) => vdict! {
                "ok" => true, "hit" => true, "cell" => vector(hit.cell),
                "normal" => vector(hit.normal), "distance" => hit.distance,
                "position" => Vector3::new(hit.position[0] as f32, hit.position[1] as f32, hit.position[2] as f32),
            },
            None => vdict! { "ok" => true, "hit" => false },
        }
    }

    #[func]
    fn observe_factory(&self) -> VarDictionary {
        match self._factory() {
            Ok(factory) => Self::_observe(factory),
            Err(error) => vdict! { "ok" => false, "error" => error.as_str() },
        }
    }

    fn _observe(factory: &Factory) -> VarDictionary {
        let result: Result<VarDictionary, String> = (|| {
            let state = factory.observe().map_err(|e| format!("{e:?}"))?;
            let ledger = factory.ledger();
            let mut machines = Array::<VarDictionary>::new();
            let mut ores = PackedVector3Array::new();
            for row in state.machines {
                let mut inputs = PackedInt32Array::new();
                let mut outputs = PackedInt32Array::new();
                for port in row.input_ports.into_iter().flatten() { inputs.push(i32::from(port as u8)); }
                for port in row.output_ports.into_iter().flatten() { outputs.push(i32::from(port as u8)); }
                machines.push(&vdict! {
                    "cell" => vector(row.cell), "block" => i64::from(row.block as u8),
                    "direction" => i64::from(row.direction as u8), "quantity" => row.quantity,
                    "inputs" => &inputs, "outputs" => &outputs,
                });
                for ore in row.ores {
                    let p = ore.position(row.cell, row.block);
                    ores.push(Vector3::new(
                        p[0] as f32, p[1] as f32, p[2] as f32,
                    ));
                }
            }
            // M05 deliberately exports this fixed small world in one batch.
            let world = factory.world();
            let bounds = world.bounds();
            let mut cells = PackedVector3Array::new();
            let mut blocks = PackedInt32Array::new();
            for y in bounds.minimum().y..bounds.maximum().y {
                for z in bounds.minimum().z..bounds.maximum().z {
                    for x in bounds.minimum().x..bounds.maximum().x {
                        let at = Cell::new(x, y, z);
                        let block = world.block(at);
                        if block != Block::Air {
                            cells.push(Vector3::new(x as f32, y as f32, z as f32));
                            blocks.push(i32::from(block as u8));
                        }
                    }
                }
            }
            Ok(vdict! {
                "ok" => true, "ruleset" => factory.ruleset().name(),
                "revision" => factory.revision() as i64, "tick" => state.tick,
                "cells" => &cells, "blocks" => &blocks, "machines" => &machines,
                "ores" => &ores, "initial" => ledger.initial,
                "produced" => ledger.produced, "removed" => ledger.removed,
            })
        })();
        match result {
            Ok(value) => value,
            Err(error) => vdict! { "ok" => false, "error" => error.as_str() },
        }
    }
}
