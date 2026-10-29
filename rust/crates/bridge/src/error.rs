#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("Network request failed")]
    Network,
    #[error("Invalid credentials")]
    InvalidCredentials,
    #[error("Invalid verification code")]
    InvalidCode,
    #[error("Session is no longer valid")]
    Unauthorized,
    #[error("Too many requests")]
    RateLimited,
    #[error("{message}")]
    Unsupported { message: String },
    #[error("{message}")]
    Internal { message: String },
}

impl BridgeError {
    pub(crate) fn unsupported(message: &str) -> Self {
        Self::Unsupported {
            message: message.into(),
        }
    }

    pub(crate) fn internal(message: &str) -> Self {
        Self::Internal {
            message: message.into(),
        }
    }
}

impl From<ente_core::http::Error> for BridgeError {
    fn from(error: ente_core::http::Error) -> Self {
        use ente_core::http::Error;
        match error {
            Error::Network(_) => Self::Network,
            Error::Http { status: 401, .. } | Error::Api { status: 401, .. } => Self::Unauthorized,
            Error::Http { status: 429, .. } | Error::Api { status: 429, .. } => Self::RateLimited,
            Error::Http { .. } | Error::Api { .. } | Error::Parse(_) => {
                Self::internal("Unexpected server response")
            }
        }
    }
}

impl From<ente_accounts::Error> for BridgeError {
    fn from(error: ente_accounts::Error) -> Self {
        use ente_accounts::Error;
        match error {
            Error::Http(error) => error.into(),
            Error::IncorrectPassword => Self::InvalidCredentials,
            Error::IncorrectEmailVerificationCode
            | Error::EmailVerificationCodeExpired
            | Error::IncorrectTotp => Self::InvalidCode,
            Error::EmailVerificationRateLimited | Error::TotpRateLimited => Self::RateLimited,
            Error::SessionInvalid | Error::SecondFactorSessionExpired => Self::Unauthorized,
            Error::InvalidInput(_) => {
                Self::unsupported("Action is not valid for the current login step")
            }
            Error::Crypto(_)
            | Error::Serialization(_)
            | Error::Otp(_)
            | Error::Decode(_)
            | Error::IncorrectRecoveryKey
            | Error::InvalidKeyAttributes
            | Error::InsufficientMemory
            | Error::MissingField(_)
            | Error::InvalidKey(_)
            | Error::Srp(_)
            | Error::MissingKeyAttributes
            | Error::AccountAlreadyExists
            | Error::Protocol(_) => Self::internal("Unable to open account"),
        }
    }
}

impl From<ente_auth::Error> for BridgeError {
    fn from(error: ente_auth::Error) -> Self {
        use ente_auth::Error;
        match error {
            Error::Http(error) => error.into(),
            Error::UnsupportedHotp => Self::unsupported("HOTP generation is unavailable"),
            Error::UnsupportedVersion => Self::unsupported("Unsupported authenticator format"),
            Error::Crypto(_)
            | Error::Otp(_)
            | Error::Base64(_)
            | Error::InvalidRecord
            | Error::InvalidCodeParameters
            | Error::InvalidBackup => Self::internal("Unable to read authenticator record"),
        }
    }
}

impl From<ente_core::crypto::Error> for BridgeError {
    fn from(_: ente_core::crypto::Error) -> Self {
        Self::internal("Invalid account key material")
    }
}
