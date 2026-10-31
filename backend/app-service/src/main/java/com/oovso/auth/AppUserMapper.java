package com.oovso.auth;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface AppUserMapper extends BaseMapper<AppUser> {

    @Select("""
            select *
            from app_user
            where delete_state = 0
              and enabled_state = 1
              and (account = #{login} or email = #{login})
            limit 1
            """)
    AppUser selectActiveByLogin(@Param("login") String login);

    @Select("""
            select *
            from app_user
            where id = #{id}
              and delete_state = 0
              and enabled_state = 1
            limit 1
            """)
    AppUser selectActiveById(@Param("id") String id);

    @Select("""
            select *
            from app_user
            where lower(email) = lower(#{email})
              and delete_state = 0
              and enabled_state = 1
            limit 1
            """)
    AppUser selectActiveByEmail(@Param("email") String email);

    @Select("""
            select *
            from app_user
            where delete_state = 0
              and (account = #{login} or email = #{login})
            limit 1
            """)
    AppUser selectByLoginIdentity(@Param("login") String login);

    @Select("""
            select *
            from app_user
            where account = #{account}
              and delete_state = 0
            limit 1
            """)
    AppUser selectByAccount(@Param("account") String account);

    @Insert("""
            insert into app_user (
                id,
                create_time,
                update_time,
                delete_state,
                account,
                email,
                display_name,
                password_hash,
                password_salt,
                enabled_state
            ) values (
                #{id},
                #{createTime},
                #{updateTime},
                #{deleteState},
                #{account},
                #{email},
                #{displayName},
                #{passwordHash},
                #{passwordSalt},
                #{enabledState}
            )
            """)
    int insertAppUser(AppUser user);
}
