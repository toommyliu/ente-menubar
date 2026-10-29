#[path = "../../bridge/tests/support/mod.rs"]
mod support;

use std::io::Write;

use ente_test_support::{Museum, TestResult, account_fixture::create_account};
use serde_json::json;

fn main() -> TestResult {
    support::prepare_museum()?;
    Museum::run_async(|endpoint| async move {
        let fixture = create_account(&endpoint, "swift-smoke").await?;
        let (api, _) = support::auth_api(&endpoint, &fixture.email, &fixture.password).await?;
        support::seed(&api, &fixture.master_key).await?;
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        println!(
            "{}",
            json!({
                "endpoint": endpoint, "email": fixture.email, "password": fixture.password, "now_unix_ms": 59000,
                "expected_codes": [
                    {"issuer": "Counter", "current": "", "next": "", "kind": "hotp", "period_secs": 0, "remaining_ms": 0, "trashed": false},
                    {"issuer": "Legacy", "current": "755224", "next": "287082", "kind": "totp", "period_secs": 60, "remaining_ms": 1000, "trashed": false},
                    {"issuer": "RFC", "current": "287082", "next": "359152", "kind": "totp", "period_secs": 30, "remaining_ms": 1000, "trashed": false},
                    {"issuer": "SHA256", "current": "46119246", "next": "30882438", "kind": "totp", "period_secs": 30, "remaining_ms": 1000, "trashed": false},
                    {"issuer": "Steam", "current": "PV9M4", "next": "B26KJ", "kind": "steam", "period_secs": 30, "remaining_ms": 1000, "trashed": false},
                    {"issuer": "Trash", "current": "287082", "next": "359152", "kind": "totp", "period_secs": 30, "remaining_ms": 1000, "trashed": true}
                ]
            })
        );
        std::io::stdout().flush()?;
        tokio::select! {
            result = tokio::signal::ctrl_c() => result?,
            _ = terminate.recv() => {}
        }
        Ok(())
    })
}
