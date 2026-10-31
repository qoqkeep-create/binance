package com.oovso.auth;

import java.time.LocalDateTime;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.boot.sql.init.dependency.DependsOnDatabaseInitialization;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

@Component
@DependsOnDatabaseInitialization
public class BootstrapAdminInitializer implements SmartInitializingSingleton {

    private static final Logger log = LoggerFactory.getLogger(BootstrapAdminInitializer.class);
    private static final int MINIMUM_PASSWORD_LENGTH = 12;

    private final AppAuthProperties properties;
    private final AppUserMapper userMapper;
    private final PasswordHasher passwordHasher;

    public BootstrapAdminInitializer(
            AppAuthProperties properties,
            AppUserMapper userMapper,
            PasswordHasher passwordHasher
    ) {
        this.properties = properties;
        this.userMapper = userMapper;
        this.passwordHasher = passwordHasher;
    }

    @Override
    public void afterSingletonsInstantiated() {
        if (!StringUtils.hasText(properties.getBootstrapAccount())
                || !StringUtils.hasText(properties.getBootstrapPassword())) {
            log.debug("App admin bootstrap skipped because credentials are not configured");
            return;
        }

        String account = AuthService.normalize(properties.getBootstrapAccount());
        if (userMapper.selectByAccount(account) != null) {
            log.debug("App admin bootstrap skipped because account already exists: {}", account);
            return;
        }

        if (properties.getBootstrapPassword().length() < MINIMUM_PASSWORD_LENGTH) {
            throw new IllegalStateException(
                    "APP_ADMIN_PASSWORD must contain at least "
                            + MINIMUM_PASSWORD_LENGTH
                            + " characters"
            );
        }

        PasswordHasher.PasswordHash passwordHash = passwordHasher.hash(
                properties.getBootstrapPassword()
        );
        LocalDateTime now = LocalDateTime.now();

        AppUser user = new AppUser();
        user.setId(UUID.randomUUID().toString());
        user.setCreateTime(now);
        user.setUpdateTime(now);
        user.setDeleteState(0);
        user.setAccount(account);
        user.setEmail(resolveEmail(account));
        user.setDisplayName(resolveDisplayName(account));
        user.setPasswordHash(passwordHash.hash());
        user.setPasswordSalt(passwordHash.salt());
        user.setEnabledState(1);
        userMapper.insertAppUser(user);

        log.info("Created bootstrap app administrator account: {}", account);
    }

    private String resolveEmail(String account) {
        if (StringUtils.hasText(properties.getBootstrapEmail())) {
            return AuthService.normalize(properties.getBootstrapEmail());
        }
        if (account.contains("@")) {
            return account;
        }
        return account + "@local.invalid";
    }

    private String resolveDisplayName(String account) {
        if (StringUtils.hasText(properties.getBootstrapDisplayName())) {
            return properties.getBootstrapDisplayName().trim();
        }
        return account;
    }
}
