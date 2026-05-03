# Build the LuaSocket plugins (socket, mime) and a small static helper
# library used by luasec.
#
# This replaces the *.c.not rename trick from compile_with_mingw.bat by
# using per-platform source lists directly.
#
# Outputs:
#   lib/luasocket/socket/socket.so / .dll
#   lib/luasocket/mime/mime.so   / .dll
#   plus the .lua bridge files copied flat into lib/luasocket/lua/

set(LSOCKET_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src)

# ---- common (used by socket plugin AND luasec's static linker) -------------
set(LSOCKET_COMMON_SOURCES
    ${LSOCKET_SRC}/io.c
    ${LSOCKET_SRC}/buffer.c
    ${LSOCKET_SRC}/timeout.c
    ${LSOCKET_SRC}/compat.c
)

# ---- socket plugin (cross-platform pieces + per-platform sockets) ----------
set(LSOCKET_CORE_SOURCES
    ${LSOCKET_SRC}/luasocket.c
    ${LSOCKET_SRC}/auxiliar.c
    ${LSOCKET_SRC}/options.c
    ${LSOCKET_SRC}/inet.c
    ${LSOCKET_SRC}/except.c
    ${LSOCKET_SRC}/select.c
    ${LSOCKET_SRC}/tcp.c
    ${LSOCKET_SRC}/udp.c
)

if(WIN32)
    list(APPEND LSOCKET_CORE_SOURCES
        ${LSOCKET_SRC}/wsocket.c    # Win32 socket layer
    )
else()
    list(APPEND LSOCKET_CORE_SOURCES
        ${LSOCKET_SRC}/usocket.c       # POSIX socket layer
        ${LSOCKET_SRC}/serial.c        # serial port (Unix-only)
        ${LSOCKET_SRC}/unix.c          # Unix-domain socket
        ${LSOCKET_SRC}/unixstream.c
        ${LSOCKET_SRC}/unixdgram.c
    )
endif()

add_library(socket MODULE
    ${LSOCKET_COMMON_SOURCES}
    ${LSOCKET_CORE_SOURCES}
)
target_compile_definitions(socket PRIVATE LUASOCKET_NODEBUG LUASOCKET_INET_PTON)
if(WIN32)
    target_compile_definitions(socket PRIVATE WINVER=0x0501)
    target_link_libraries(socket PRIVATE ws2_32)
endif()
target_include_directories(socket PRIVATE ${LSOCKET_SRC})
target_link_libraries(socket PRIVATE lua)
set_target_properties(socket PROPERTIES PREFIX "")
if(WIN32)
    set_target_properties(socket PROPERTIES SUFFIX ".dll")
endif()

# ---- mime plugin (small, cross-platform) -----------------------------------
add_library(mime MODULE
    ${LSOCKET_SRC}/mime.c
    ${LSOCKET_SRC}/compat.c
)
target_include_directories(mime PRIVATE ${LSOCKET_SRC})
target_link_libraries(mime PRIVATE lua)
set_target_properties(mime PROPERTIES PREFIX "")
if(WIN32)
    set_target_properties(mime PROPERTIES SUFFIX ".dll")
endif()

# ---- static helper for luasec ----------------------------------------------
# luasec links against a subset of luasocket's object files (the buffer/io/
# timeout glue PLUS the platform socket layer — wsocket on Windows, usocket
# on POSIX) so its TLS sockets share LuaSocket's read/write/wait semantics.
# We expose this as a static library; luasec's CMakeLists pulls it in.
set(LSOCKET_STATIC_SOURCES ${LSOCKET_COMMON_SOURCES})
if(WIN32)
    list(APPEND LSOCKET_STATIC_SOURCES ${LSOCKET_SRC}/wsocket.c)
else()
    list(APPEND LSOCKET_STATIC_SOURCES ${LSOCKET_SRC}/usocket.c)
endif()
add_library(luasocket_static STATIC ${LSOCKET_STATIC_SOURCES})
target_compile_definitions(luasocket_static PRIVATE LUASOCKET_NODEBUG LUASOCKET_INET_PTON)
if(WIN32)
    target_compile_definitions(luasocket_static PRIVATE WINVER=0x0501)
endif()
target_include_directories(luasocket_static PUBLIC ${LSOCKET_SRC})
target_link_libraries(luasocket_static PUBLIC lua)

# ---- install ---------------------------------------------------------------
install(TARGETS socket LIBRARY DESTINATION lib/luasocket/socket
                       RUNTIME DESTINATION lib/luasocket/socket)
install(TARGETS mime   LIBRARY DESTINATION lib/luasocket/mime
                       RUNTIME DESTINATION lib/luasocket/mime)

# Copy the Lua-side helpers (http, ftp, smtp, ltn12, …) into the runtime tree
file(GLOB LSOCKET_LUA_HELPERS "${LSOCKET_SRC}/*.lua")
install(FILES ${LSOCKET_LUA_HELPERS} DESTINATION lib/luasocket/lua)
