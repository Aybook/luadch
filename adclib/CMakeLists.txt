# Build the adclib native plugin: ADC protocol hashing (Tiger) + base32 +
# string escape/unescape. Loaded by luadch as require("adclib").
#
# Output: lib/adclib/adclib.so (Linux) / lib/adclib/adclib.dll (Windows).

add_library(adclib MODULE
    adclib.cpp
    base32.cpp
    tiger.cpp
)

target_link_libraries(adclib PRIVATE lua OpenSSL::Crypto)

# Lua C modules conventionally have no "lib" prefix on Linux either —
# require("adclib") looks for adclib.so directly, not libadclib.so.
set_target_properties(adclib PROPERTIES
    PREFIX ""
)

# On Windows we need to force .dll suffix (CMake MODULE on win32 already
# does this, but make it explicit so the file lands at adclib.dll).
if(WIN32)
    set_target_properties(adclib PROPERTIES SUFFIX ".dll")
endif()

# Static link of libstdc++/libgcc so the .dll/.so doesn't drag in a
# runtime dependency on the toolchain. Mirrors the legacy build flags.
if(WIN32)
    target_link_options(adclib PRIVATE
        -static-libgcc -static-libstdc++ -static
    )
endif()

install(TARGETS adclib LIBRARY DESTINATION lib/adclib RUNTIME DESTINATION lib/adclib)
