cmake_minimum_required(VERSION 3.24)
project(crazycut LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
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

add_library(crazycut_core STATIC
  core/time.cpp
  core/log.cpp
  core/result.cpp
  model/project.cpp
  graph/keyframes.cpp
  media/probe.cpp
  media/prepare.cpp
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
target_link_libraries(crazycut_core
  PUBLIC
    FFMPEG::avformat FFMPEG::avcodec FFMPEG::avutil FFMPEG::swscale FFMPEG::swresample
    nlohmann_json::nlohmann_json
)

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
  add_executable(cc_tests tests/time_test.cpp tests/project_test.cpp tests/keyframes_test.cpp tests/prepare_test.cpp tests/probe_test.cpp tests/playback_test.cpp tests/golden_test.cpp tests/audio_test.cpp)
  target_compile_definitions(cc_tests PRIVATE CC_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(cc_tests PRIVATE crazycut_core GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(cc_tests)
endif()
