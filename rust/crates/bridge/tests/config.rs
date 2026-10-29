use ente_bridge::{BridgeError, Config, LoginFlow};

fn config(api_origin: &str) -> Config {
    Config {
        api_origin: api_origin.into(),
        client_package: "io.ente.auth.menubar".into(),
        user_agent: "ente-menubar-tests".into(),
    }
}

#[test]
fn api_origin_needs_https_unless_loopback() {
    for origin in [
        "https://api.ente.com",
        "https://ente.example.org:8443/",
        "http://127.0.0.1:8080",
        "http://localhost:3000",
        "http://[::1]:8080",
    ] {
        assert!(LoginFlow::new(config(origin)).is_ok(), "{origin}");
    }
    for origin in [
        "http://api.ente.com",
        "http://192.168.1.10:8080",
        "ftp://api.ente.com",
        "https://user:pw@api.ente.com",
        "https://api.ente.com/?a=1",
        "not a url",
    ] {
        assert!(
            matches!(
                LoginFlow::new(config(origin)),
                Err(BridgeError::Unsupported { .. })
            ),
            "{origin}"
        );
    }
}
