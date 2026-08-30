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

# Area tracking (TRK). OpenCV supplies feature flow and RANSAC homography.
# Optional for the same reason whisper is: it dominates a cold build, and the
# engine must still be buildable without it.
option(CC_WITH_TRACKING "Build with area tracking (OpenCV)" ON)
if(CC_WITH_TRACKING)
  # Static and trimmed, deliberately. tools/package-macos.sh walks otool -L and
  # copies, re-links and re-signs every dylib it finds; a shared OpenCV would
  # add a dozen libraries to bundle and notarize on macOS and to stage on
  # Windows, for one feature. Nothing here needs to be swappable at runtime.
  set(CC_TRACKING_SAVED_SHARED ${BUILD_SHARED_LIBS})
  set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
  # goodFeaturesToTrack lives in imgproc, calcOpticalFlowPyrLK in video,
  # findHomography in calib3d. Nothing else is used: frames come from the
  # engine's own ffmpeg decoder, so imgcodecs/videoio/highgui stay out.
  set(BUILD_LIST "core,imgproc,video,calib3d" CACHE STRING "" FORCE)
  foreach(_cc_off
      BUILD_TESTS BUILD_PERF_TESTS BUILD_EXAMPLES BUILD_DOCS BUILD_JAVA
      BUILD_opencv_apps BUILD_opencv_python2 BUILD_opencv_python3
      BUILD_ZLIB BUILD_PNG BUILD_JPEG BUILD_TIFF BUILD_WEBP BUILD_OPENJPEG
      BUILD_PROTOBUF WITH_PROTOBUF WITH_FFMPEG WITH_GSTREAMER WITH_1394
      WITH_OPENEXR WITH_JASPER WITH_IPP WITH_ITT WITH_QUIRC WITH_ADE
      WITH_OPENCL WITH_VTK WITH_EIGEN OPENCV_ENABLE_NONFREE
      INSTALL_C_EXAMPLES INSTALL_PYTHON_EXAMPLES
      # BUILD_LIST keeps these modules out of the build, but their cmake/init
      # scripts still run while modules are globbed, and videoio's tries to
      # download an Orbbec SDK. Naming them off stops that before it starts.
      BUILD_opencv_videoio BUILD_opencv_imgcodecs BUILD_opencv_highgui
      BUILD_opencv_gapi BUILD_opencv_dnn BUILD_opencv_ml BUILD_opencv_photo
      BUILD_opencv_objdetect BUILD_opencv_stitching BUILD_opencv_ts
      BUILD_opencv_videostab BUILD_opencv_world
      WITH_OBSENSOR WITH_AVFOUNDATION WITH_V4L WITH_DSHOW WITH_MSMF
      WITH_ARAVIS WITH_PVAPI WITH_XIMEA WITH_UEYE WITH_GPHOTO2
      WITH_ANDROID_MEDIANDK WITH_CAP_IOS WITH_OPENNI WITH_OPENNI2
      WITH_LAPACK WITH_TBB WITH_OPENMP)
    set(${_cc_off} OFF CACHE BOOL "" FORCE)
  endforeach()
  set(OPENCV_GENERATE_PKGCONFIG OFF CACHE BOOL "" FORCE)
  set(OPENCV_GENERATE_SETUPVARS OFF CACHE BOOL "" FORCE)
  FetchContent_Declare(
    opencv
    GIT_REPOSITORY https://github.com/opencv/opencv.git
    GIT_TAG 4.10.0
    GIT_SHALLOW TRUE
  )
  FetchContent_MakeAvailable(opencv)
  set(BUILD_SHARED_LIBS ${CC_TRACKING_SAVED_SHARED} CACHE BOOL "" FORCE)
  # OpenCV's targets do not carry usable interface include dirs from a build
  # tree, so the module headers are named explicitly.
  set(CC_OPENCV_INCLUDE_DIRS
    ${OPENCV_CONFIG_FILE_INCLUDE_DIR}
    ${opencv_SOURCE_DIR}/include
    ${opencv_SOURCE_DIR}/modules/core/include
    ${opencv_SOURCE_DIR}/modules/imgproc/include
    ${opencv_SOURCE_DIR}/modules/video/include
    ${opencv_SOURCE_DIR}/modules/calib3d/include
    ${opencv_SOURCE_DIR}/modules/features2d/include
    ${opencv_SOURCE_DIR}/modules/flann/include)
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
  track/solve.cpp
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
if(CC_WITH_TRACKING)
  target_link_libraries(crazycut_core PRIVATE
    opencv_core opencv_imgproc opencv_video opencv_calib3d)
  target_include_directories(crazycut_core PRIVATE ${CC_OPENCV_INCLUDE_DIRS})
  # PUBLIC: the worker and the tests branch on this too, so it has to cross the
  # library boundary rather than stopping at crazycut_core.
  target_compile_definitions(crazycut_core PUBLIC CC_HAS_TRACKING)
endif()

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

# OpenCV's CMake sets CMAKE_RUNTIME_OUTPUT_DIRECTORY for the entire build, which
# moves our executables into bin/ — where neither the app's engine discovery
# (app/lib/engine/engine.dart) nor tools/package-macos.sh looks. Both would then
# silently resolve a stale binary left over from an earlier build. Pin our own
# targets so adding a dependency can never relocate the artefacts other things
# find by path. (Multi-config generators still append the config subdirectory,
# which is what the Windows candidates already expect.)
set_target_properties(crazycut crazycut_worker PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
  LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

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
  add_executable(cc_tests tests/time_test.cpp tests/project_test.cpp tests/keyframes_test.cpp tests/prepare_test.cpp tests/probe_test.cpp tests/playback_test.cpp tests/golden_test.cpp tests/audio_test.cpp tests/transcribe_test.cpp tests/tracking_test.cpp)
  target_compile_definitions(cc_tests PRIVATE CC_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(cc_tests PRIVATE crazycut_core GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(cc_tests)
endif()
