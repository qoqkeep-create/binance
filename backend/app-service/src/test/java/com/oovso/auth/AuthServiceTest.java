package com.oovso.auth;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class AuthServiceTest {

    private final AppAuthProperties properties = new AppAuthProperties();
    private final AppUserMapper userMapper = mock(AppUserMapper.class);
    private final PasswordHasher passwordHasher = new PasswordHasher();

    private AuthService authService;

    @BeforeEach
    void setUp() {
        properties.setRegistrationEnabled(true);
        authService = new AuthService(properties, userMapper, passwordHasher);
    }

    @Test
    void authenticatesEnabledUserWithCorrectPassword() {
        AppUser user = user("admin", "a strong password");
        when(userMapper.selectActiveByLogin("admin")).thenReturn(user);

        AppUser authenticated = authService.authenticate(
                " ADMIN ",
                "a strong password"
        );

        assertEquals(user.getId(), authenticated.getId());
    }

    @Test
    void rejectsWrongPassword() {
        AppUser user = user("admin", "a strong password");
        when(userMapper.selectActiveByLogin("admin")).thenReturn(user);

        assertThrows(
                InvalidCredentialsException.class,
                () -> authService.authenticate("admin", "wrong password")
        );
    }

    @Test
    void rejectsUnknownAccount() {
        when(userMapper.selectActiveByLogin("missing")).thenReturn(null);

        assertThrows(
                InvalidCredentialsException.class,
                () -> authService.authenticate("missing", "wrong password")
        );
    }

    @Test
    void rejectsSessionWhenUserWasDisabledOrDeleted() {
        when(userMapper.selectActiveById("disabled-user")).thenReturn(null);

        assertThrows(
                SessionInvalidException.class,
                () -> authService.requireActiveUser("disabled-user")
        );
    }

    @Test
    void registersUserWithHashedPassword() {
        when(userMapper.selectByLoginIdentity("trader")).thenReturn(null);
        when(userMapper.selectByLoginIdentity("trader@local.invalid")).thenReturn(null);

        AppUser registered = authService.register(
                " Trader ",
                "secure-password",
                null
        );

        ArgumentCaptor<AppUser> userCaptor =
                ArgumentCaptor.forClass(AppUser.class);
        verify(userMapper).insertAppUser(userCaptor.capture());
        AppUser inserted = userCaptor.getValue();

        assertEquals(inserted.getId(), registered.getId());
        assertEquals("trader", inserted.getAccount());
        assertEquals("trader@local.invalid", inserted.getEmail());
        assertEquals("trader", inserted.getDisplayName());
        assertTrue(passwordHasher.matches(
                "secure-password",
                inserted.getPasswordHash(),
                inserted.getPasswordSalt()
        ));
    }

    @Test
    void rejectsDuplicateRegistrationIdentity() {
        when(userMapper.selectByLoginIdentity("admin")).thenReturn(user("admin", "password"));

        assertThrows(
                AccountAlreadyExistsException.class,
                () -> authService.register("admin", "secure-password", null)
        );
    }

    @Test
    void rejectsRegistrationWhenDisabled() {
        properties.setRegistrationEnabled(false);

        assertThrows(
                RegistrationDisabledException.class,
                () -> authService.register("new-user", "secure-password", null)
        );
    }

    private AppUser user(String account, String password) {
        PasswordHasher.PasswordHash passwordHash =
                passwordHasher.hash(password);
        AppUser user = new AppUser();
        user.setId("user-id");
        user.setAccount(account);
        user.setPasswordHash(passwordHash.hash());
        user.setPasswordSalt(passwordHash.salt());
        user.setEnabledState(1);
        return user;
    }
}
