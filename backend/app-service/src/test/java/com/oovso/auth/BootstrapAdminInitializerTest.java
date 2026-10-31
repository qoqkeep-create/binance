package com.oovso.auth;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class BootstrapAdminInitializerTest {

    private final AppUserMapper userMapper = mock(AppUserMapper.class);
    private final PasswordHasher passwordHasher = new PasswordHasher();

    @Test
    void skipsWhenCredentialsAreNotConfigured() {
        AppAuthProperties properties = new AppAuthProperties();
        BootstrapAdminInitializer initializer = new BootstrapAdminInitializer(
                properties,
                userMapper,
                passwordHasher
        );

        initializer.afterSingletonsInstantiated();

        verify(userMapper, never()).insertAppUser(any());
    }

    @Test
    void createsInitialAdministratorWithHashedPassword() {
        AppAuthProperties properties = properties(
                "Admin",
                "a-strong-bootstrap-password"
        );
        when(userMapper.selectByAccount("admin")).thenReturn(null);
        BootstrapAdminInitializer initializer = new BootstrapAdminInitializer(
                properties,
                userMapper,
                passwordHasher
        );

        initializer.afterSingletonsInstantiated();

        ArgumentCaptor<AppUser> userCaptor =
                ArgumentCaptor.forClass(AppUser.class);
        verify(userMapper).insertAppUser(userCaptor.capture());
        AppUser user = userCaptor.getValue();
        assertEquals("admin", user.getAccount());
        assertEquals("admin@example.com", user.getEmail());
        assertEquals("Administrator", user.getDisplayName());
        assertTrue(passwordHasher.matches(
                "a-strong-bootstrap-password",
                user.getPasswordHash(),
                user.getPasswordSalt()
        ));
    }

    @Test
    void rejectsWeakBootstrapPassword() {
        AppAuthProperties properties = properties("admin", "short");
        when(userMapper.selectByAccount("admin")).thenReturn(null);
        BootstrapAdminInitializer initializer = new BootstrapAdminInitializer(
                properties,
                userMapper,
                passwordHasher
        );

        assertThrows(
                IllegalStateException.class,
                initializer::afterSingletonsInstantiated
        );
    }

    private AppAuthProperties properties(
            String account,
            String password
    ) {
        AppAuthProperties properties = new AppAuthProperties();
        properties.setBootstrapAccount(account);
        properties.setBootstrapPassword(password);
        properties.setBootstrapEmail("admin@example.com");
        properties.setBootstrapDisplayName("Administrator");
        return properties;
    }
}
