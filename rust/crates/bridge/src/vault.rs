use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, RwLock},
};

use ente_auth::code::{Code, Kind};
use ente_core::{
    Session, b64,
    crypto::{Key, SecretKey, kdf, secretbox},
    http::{ApiConfig, Auth},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Mutex;
use zeroize::Zeroizing;

use crate::{BridgeError, CodeKind, CodeView, Config, Display, SyncSummary, types::StoredAccount};

struct Record {
    code: Code,
    period_secs: u64,
    display: Display,
    uri: Zeroizing<String>,
}

#[derive(Default)]
struct VaultData {
    since: i64,
    unreadable: BTreeSet<String>,
    records: BTreeMap<String, Record>,
}

#[derive(Serialize, Deserialize)]
struct Cache {
    version: u8,
    since: i64,
    unreadable: BTreeSet<String>,
    records: BTreeMap<String, String>,
}

impl Drop for Cache {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        for uri in self.records.values_mut() {
            uri.zeroize();
        }
    }
}

impl Cache {
    fn open(bytes: &[u8], key: &Key) -> Option<VaultData> {
        let plaintext = Zeroizing::new(secretbox::decrypt_combined(bytes, key).ok()?);
        let cache: Self = serde_json::from_slice(&plaintext).ok()?;
        if cache.version != 1 {
            return None;
        }
        let records = cache
            .records
            .iter()
            .map(|(id, uri)| Ok((id.clone(), Record::from_uri(Zeroizing::new(uri.clone()))?)))
            .collect::<Result<_, BridgeError>>()
            .ok()?;
        Some(VaultData {
            since: cache.since,
            unreadable: cache.unreadable.clone(),
            records,
        })
    }
}

enum Change {
    Upsert(Box<Record>),
    Delete,
    Unreadable,
}

#[derive(uniffi::Object)]
pub struct Vault {
    session: Session,
    sync_key: Mutex<Option<Key>>,
    data: RwLock<VaultData>,
    cache_key: Key,
    email: String,
}

#[uniffi::export]
impl Vault {
    #[uniffi::constructor]
    pub fn new(
        config: Config,
        session: Vec<u8>,
        cache: Option<Vec<u8>>,
    ) -> Result<Arc<Self>, BridgeError> {
        let config = config.validate()?;
        let account = StoredAccount::decode(session)?;
        if config.api_origin != account.api_origin {
            return Err(BridgeError::unsupported(
                "Stored account belongs to a different API origin",
            ));
        }
        let api = ApiConfig {
            origin: config.api_origin,
            client_package: Some(config.client_package),
            client_version: None,
            user_agent: Some(config.user_agent),
            auth: Some(Auth::User(b64::encode_url_safe(&account.token))),
        };
        let session = Session::new(
            api,
            account.user_id,
            Key::try_from_slice(&account.master_key)?,
            Key::try_from_slice(&account.recovery_key)?,
            SecretKey::try_from_slice(&account.secret_key)?,
        )?;
        let cache_key = Key::try_from_slice(&kdf::derive_subkey(
            &session.master_key,
            Key::BYTES,
            1,
            b"EMBcache",
        )?)?;
        let data = cache
            .as_deref()
            .and_then(|bytes| Cache::open(bytes, &cache_key))
            .unwrap_or_default();
        Ok(Arc::new(Self {
            session,
            sync_key: Mutex::new(None),
            data: RwLock::new(data),
            cache_key,
            email: account.email.clone(),
        }))
    }

    #[uniffi::method(async_runtime = "tokio")]
    pub async fn logout(&self) -> Result<(), BridgeError> {
        self.session
            .api
            .post("/users/logout")
            .json(&serde_json::json!({}))
            .send()
            .await?
            .error_for_code()
            .await?;
        Ok(())
    }

    #[uniffi::method(async_runtime = "tokio")]
    pub async fn sync(&self) -> Result<SyncSummary, BridgeError> {
        let mut key_guard = self.sync_key.lock().await;
        if key_guard.is_none() {
            *key_guard = ente_auth::fetch_key(&self.session)
                .await?
                .map(|wrapped| ente_auth::open_key(&wrapped, &self.session.master_key))
                .transpose()?;
        }
        let mut summary = SyncSummary {
            upserted: 0,
            deleted: 0,
            total: 0,
            unreadable: 0,
            has_authenticator_key: key_guard.is_some(),
        };
        if let Some(key) = key_guard.as_ref() {
            let mut since = self.data.read().unwrap().since;
            loop {
                let page = ente_auth::diff(&self.session, since).await?;
                let full = page.len() == ente_auth::PAGE_SIZE;
                let mut cursor = since;
                let mut changes = Vec::with_capacity(page.len());
                for entity in page {
                    cursor = cursor.max(entity.updated_at);
                    let change = if entity.is_deleted {
                        Change::Delete
                    } else {
                        Record::open(&entity, key).map_or(Change::Unreadable, |record| {
                            Change::Upsert(Box::new(record))
                        })
                    };
                    changes.push((entity.id.to_string(), change));
                }
                if full && cursor <= since {
                    return Err(BridgeError::internal("Authenticator diff did not advance"));
                }
                {
                    let mut data = self
                        .data
                        .write()
                        .map_err(|_| BridgeError::internal("Vault lock failed"))?;
                    for (id, change) in changes {
                        match change {
                            Change::Upsert(record) => {
                                data.unreadable.remove(&id);
                                data.records.insert(id, *record);
                                summary.upserted += 1;
                            }
                            Change::Delete => {
                                data.unreadable.remove(&id);
                                data.records.remove(&id);
                                summary.deleted += 1;
                            }
                            Change::Unreadable => {
                                data.records.remove(&id);
                                data.unreadable.insert(id);
                            }
                        }
                    }
                    data.since = cursor;
                }
                since = cursor;
                if !full {
                    break;
                }
            }
        }
        let data = self
            .data
            .read()
            .map_err(|_| BridgeError::internal("Vault lock failed"))?;
        summary.unreadable = data.unreadable.len() as u64;
        summary.total = data.records.len() as u64;
        Ok(summary)
    }

