# Build the zlib_stream native plugin: minimal zlib binding for the
# ADC-EXT ZLIF stream-compression feature (Phase 8 S4b). Wraps the two
# stream operations the hub needs:
#
#   - deflate_stream:push(bytes) -> compressed bytes (Z_SYNC_FLUSH)
#   - inflate_stream:push(bytes) -> decompressed bytes (Z_SYNC_FLUSH,
#       with a hard total-output cap to bound decompression bombs)
#
# Output: lib/zlib_stream/zlib_stream.so (Linux) /
#         lib/zlib_stream/zlib_stream.dll (Windows). Loaded by the
# hub as require("zlib_stream"). Mirrors the layout of adclib.

add_library(zlib_stream MODULE
    zlib_stream.c
)

target_link_libraries(zlib_stream PRIVATE lua ZLIB::ZLIB)

# Lua C modules conventionally have no "lib" prefix on Linux either —
# require("zlib_stream") looks for zlib_stream.so directly.
set_target_properties(zlib_stream PROPERTIES
    PREFIX ""
)

# On Windows force .dll suffix to match the adclib precedent.
if(WIN32)
    set_target_properties(zlib_stream PROPERTIES SUFFIX ".dll")
endif()

# Static link of libgcc on Windows so the .dll does not drag in a
# runtime dependency on the toolchain. Mirrors adclib.
if(WIN32)
    target_link_options(zlib_stream PRIVATE
        -static-libgcc -static
    )
endif()

install(TARGETS zlib_stream LIBRARY DESTINATION lib/zlib_stream RUNTIME DESTINATION lib/zlib_stream)
