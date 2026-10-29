use ente_core::{
    b64,
    crypto::{Key, blob, secretbox, stream::Encryptor},
    http::Api,
};
use ente_test_support::TestResult;
use serde_json::{Value, json};
use url::Url;

pub async fn seed(api: &Api, master_key: &[u8]) -> TestResult<Vec<String>> {
    let key = Key::generate();
    let wrapped = secretbox::encrypt(key.as_bytes(), &Key::try_from_slice(master_key)?);
    api.post("/authenticator/key")
        .json(&json!({
            "encryptedKey": b64::encode(&wrapped.encrypted_data),
            "header": b64::encode(wrapped.nonce.as_bytes())
        }))
        .send()
        .await?
        .error_for_code()
        .await?;
    let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
    let display = json!({
        "pinned": true, "trashed": false, "tags": ["work", "comma, + # 😀"],
        "note": "literal%2C, + # 😀", "iconSrc": "custom", "iconID": "saved",
        "tapCount": 7, "lastUsedAt": 123456, "position": 45, "future": {"unknown": true}
    });
    let mut primary = Url::parse(&format!(
        "otpauth://totp/RFC:alice?secret={secret}&issuer=RFC&digits=6&period=30&algorithm=SHA1"
    ))?;
    primary
        .query_pairs_mut()
        .append_pair("codeDisplay", &display.to_string());
    let mut trashed = Url::parse(&format!("otpauth://totp/Trash:alice?secret={secret}"))?;
    trashed
        .query_pairs_mut()
        .append_pair("codeDisplay", r#"{"trashed":true}"#);
    let values = [
        json!(primary.as_str()),
        json!(
            "otpauth://totp/SHA256:alice?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA&algorithm=SHA256&digits=8&period=30"
        ),
        json!(format!("otpauth://steam/Steam:alice?secret={secret}")),
        json!(trashed.as_str()),
        json!({"rawData": format!("otpauth://totp/Legacy:alice?secret={secret}&period=60"), "display": display}),
        json!(format!(
            "otpauth://hotp/Counter:alice?secret={secret}&counter=12"
        )),
    ];
    let mut ids = Vec::new();
    for (index, value) in values.into_iter().enumerate() {
        let plaintext = serde_json::to_vec(&value)?;
        let (data, header) = if index == 4 {
            let mut stream = Encryptor::new(&key);
            let data = stream.push(&plaintext, false)?;
            (data, *stream.header())
        } else {
            let blob = blob::encrypt(&plaintext, &key)?;
            (blob.encrypted_data, blob.decryption_header)
        };
        let response: Value = api.post("/authenticator/entity")
            .json(&json!({"encryptedData": b64::encode(&data), "header": b64::encode(header.as_bytes())}))
            .send().await?.error_for_code().await?.json().await?;
        ids.push(
            response["id"]
                .as_str()
                .ok_or("missing entity id")?
                .to_owned(),
        );
    }
    Ok(ids)
}

pub fn prepare_museum() -> TestResult {
    let settings = postgresql_embedded::Settings {
        installation_dir: dirs::cache_dir()
            .ok_or("missing cache directory")?
            .join(".theseus/postgresql"),
        ..Default::default()
    };
    let mut postgres = postgresql_embedded::blocking::PostgreSQL::new(settings);
    postgres.setup()?;
    let timezone = postgres.settings().installation_dir.join("share/timezone");
    // postgresql_archive 0.20.4 drops tar hardlinks, including UTC, which SQLx requires at startup.
    for (alias, source) in [("UTC", "Universal"), ("GMT", "Greenwich")] {
        let alias = timezone.join(alias);
        if !alias.exists() {
            std::fs::copy(timezone.join(source), alias)?;
        }
    }
    Ok(())
}

pub async fn auth_api(endpoint: &str, email: &str, password: &str) -> TestResult<(Api, String)> {
    use ente_accounts::{AccountsClient, AccountsClientConfig, login::LoginFlow};
    use ente_core::http::{ApiConfig, Auth, Http};
    let client = AccountsClient::new(
        AccountsClientConfig::new("io.ente.auth.menubar").with_origin(endpoint),
    )?;
    let (mut flow, _) = LoginFlow::start(&client, email.to_owned()).await?;
    let ente_accounts::login::LoginStep::Complete(account) =
        flow.submit_password(&client, password).await?
    else {
        return Err("expected completed fixture login".into());
    };
    let mut config = ApiConfig::new(endpoint.to_owned());
    config.client_package = Some("io.ente.auth.menubar".into());
    let token = b64::encode_url_safe(&account.secrets.token);
    config.auth = Some(Auth::User(token.clone()));
    Ok((Api::new(Http::new()?, config), token))
}