    pub fn email(&self) -> String {
        self.email.clone()
    }

    pub fn unreadable_count(&self) -> u64 {
        self.data.read().unwrap().unreadable.len() as u64
    }

    pub fn export_cache(&self) -> Vec<u8> {
        let data = self.data.read().unwrap();
        let cache = Cache {
            version: 1,
            since: data.since,
            unreadable: data.unreadable.clone(),
            records: data
                .records
                .iter()
                .map(|(id, record)| (id.clone(), record.uri.to_string()))
                .collect(),
        };
        let plaintext = Zeroizing::new(
            serde_json::to_vec(&cache)
                .expect("Cache contains only serializable strings and integers"),
        );
        secretbox::encrypt_combined(&plaintext, &self.cache_key)
    }

    pub fn codes(&self, now_unix_ms: i64) -> Result<Vec<CodeView>, BridgeError> {
        let now = u64::try_from(now_unix_ms)
            .map_err(|_| BridgeError::unsupported("Time must be at or after the Unix epoch"))?;
        let data = self
            .data
            .read()
            .map_err(|_| BridgeError::internal("Vault lock failed"))?;
        data.records
            .iter()
            .map(|(id, record)| {
                let kind = match record.code.kind {
                    Kind::Totp => CodeKind::Totp,
                    Kind::Steam => CodeKind::Steam,
                    Kind::Hotp => CodeKind::Hotp,
                };
                let (current, next, remaining_ms) = if kind == CodeKind::Hotp {
                    (String::new(), String::new(), 0)
                } else {
                    let (current, until) = record.code.generate(now / 1000)?;
                    let next = record.code.generate(until)?.0;
                    let until_ms = until.checked_mul(1000).ok_or_else(|| {
                        BridgeError::internal("Code validity exceeds supported time range")
                    })?;
                    (current, next, until_ms - now)
                };
                Ok(CodeView {
                    id: id.clone(),
                    issuer: record.code.issuer.clone(),
                    account: record.code.account_name.clone(),
                    kind,
                    current,
                    next,
                    period_secs: record.period_secs,
                    remaining_ms,
                    display: record.display.clone(),
                })
            })
            .collect()
    }
}

impl Record {
    fn open(entity: &ente_auth::Entity, key: &Key) -> Result<Self, BridgeError> {
        let uri = ente_auth::record::uri_line(
            entity.encrypted_data.as_deref(),
            entity.header.as_deref(),
            key,
        )?;
        Self::from_uri(uri)
    }

    fn from_uri(uri: Zeroizing<String>) -> Result<Self, BridgeError> {
        let code = Code::from_uri(&uri)?;
        let normalized = Zeroizing::new(uri.trim_end().replace('#', "%23"));
        let parsed = url::Url::parse(&normalized)
            .map_err(|_| BridgeError::internal("Invalid authenticator URI"))?;
        let display_json = Zeroizing::new(
            parsed
                .query_pairs()
                .filter(|(name, _)| name == "codeDisplay")
                .last()
                .map(|(_, value)| value.into_owned())
                .unwrap_or_default(),
        );
        let fields = serde_json::Deserializer::from_str(&display_json)
            .into_iter::<Value>()
            .next()
            .and_then(Result::ok)
            .unwrap_or_default();
        let text = |name: &str| {
            fields
                .get(name)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let display = Display {
            pinned: fields
                .get("pinned")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            trashed: code.trashed,
            tags: fields
                .get("tags")
                .and_then(Value::as_array)
                .map(|tags| {
                    tags.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default(),
            note: text("note"),
            icon_src: text("iconSrc"),
            icon_id: text("iconID"),
            tap_count: fields.get("tapCount").and_then(Value::as_i64).unwrap_or(0),
            last_used_at: fields
                .get("lastUsedAt")
                .and_then(Value::as_i64)
                .unwrap_or(0),
        };
        let period_secs = match code.kind {
            Kind::Hotp => 0,
            Kind::Steam => {
                code.generate(0)?;
                30
            }
            Kind::Totp => code.generate(0)?.1,
        };
        if period_secs > u64::MAX / 1000 {
            return Err(BridgeError::unsupported(
                "Authenticator period is too large",
            ));
        }
        Ok(Self {
            code,
            period_secs,
            display,
            uri,
        })
    }
}
