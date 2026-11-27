//! The first bridge contract advertises only operations it implements.
pub const API_VERSION: u32 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Capabilities {
    pub api_version: u32,
    pub features: Vec<&'static str>,
    pub rulesets: Vec<&'static str>,
    pub background: bool,
    pub persistence: bool,
}

pub fn implemented_capabilities() -> Capabilities {
    Capabilities {
        api_version: API_VERSION,
        features: vec!["handshake", "synchronous_factory", "checkpoint_jobs"],
        rulesets: vec!["legacy_discrete_v1", "conveyor_continuous_v1"],
        background: false,
        persistence: true,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidArgument,
    UnsupportedProtocol,
    AlreadyOpen,
}

impl Error {
    pub fn code(self) -> &'static str {
        match self {
            Self::InvalidArgument => "invalid_argument",
            Self::UnsupportedProtocol => "unsupported_protocol",
            Self::AlreadyOpen => "already_open",
        }
    }
}

#[derive(Default)]
pub struct Backend {
    is_open: bool,
}

impl Backend {
    pub fn open(&mut self, api_version: u32) -> Result<Capabilities, Error> {
        if api_version != API_VERSION {
            return Err(Error::UnsupportedProtocol);
        }
        if self.is_open {
            return Err(Error::AlreadyOpen);
        }
        self.is_open = true;
        Ok(implemented_capabilities())
    }

    pub fn is_open(&self) -> bool {
        self.is_open
    }

    pub fn close(&mut self) {
        self.is_open = false;
    }
}
