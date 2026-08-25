cmake_minimum_required(VERSION 3.24)
project(crazycut LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

# The compositor and mixer are per-pixel/per-sample CPU loops. An unoptimized
# build renders preview frames roughly ten times slower, which reads as "the
# app is broken" rather than "the engine was built for debugging".
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  message(WARNING
    "CMAKE_BUILD_TYPE=Debug: preview and export will be ~10x slower. "
    "Use -DCMAKE_BUILD_TYPE=RelWithDebInfo unless you are stepping through "
    "the engine in a debugger.")
endif()

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
find_package(FFMPEG REQUIRED COMPONENTS avformat avcodec avutil swscale swresample)

include(FetchContent)
FetchContent_Declare(
  nlohmann_json
  GIT_REPOSITORY https://github.com/nlohmann/json.git
  GIT_TAG v3.11.3
)
FetchContent_MakeAvailable(nlohmann_json)

FetchContent_Declare(
  miniaudio
  GIT_REPOSITORY https://github.com/mackron/miniaudio.git
  GIT_TAG 0.11.21
)
FetchContent_MakeAvailable(miniaudio)

# Speech-to-text (AI-18). Optional so the engine still builds where the extra
# compile time is unwanted; `transcribe.cpp` compiles either way and reports a
# clear "not built with transcription support" instead of vanishing.
option(CC_WITH_WHISPER "Build with local speech-to-text (whisper.cpp)" ON)
if(CC_WITH_WHISPER)
  set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
  FetchContent_Declare(
    whisper
    GIT_REPOSITORY https://github.com/ggml-org/whisper.cpp.git
    GIT_TAG v1.7.4
  )
  FetchContent_MakeAvailable(whisper)
endif()

add_library(crazycut_core STATIC
  core/time.cpp
  core/log.cpp
  core/result.cpp
  model/project.cpp
  graph/keyframes.cpp
  media/probe.cpp
  media/prepare.cpp
  media/transcribe.cpp
  media/frame.cpp
  audio/decode.cpp
  audio/mixer.cpp
  playback/player.cpp
  playback/sequence_player.cpp
  render/effects.cpp
  render/composite.cpp
  render/renderer.cpp
)
target_include_directories(crazycut_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} PRIVATE ${miniaudio_SOURCE_DIR})
if(WIN32)
  target_compile_definitions(crazycut_core PRIVATE NOMINMAX)
endif()
target_link_libraries(crazycut_core
  PUBLIC
    FFMPEG::avformat FFMPEG::avcodec FFMPEG::avutil FFMPEG::swscale FFMPEG::swresample
    nlohmann_json::nlohmann_json
)
if(CC_WITH_WHISPER)
  target_link_libraries(crazycut_core PRIVATE whisper)
  # PUBLIC: callers (the worker, the tests) branch on this too, so it has to
  # cross the library boundary rather than stopping at crazycut_core.
  target_compile_definitions(crazycut_core PUBLIC CC_HAS_WHISPER)
endif()

add_library(crazycut SHARED bindings/crazycut.cpp)
target_link_libraries(crazycut PRIVATE crazycut_core)
set_target_properties(crazycut PROPERTIES OUTPUT_NAME crazycut)
add_executable(crazycut_worker apps/worker/main.cpp apps/worker/timeline_job.cpp)
target_link_libraries(crazycut_worker PRIVATE crazycut_core)

option(CC_BUILD_TESTS "Build unit tests" ON)
if(CC_BUILD_TESTS)
  enable_testing()
  FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG v1.14.0
  )
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(googletest)
  add_executable(cc_tests tests/time_test.cpp tests/project_test.cpp tests/keyframes_test.cpp tests/prepare_test.cpp tests/probe_test.cpp tests/playback_test.cpp tests/golden_test.cpp tests/audio_test.cpp tests/transcribe_test.cpp)
  target_compile_definitions(cc_tests PRIVATE CC_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(cc_tests PRIVATE crazycut_core GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(cc_tests)
endif()
