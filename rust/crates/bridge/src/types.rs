use crate::BridgeError;
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

#[derive(Clone, Debug, uniffi::Record)]
pub struct Config {
    pub api_origin: String,
    pub client_package: String,
    pub user_agent: String,
}

impl Config {
    pub(crate) fn validate(mut self) -> Result<Self, BridgeError> {
        let url = url::Url::parse(&self.api_origin)
            .map_err(|_| BridgeError::unsupported("Invalid API origin"))?;
        let transport_ok = match (url.scheme(), url.host()) {
            ("https", Some(_)) => true,
            ("http", Some(url::Host::Domain(host))) => host == "localhost",
            ("http", Some(url::Host::Ipv4(ip))) => ip.is_loopback(),
            ("http", Some(url::Host::Ipv6(ip))) => ip.is_loopback(),
            _ => false,
        };
        if !transport_ok
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(BridgeError::unsupported("Invalid API origin"));
        }
        if !self.client_package.starts_with("io.ente.auth") {
            return Err(BridgeError::unsupported(
                "Client package must start with io.ente.auth",
            ));
        }
        self.api_origin = url.as_str().trim_end_matches('/').to_owned();
        Ok(self)
    }
}

#[derive(Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
pub(crate) struct StoredAccount {
    pub api_origin: String,
    pub email: String,
    pub user_id: i64,
    pub token: Vec<u8>,
    pub master_key: Vec<u8>,
    pub secret_key: Vec<u8>,
    pub recovery_key: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "version", content = "account")]
enum SessionEnvelope {
    #[serde(rename = "1")]
    V1(StoredAccount),
}

impl StoredAccount {
    pub(crate) fn encode(self) -> Result<Vec<u8>, BridgeError> {
        serde_json::to_vec(&SessionEnvelope::V1(self))
            .map_err(|_| BridgeError::internal("Unable to store session"))
    }

    pub(crate) fn decode(bytes: Vec<u8>) -> Result<Self, BridgeError> {
        let bytes = Zeroizing::new(bytes);
        let SessionEnvelope::V1(account) = serde_json::from_slice(&bytes)
            .map_err(|_| BridgeError::unsupported("Invalid stored session"))?;
        Ok(account)
    }
}

#[derive(Clone, uniffi::Enum)]
pub enum LoginStep {
    EmailCode,
    Password,
    AuthenticatorCode,
    PasskeyUnsupported,
    Complete { session: Vec<u8> },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CodeKind {
    Totp,
    Steam,
    Hotp,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct Display {
    pub pinned: bool,
    pub trashed: bool,
    pub tags: Vec<String>,
    pub note: String,
    pub icon_src: String,
    pub icon_id: String,
    pub tap_count: i64,
    pub last_used_at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CodeView {
    pub id: String,
    pub issuer: String,
    pub account: String,
    pub kind: CodeKind,
    pub current: String,
    pub next: String,
    pub period_secs: u64,
    pub remaining_ms: u64,
    pub display: Display,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SyncSummary {
    pub upserted: u64,
    pub deleted: u64,
    pub total: u64,
    pub unreadable: u64,
    pub has_authenticator_key: bool,
}
