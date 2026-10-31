package com.oovso.trading;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.security.SecureRandom;
import java.util.Base64;
import org.junit.jupiter.api.Test;

class TradingCredentialCipherTest {

    @Test
    void encryptsAndDecryptsCredentialsWithAccountBoundAad() {
        TradingProperties properties = properties();
        TradingCredentialCipher cipher = new TradingCredentialCipher(
                properties,
                new FixedSecureRandom()
        );
        TradingAccount account = account("account-a");
        BinanceCredentials credentials = new BinanceCredentials(
                "abcde12345vwxyz",
                "server-only-secret"
        );

        TradingCredentialCipher.EncryptedCredential encrypted = cipher.encrypt(
                "user-a",
                account,
                credentials
        );
        account.setCredentialCiphertext(encrypted.ciphertext());
        account.setCredentialNonce(encrypted.nonce());
        account.setCredentialKeyVersion(encrypted.keyVersion());

        assertEquals(credentials, cipher.decrypt("user-a", account));
        assertEquals("abcde****vwxyz", encrypted.apiKeyMasked());
        assertEquals(64, encrypted.fingerprint().length());
        assertThrows(
                TradingApiException.class,
                () -> cipher.decrypt("different-user", account)
        );
    }

    @Test
    void refusesToOperateWithoutConfiguredMasterKey() {
        TradingProperties properties = new TradingProperties();
        TradingCredentialCipher cipher = new TradingCredentialCipher(properties);

        TradingApiException error = assertThrows(
                TradingApiException.class,
                () -> cipher.encrypt(
                        "user-a",
                        account("account-a"),
                        new BinanceCredentials("api-key", "secret-key")
                )
        );

        assertEquals(503, error.status().value());
    }

    private TradingProperties properties() {
        TradingProperties properties = new TradingProperties();
        byte[] masterKey = new byte[32];
        for (int index = 0; index < masterKey.length; index++) {
            masterKey[index] = (byte) index;
        }
        properties.setCredentialMasterKey(
                Base64.getEncoder().encodeToString(masterKey)
        );
        properties.setCredentialKeyVersion("v1");
        return properties;
    }

    private TradingAccount account(String id) {
        TradingAccount account = new TradingAccount();
        account.setId(id);
        account.setExchange("BINANCE");
        account.setMarketType("USDM");
        account.setEnvironment("LIVE");
        return account;
    }

    private static final class FixedSecureRandom extends SecureRandom {
        @Override
        public void nextBytes(byte[] bytes) {
            for (int index = 0; index < bytes.length; index++) {
                bytes[index] = (byte) (index + 1);
            }
        }
    }
}
