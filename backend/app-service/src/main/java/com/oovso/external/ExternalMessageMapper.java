package com.oovso.external;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface ExternalMessageMapper {

    @Insert("""
            insert into external_message (
                id,
                payload_json,
                received_time_ms
            ) values (
                #{id},
                #{payloadJson},
                #{receivedTimeMs}
            )
            """)
    int insertMessage(ExternalMessageRow message);
}
