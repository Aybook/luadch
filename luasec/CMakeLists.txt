# Build the LuaSec TLS plugin: TLS handshake on top of LuaSocket TCP sockets.
#
# Outputs:
#   lib/luasec/ssl/ssl.so / .dll                (C module)
#   plus the Lua-side helpers under lib/luasec/lua/, in the canonical
#   LuaSec layout (closes luadch-ng/luadch#88):
#     lib/luasec/lua/ssl.lua                    (entrypoint)
#     lib/luasec/lua/ssl/https.lua   , options.lua  (`require "ssl.https"` etc.)

set(LSEC_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src)

set(LSEC_SOURCES
    ${LSEC_SRC}/options.c
    ${LSEC_SRC}/x509.c
    ${LSEC_SRC}/context.c
    ${LSEC_SRC}/ssl.c
    ${LSEC_SRC}/config.c
    ${LSEC_SRC}/ec.c
)

add_library(ssl MODULE ${LSEC_SOURCES})

target_compile_definitions(ssl PRIVATE WITH_LUASOCKET LUASEC_INET_NTOP)
if(WIN32)
    target_compile_definitions(ssl PRIVATE WINVER=0x0501)
endif()

# Headers: lua, openssl, our own dir (for luasocket/buffer.h etc.)
target_include_directories(ssl PRIVATE
    ${LSEC_SRC}
    ${OPENSSL_INCLUDE_DIR}
)

target_link_libraries(ssl PRIVATE
    lua
    luasocket_static    # buffer / io / timeout glue from the luasocket subdir
    OpenSSL::SSL
    OpenSSL::Crypto
)
if(WIN32)
    target_link_libraries(ssl PRIVATE ws2_32 gdi32)
endif()

set_target_properties(ssl PROPERTIES PREFIX "")
if(WIN32)
    set_target_properties(ssl PROPERTIES SUFFIX ".dll")
endif()

install(TARGETS ssl LIBRARY DESTINATION lib/luasec/ssl
                    RUNTIME DESTINATION lib/luasec/ssl)

# Canonical LuaSec layout (closes #88): top-level entrypoint + `ssl/` subdir
# for `ssl.X` submodules.
install(FILES ${LSEC_SRC}/ssl.lua      DESTINATION lib/luasec/lua)
install(FILES ${LSEC_SRC}/https.lua
              ${LSEC_SRC}/options.lua  DESTINATION lib/luasec/lua/ssl)
