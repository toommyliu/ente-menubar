mod support;

use ente_accounts::{AccountsClient, AccountsClientConfig, TwoFactorSetup};
use ente_bridge::{BridgeError, CodeKind, CodeView, Config, Display, LoginFlow, LoginStep, Vault};
use ente_core::{
    b64,
    crypto::{Key, blob, kdf, secretbox},
    http::Api,
};
use ente_test_support::{
    HARDCODED_OTT, Museum, TestResult,
    account_fixture::{create_account, current_totp},
};

fn config(endpoint: &str) -> Config {
    Config {
        api_origin: endpoint.into(),
        client_package: "io.ente.auth.menubar".into(),
        user_agent: "ente-menubar-tests".into(),
    }
}

fn code<'a>(codes: &'a [CodeView], issuer: &str) -> &'a CodeView {
    codes.iter().find(|code| code.issuer == issuer).unwrap()
}

#[test]
fn museum() -> TestResult {
    support::prepare_museum()?;
    Museum::run_async(|endpoint| async move {
        let fixture = create_account(&endpoint, "menubar").await?;
        let flow = LoginFlow::new(config(&endpoint))?;
        assert!(matches!(
            flow.prepare(fixture.email.clone()).await?,
            LoginStep::Password
        ));
        assert!(matches!(
            flow.submit_password("wrong password".into()).await,
            Err(BridgeError::InvalidCredentials)
        ));
        let LoginStep::Complete { session } =
            flow.submit_password(fixture.password.clone()).await?
        else {
            panic!("expected complete login")
        };
        let (api, token) = support::auth_api(&endpoint, &fixture.email, &fixture.password).await?;
        let vault = Vault::new(config(&endpoint), session.clone(), None)?;
        assert_eq!(vault.email(), fixture.email);
        assert!(matches!(
            Vault::new(config("http://127.0.0.1:1"), session.clone(), None),
            Err(BridgeError::Unsupported { .. })
        ));
        let empty = vault.sync().await?;
        assert_eq!((empty.has_authenticator_key, empty.total), (false, 0));
        assert_eq!(vault.codes(59_000)?, vec![]);
        let ids = support::seed(&api, &fixture.master_key).await?;
        let summary = vault.sync().await?;
        assert_eq!(
            (
                summary.has_authenticator_key,
                summary.upserted,
                summary.deleted,
                summary.total
            ),
            (true, 6, 0, 6)
        );
        let codes = vault.codes(59_000)?;
        let mut values: Vec<_> = codes
            .iter()
            .map(|code| {
                (
                    code.issuer.as_str(),
                    code.current.as_str(),
                    code.next.as_str(),
                    code.period_secs,
                    code.remaining_ms,
                )
            })
            .collect();
        values.sort();
        assert_eq!(
            values,
            vec![
                ("Counter", "", "", 0, 0),
                ("Legacy", "755224", "287082", 60, 1000),
                ("RFC", "287082", "359152", 30, 1000),
                ("SHA256", "46119246", "30882438", 30, 1000),
                ("Steam", "PV9M4", "B26KJ", 30, 1000),
                ("Trash", "287082", "359152", 30, 1000),
            ]
        );
        assert_eq!(code(&codes, "Counter").kind, CodeKind::Hotp);
        assert_eq!(code(&codes, "Steam").kind, CodeKind::Steam);
        assert_eq!(code(&codes, "RFC").kind, CodeKind::Totp);
        assert_eq!(code(&codes, "RFC").account, "alice");
        assert_eq!(code(&codes, "RFC").id, ids[0]);
        assert!(code(&codes, "Trash").display.trashed);
        let expected_display = Display {
            pinned: true,
            trashed: false,
            tags: vec!["work".into(), "comma, + # 😀".into()],
            note: "literal%2C, + # 😀".into(),
            icon_src: "custom".into(),
            icon_id: "saved".into(),
            tap_count: 7,
            last_used_at: 123456,
        };
        assert_eq!(code(&codes, "RFC").display, expected_display);
        assert_eq!(code(&codes, "Legacy").display, expected_display);
        assert_eq!(code(&vault.codes(59_999)?, "RFC").remaining_ms, 1);
        let boundary = vault.codes(60_000)?;
        assert_eq!(code(&boundary, "RFC").current, "359152");
        assert_eq!(code(&boundary, "RFC").remaining_ms, 30_000);
        assert_eq!(code(&boundary, "Legacy").remaining_ms, 60_000);
        for (seconds, sha1, sha256) in [
            (1_111_111_109, "081804", "68084774"),
            (1_111_111_111, "050471", "67062674"),
            (1_234_567_890, "005924", "91819424"),
            (2_000_000_000, "279037", "90698825"),
            (20_000_000_000, "353130", "77737706"),
        ] {
            let codes = vault.codes(seconds * 1000)?;
            assert_eq!(code(&codes, "RFC").current, sha1);
            assert_eq!(code(&codes, "SHA256").current, sha256);
        }
        let unchanged = vault.sync().await?;
        assert_eq!(
            (unchanged.upserted, unchanged.deleted, unchanged.total),
            (0, 0, 6)
        );
        let cache = vault.export_cache();
        let master_key = Key::try_from_slice(&fixture.master_key)?;
        assert!(secretbox::decrypt_combined(&cache, &master_key).is_err());
        let cache_key = Key::try_from_slice(&kdf::derive_subkey(
            &master_key,
            Key::BYTES,
            1,
            b"EMBcache",
        )?)?;
        let plaintext = secretbox::decrypt_combined(&cache, &cache_key)?;
        let cached: serde_json::Value = serde_json::from_slice(&plaintext)?;
        assert_eq!(cached["version"], 1);
        assert_eq!(cached["records"].as_object().unwrap().len(), 6);
        let restarted = Vault::new(config(&endpoint), session.clone(), Some(cache.clone()))?;
        assert_eq!(restarted.codes(59_000)?, codes);
        let restored = restarted.sync().await?;
        assert_eq!((restored.upserted, restored.total), (0, 6));
        let mut corrupt = cache.clone();
        corrupt[30] ^= 1;
        let corrupt_vault = Vault::new(config(&endpoint), session.clone(), Some(corrupt))?;
        assert_eq!(corrupt_vault.codes(59_000)?, vec![]);
        assert_eq!(corrupt_vault.sync().await?.total, 6);
        assert_eq!(corrupt_vault.codes(59_000)?, codes);
        let other = create_account(&endpoint, "other-cache").await?;
        let other_flow = LoginFlow::new(config(&endpoint))?;
        other_flow.prepare(other.email).await?;
        let LoginStep::Complete {
            session: other_session,
        } = other_flow.submit_password(other.password).await?
        else {
            panic!("expected other account session")
        };
        let other_vault = Vault::new(config(&endpoint), other_session, Some(cache))?;
        assert_eq!(other_vault.codes(59_000)?, vec![]);
        assert_eq!(other_vault.sync().await?.total, 0);
        let foreign_cache = other_vault.export_cache();
        let foreign = Vault::new(config(&endpoint), session.clone(), Some(foreign_cache))?;
        assert_eq!(foreign.codes(59_000)?, vec![]);
        assert_eq!(foreign.sync().await?.total, 6);
        api.delete("/authenticator/entity")
            .query(&[("id", &ids[0])])
            .send()
            .await?
            .error_for_code()
            .await?;
        let deleted = vault.sync().await?;
        assert_eq!(
            (deleted.upserted, deleted.deleted, deleted.total),
            (0, 1, 5)
        );
        let remaining = vault.codes(59_000)?;
        assert!(!remaining.iter().any(|code| code.id == ids[0]));
        assert_eq!(code(&remaining, "SHA256").current, "46119246");
        let mut invalid: serde_json::Value = serde_json::from_slice(&session)?;
        invalid["account"]["token"] = serde_json::json!([0; 32].to_vec());
        assert!(matches!(
            Vault::new(config(&endpoint), serde_json::to_vec(&invalid)?, None)?
                .sync()
                .await,
            Err(BridgeError::Unauthorized)
        ));

        api.put("/users/email-mfa")
            .json(&serde_json::json!({"isEnabled": true}))
            .send()
            .await?
            .error_for_code()
            .await?;
        let email_flow = LoginFlow::new(config(&endpoint))?;
        assert!(matches!(
            email_flow.prepare(fixture.email.clone()).await?,
            LoginStep::EmailCode
        ));
        email_flow.resend_code().await?;
        assert!(matches!(
            email_flow.submit_code("000000".into()).await,
            Err(BridgeError::InvalidCode)
        ));
        assert!(matches!(
            email_flow.submit_code(HARDCODED_OTT.into()).await?,
            LoginStep::Password
        ));
        let LoginStep::Complete {
            session: email_session,
        } = email_flow.submit_password(fixture.password.clone()).await?
        else {
            panic!("expected complete login after email verification")
        };
        let email_vault = Vault::new(config(&endpoint), email_session, None)?;
        email_vault.sync().await?;
        assert_eq!(email_vault.codes(59_000)?, remaining);
        api.put("/users/email-mfa")
            .json(&serde_json::json!({"isEnabled": false}))
            .send()
            .await?
            .error_for_code()
            .await?;
        let client = AccountsClient::new(
            AccountsClientConfig::new("io.ente.auth.menubar")
                .with_origin(&endpoint)
                .with_auth_token(token),
        )?;
        let setup =
            TwoFactorSetup::start(&client, &fixture.master_key, &fixture.key_attributes).await?;
        setup
            .enable(&client, &current_totp(&setup.secret_code)?)
            .await?;
        let second_factor = LoginFlow::new(config(&endpoint))?;
        assert!(matches!(
            second_factor.prepare(fixture.email.clone()).await?,
            LoginStep::Password
        ));
        assert!(matches!(
            second_factor
                .submit_password(fixture.password.clone())
                .await?,
            LoginStep::AuthenticatorCode
        ));
        assert!(matches!(
            second_factor.submit_code("invalid".into()).await,
            Err(BridgeError::InvalidCode)
        ));
        assert!(matches!(
            second_factor
                .submit_code(current_totp(&setup.secret_code)?)
                .await?,
            LoginStep::Complete { .. }
        ));
        let raw: serde_json::Value = api
            .get("/authenticator/entity/diff")
            .query(&[("sinceTime", 0), ("limit", 5000)])
            .send()
            .await?
            .error_for_code()
            .await?
            .json()
            .await?;
        let source = raw["diff"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entity| entity["id"] == ids[1])
            .unwrap();
        let copy = serde_json::json!({"encryptedData": source["encryptedData"], "header": source["header"]});
        for index in 0..5001 {
            if index % 100 == 0 {
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            }
            api.post("/authenticator/entity")
                .json(&copy)
                .send()
                .await?
                .error_for_code()
                .await?;
        }
        let paginated = restarted.sync().await?;
        assert_eq!(
            (paginated.upserted, paginated.deleted, paginated.total),
            (5001, 1, 5006)
        );
        let all_codes = restarted.codes(59_000)?;
        assert_eq!(
            all_codes
                .iter()
                .filter(|code| code.current == "46119246")
                .count(),
            5002
        );
        assert_eq!(code(&all_codes, "Steam").current, "PV9M4");

        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
        add_entities(
            &api,
            &fixture.master_key,
            &[
                serde_json::json!(format!(
                    "otpauth://totp/Fragment:alice?secret={secret}&codeDisplay={{\"trashed\":true,\"pinned\":true}}#suffix"
                )),
                serde_json::json!(format!(
                    "otpauth://totp/BadDisplay:alice?secret={secret}&codeDisplay=%7B%22pinned%22%3Atrue%2C%22tags%22%3A%22oops%22%2C%22tapCount%22%3A%22x%22%7D"
                )),
                serde_json::json!("not an otpauth uri"),
            ],
        )
        .await?;
        let edge = restarted.sync().await?;
        assert_eq!(
            (edge.upserted, edge.deleted, edge.total, edge.unreadable),
            (2, 0, 5008, 1)
        );
        let edge_codes = restarted.codes(59_000)?;
        assert_eq!(code(&edge_codes, "Fragment").current, "287082");
        assert_eq!(
            code(&edge_codes, "Fragment").display,
            Display {
                pinned: true,
                trashed: true,
                ..Display::default()
            }
        );
        assert_eq!(
            code(&edge_codes, "BadDisplay").display,
            Display {
                pinned: true,
                ..Display::default()
            }
        );
        let edge_cache = restarted.export_cache();
        let edge_restored = Vault::new(config(&endpoint), session, Some(edge_cache))?;
        assert_eq!(edge_restored.codes(59_000)?, edge_codes);
        assert_eq!(edge_restored.unreadable_count(), 1);
        assert_eq!(edge_restored.sync().await?.upserted, 0);
        edge_restored.logout().await?;
        assert!(matches!(
            edge_restored.sync().await,
            Err(BridgeError::Unauthorized)
        ));
        Ok(())
    })
}

async fn add_entities(api: &Api, master_key: &[u8], values: &[serde_json::Value]) -> TestResult {
    let wrapped = api
        .get("/authenticator/key")
        .send()
        .await?
        .error_for_code()
        .await?
        .json()
        .await?;
    let key = ente_auth::open_key(&wrapped, &Key::try_from_slice(master_key)?)?;
    for value in values {
        let sealed = blob::encrypt(&serde_json::to_vec(value)?, &key)?;
        api.post("/authenticator/entity")
            .json(&serde_json::json!({
                "encryptedData": b64::encode(&sealed.encrypted_data),
                "header": b64::encode(sealed.decryption_header.as_bytes())
            }))
            .send()
            .await?
            .error_for_code()
            .await?;
    }
    Ok(())
}
