use std::sync::Arc;

use ente_accounts::{AccountsClient, AccountsClientConfig, login as upstream};
use tokio::sync::Mutex;
use zeroize::Zeroizing;

use crate::{BridgeError, Config, LoginStep, types::StoredAccount};

#[derive(uniffi::Object)]
pub struct LoginFlow {
    config: Config,
    client: AccountsClient,
    prepared: Mutex<Option<(String, upstream::LoginFlow)>>,
}

#[uniffi::export]
impl LoginFlow {
    #[uniffi::constructor]
    pub fn new(config: Config) -> Result<Arc<Self>, BridgeError> {
        let config = config.validate()?;
        let client = AccountsClient::new(
            AccountsClientConfig::new(&config.client_package)
                .with_origin(&config.api_origin)
                .with_user_agent(&config.user_agent),
        )?;
        Ok(Arc::new(Self {
            config,
            client,
            prepared: Mutex::new(None),
        }))
    }

    #[uniffi::method(async_runtime = "tokio")]
    pub async fn prepare(&self, email: String) -> Result<LoginStep, BridgeError> {
        let email = email.trim().to_lowercase();
        if email.is_empty() {
            return Err(BridgeError::unsupported("Email is empty"));
        }
        let mut prepared = self.prepared.lock().await;
        let (flow, step) = upstream::LoginFlow::start(&self.client, email.clone()).await?;
        let step = self.step(step, &email)?;
        *prepared = Some((email, flow));
        Ok(step)
    }

    #[uniffi::method(async_runtime = "tokio")]
    pub async fn submit_password(&self, password: String) -> Result<LoginStep, BridgeError> {
        let password = Zeroizing::new(password);
        let mut prepared = self.prepared.lock().await;
        let (email, flow) = prepared
            .as_mut()
            .ok_or_else(|| BridgeError::unsupported("Prepare login first"))?;
        let step = flow.submit_password(&self.client, &password).await?;
        self.step(step, email)
    }

    #[uniffi::method(async_runtime = "tokio")]
    pub async fn submit_code(&self, code: String) -> Result<LoginStep, BridgeError> {
        let code = Zeroizing::new(code);
        let mut prepared = self.prepared.lock().await;
        let (email, flow) = prepared
            .as_mut()
            .ok_or_else(|| BridgeError::unsupported("Prepare login first"))?;
        let step = flow.submit_code(&self.client, &code).await?;
        self.step(step, email)
    }

    #[uniffi::method(async_runtime = "tokio")]
    pub async fn resend_code(&self) -> Result<(), BridgeError> {
        let prepared = self.prepared.lock().await;
        let (_, flow) = prepared
            .as_ref()
            .ok_or_else(|| BridgeError::unsupported("Prepare login first"))?;
        flow.resend_code(&self.client).await?;
        Ok(())
    }
}

impl LoginFlow {
    fn step(&self, step: upstream::LoginStep, email: &str) -> Result<LoginStep, BridgeError> {
        Ok(match step {
            upstream::LoginStep::EmailCode => LoginStep::EmailCode,
            upstream::LoginStep::Password => LoginStep::Password,
            upstream::LoginStep::SecondFactor { totp: true, .. } => LoginStep::AuthenticatorCode,
            upstream::LoginStep::SecondFactor {
                totp: false,
                passkey: true,
            } => LoginStep::PasskeyUnsupported,
            upstream::LoginStep::SecondFactor {
                totp: false,
                passkey: false,
            } => return Err(BridgeError::internal("Missing second factor")),
            upstream::LoginStep::Complete(mut account) => {
                let recovery = Zeroizing::new(
                    account
                        .recovery_key
                        .take()
                        .ok_or_else(|| BridgeError::unsupported("Account has no recovery key"))?,
                );
                let recovery_key =
                    ente_accounts::auth::recovery_key_from_mnemonic_or_hex(&recovery)?.into_vec();
                LoginStep::Complete {
                    session: StoredAccount {
                        api_origin: self.config.api_origin.clone(),
                        email: email.into(),
                        user_id: account.user_id,
                        token: std::mem::take(&mut account.secrets.token),
                        master_key: std::mem::take(&mut account.secrets.master_key),
                        secret_key: std::mem::take(&mut account.secrets.secret_key),
                        recovery_key,
                    }
                    .encode()?,
                }
            }
        })
    }
}
