package com.oovso.auth;

import java.time.LocalDateTime;
import java.util.Locale;
import java.util.UUID;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.util.StringUtils;

@Service
public class AuthService {

    private static final String DUMMY_PASSWORD = "trade-tool-invalid-credential";

    private final AppAuthProperties properties;
    private final AppUserMapper userMapper;
    private final PasswordHasher passwordHasher;
    private final PasswordHasher.PasswordHash dummyHash;

    public AuthService(
            AppAuthProperties properties,
            AppUserMapper userMapper,
            PasswordHasher passwordHasher
    ) {
        this.properties = properties;
        this.userMapper = userMapper;
        this.passwordHasher = passwordHasher;
        dummyHash = passwordHasher.hash(DUMMY_PASSWORD);
    }

    public AppUser authenticate(String account, String password) {
        String normalizedAccount = normalize(account);
        AppUser user = userMapper.selectActiveByLogin(normalizedAccount);

        if (user == null) {
            passwordHasher.matches(
                    password,
                    dummyHash.hash(),
                    dummyHash.salt()
            );
            throw new InvalidCredentialsException();
        }

        boolean passwordMatches = passwordHasher.matches(
                password,
                user.getPasswordHash(),
                user.getPasswordSalt()
        );

        if (!passwordMatches) {
            throw new InvalidCredentialsException();
        }

        return user;
    }

    @Transactional
    public AppUser register(
            String account,
            String password,
            String displayName
    ) {
        if (!properties.isRegistrationEnabled()) {
            throw new RegistrationDisabledException();
        }

        String normalizedAccount = normalize(account);
        String resolvedEmail = resolveEmail(normalizedAccount);
        assertLoginIdentityAvailable(normalizedAccount);
        if (!resolvedEmail.equals(normalizedAccount)) {
            assertLoginIdentityAvailable(resolvedEmail);
        }

        PasswordHasher.PasswordHash passwordHash = passwordHasher.hash(password);
        LocalDateTime now = LocalDateTime.now();

        AppUser user = new AppUser();
        user.setId(UUID.randomUUID().toString());
        user.setCreateTime(now);
        user.setUpdateTime(now);
        user.setDeleteState(0);
        user.setAccount(normalizedAccount);
        user.setEmail(resolvedEmail);
        user.setDisplayName(resolveDisplayName(displayName, normalizedAccount));
        user.setPasswordHash(passwordHash.hash());
        user.setPasswordSalt(passwordHash.salt());
        user.setEnabledState(1);

        try {
            userMapper.insertAppUser(user);
        } catch (DuplicateKeyException exception) {
            throw new AccountAlreadyExistsException();
        }
        return user;
    }

    public AppUser requireActiveUser(String id) {
        AppUser user = userMapper.selectActiveById(id);
        if (user == null) {
            throw new SessionInvalidException();
        }
        return user;
    }

    private void assertLoginIdentityAvailable(String login) {
        if (userMapper.selectByLoginIdentity(login) != null) {
            throw new AccountAlreadyExistsException();
        }
    }

    private String resolveEmail(String normalizedAccount) {
        if (normalizedAccount.contains("@")) {
            return normalizedAccount;
        }
        return normalizedAccount + "@local.invalid";
    }

    private String resolveDisplayName(
            String displayName,
            String normalizedAccount
    ) {
        if (StringUtils.hasText(displayName)) {
            return displayName.trim();
        }
        return normalizedAccount;
    }

    static String normalize(String value) {
        if (!StringUtils.hasText(value)) {
            return "";
        }
        return value.trim().toLowerCase(Locale.ROOT);
    }
}
