# Standalone native harness for the shared protocol, IPC validation and stream
# conversion code. Does not need libASPL.
#
#   cmake -S packages/driver/tests -B packages/driver/tests/build-asan
#   cmake --build packages/driver/tests/build-asan && packages/driver/tests/build-asan/soundbridge_protocol_tests
#   cmake -S packages/driver/tests -B packages/driver/tests/build-tsan -DSB_SANITIZE=thread
cmake_minimum_required(VERSION 3.20)
project(SoundBridgeProtocolTests LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

set(SB_SANITIZE "address,undefined" CACHE STRING "Sanitizers passed to -fsanitize=")

add_executable(soundbridge_protocol_tests
    test_main.cpp
    test_c_mode.c
    test_layout.cpp
    test_ring.cpp
    test_eq.cpp
    test_control.cpp
    test_ipc_fs.cpp
    test_conversion.cpp
    test_concurrency.cpp
    test_handoff.cpp
    test_render_slot.cpp
)

target_include_directories(soundbridge_protocol_tests PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

target_compile_options(soundbridge_protocol_tests PRIVATE
    -Wall -Wextra -g -O1 -fno-omit-frame-pointer
    -fsanitize=${SB_SANITIZE} -fno-sanitize-recover=all
)
target_link_options(soundbridge_protocol_tests PRIVATE -fsanitize=${SB_SANITIZE})
target_link_libraries(soundbridge_protocol_tests PRIVATE "-framework CoreAudio" "-framework CoreFoundation")

enable_testing()
add_test(NAME soundbridge_protocol_tests COMMAND soundbridge_protocol_tests)
