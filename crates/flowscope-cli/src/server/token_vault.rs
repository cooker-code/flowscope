//! Recoverable credentials for the administrator's token list.
use super::lineage_policy::{failure, ApiError};
use anyhow::Context;
use axum::http::StatusCode;
use ring::{
    aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM, NONCE_LEN},
    rand::{SecureRandom, SystemRandom},
};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Clone)]
pub(super) struct TokenVault {
    key: LessSafeKey,
}

impl TokenVault {
    pub fn key_path(database: &Path) -> PathBuf {
        let mut name = database.as_os_str().to_owned();
        name.push(".tokens.key");
        PathBuf::from(name)
    }

    pub fn load(database: &Path, has_encrypted_tokens: bool) -> anyhow::Result<Self> {
        let path = Self::key_path(database);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                anyhow::ensure!(
                    !has_encrypted_tokens,
                    "token encryption key is missing: restore {} with the state database",
                    path.display()
                );
                let mut bytes = [0; 32];
                SystemRandom::new()
                    .fill(&mut bytes)
                    .map_err(|_| anyhow::anyhow!("cannot generate token encryption key"))?;
                let mut options = OpenOptions::new();
                options.write(true).create_new(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    options.mode(0o600);
                }
                let mut file = options.open(&path).with_context(|| {
                    format!("cannot create token encryption key {}", path.display())
                })?;
                file.write_all(&bytes)?;
                file.sync_all()?;
                #[cfg(unix)]
                if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
                    fs::File::open(parent)?.sync_all()?;
                }
                bytes.to_vec()
            }
            Err(error) => return Err(error).context("cannot read token encryption key"),
        };
        anyhow::ensure!(bytes.len() == 32, "invalid token encryption key length");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        }
        let key = UnboundKey::new(&AES_256_GCM, &bytes)
            .map_err(|_| anyhow::anyhow!("invalid token encryption key"))?;
        Ok(Self {
            key: LessSafeKey::new(key),
        })
    }

    pub fn encrypt(&self, id: &str, token: &str) -> Result<Vec<u8>, ApiError> {
        let mut nonce = [0; NONCE_LEN];
        SystemRandom::new()
            .fill(&mut nonce)
            .map_err(|_| secret_error())?;
        let mut encrypted = token.as_bytes().to_vec();
        self.key
            .seal_in_place_append_tag(
                Nonce::assume_unique_for_key(nonce),
                Aad::from(id.as_bytes()),
                &mut encrypted,
            )
            .map_err(|_| secret_error())?;
        let mut stored = nonce.to_vec();
        stored.extend_from_slice(&encrypted);
        Ok(stored)
    }

    pub fn decrypt(&self, id: &str, stored: &[u8]) -> Result<String, ApiError> {
        if stored.len() < NONCE_LEN + AES_256_GCM.tag_len() {
            return Err(secret_error());
        }
        let nonce =
            Nonce::try_assume_unique_for_key(&stored[..NONCE_LEN]).map_err(|_| secret_error())?;
        let mut encrypted = stored[NONCE_LEN..].to_vec();
        let plaintext = self
            .key
            .open_in_place(nonce, Aad::from(id.as_bytes()), &mut encrypted)
            .map_err(|_| secret_error())?;
        String::from_utf8(plaintext.to_vec()).map_err(|_| secret_error())
    }
}

fn secret_error() -> ApiError {
    failure(
        StatusCode::INTERNAL_SERVER_ERROR,
        "token_secret_unavailable",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ciphertext_is_bound_to_its_token_and_key_survives_restart() {
        let dir = tempfile::tempdir().unwrap();
        let database = dir.path().join("state.db");
        let vault = TokenVault::load(&database, false).unwrap();
        let encrypted = vault.encrypt("token-a", "fst_test_credential").unwrap();
        assert!(!encrypted.windows(19).any(|w| w == b"fst_test_credential"));
        assert!(vault.decrypt("token-b", &encrypted).is_err());
        let mut tampered = encrypted.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert!(vault.decrypt("token-a", &tampered).is_err());
        let reopened = TokenVault::load(&database, true).unwrap();
        assert_eq!(
            reopened.decrypt("token-a", &encrypted).unwrap(),
            "fst_test_credential"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(TokenVault::key_path(&database))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        fs::remove_file(TokenVault::key_path(&database)).unwrap();
        assert!(TokenVault::load(&database, true).is_err());
        assert!(!TokenVault::key_path(&database).exists());
    }
}
